#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  printf 'Usage: %s --file <development-kind-network.yaml> [--source <local-docker-tag>]\n' "$0"
}

normalize_containerd_reference() {
  local reference="${1%@sha256:*}"
  local first_component
  if [[ "$reference" != */* ]]; then
    printf 'docker.io/library/%s' "$reference"
    return
  fi
  first_component="${reference%%/*}"
  if [[ "$first_component" != *.* && "$first_component" != *:* && "$first_component" != localhost ]]; then
    printf 'docker.io/%s' "$reference"
  else
    printf '%s' "$reference"
  fi
}

CONFIG_FILE=''
SOURCE_IMAGE=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      CONFIG_FILE="$2"
      shift 2
      ;;
    --source)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      SOURCE_IMAGE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]] || { usage >&2; exit 2; }
for command_name in docker kind rg yq; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$command_name" >&2
    exit 1
  }
done

"$TOOL_ROOT/fabricctl.sh" validate --file "$CONFIG_FILE" >/dev/null
CONTEXT="$(yq e -r '.spec.cluster.context' "$CONFIG_FILE")"
ENVIRONMENT="$(yq e -r '.spec.environment' "$CONFIG_FILE")"
CONFIGURED_IMAGE="$(yq e -r '.spec.images.chaincode' "$CONFIG_FILE")"
[[ "$ENVIRONMENT" == development && "$CONTEXT" == kind-* ]] || {
  printf 'Image loading is restricted to development kind configurations.\n' >&2
  exit 1
}

CLUSTER="${CONTEXT#kind-}"
NODE="${CLUSTER}-control-plane"
EXPECTED_DIGEST="${CONFIGURED_IMAGE##*@}"
CONFIGURED_TAG="${CONFIGURED_IMAGE%@sha256:*}"
SOURCE_IMAGE="${SOURCE_IMAGE:-$CONFIGURED_TAG}"

kind get clusters | rg -Fxq "$CLUSTER" || {
  printf 'Kind cluster does not exist: %s\n' "$CLUSTER" >&2
  exit 1
}
docker image inspect "$SOURCE_IMAGE" >/dev/null 2>&1 || {
  printf 'Local Docker image does not exist: %s\n' "$SOURCE_IMAGE" >&2
  exit 1
}

kind load docker-image "$SOURCE_IMAGE" --name "$CLUSTER"
SOURCE_REFERENCE="$(normalize_containerd_reference "$SOURCE_IMAGE")"
CONFIGURED_REFERENCE="$(normalize_containerd_reference "$CONFIGURED_TAG")"
INSPECT_OUTPUT="$(docker exec "$NODE" ctr --namespace=k8s.io images inspect "$SOURCE_REFERENCE")"
LOADED_DIGEST="$(printf '%s\n' "$INSPECT_OUTPUT" | rg -o 'sha256:[a-f0-9]{64}' | sed -n '1p')"

[[ -n "$LOADED_DIGEST" ]] || {
  printf 'Could not determine the loaded OCI image digest for %s\n' "$SOURCE_REFERENCE" >&2
  exit 1
}
[[ "$LOADED_DIGEST" == "$EXPECTED_DIGEST" ]] || {
  printf 'Configured chaincode digest does not match the loaded image.\n' >&2
  printf '  configured: %s\n' "$EXPECTED_DIGEST" >&2
  printf '  loaded:     %s\n' "$LOADED_DIGEST" >&2
  printf 'Update spec.images.chaincode only after confirming the loaded image is trusted.\n' >&2
  exit 1
}

# Kubernetes canonicalizes name:tag@digest to name@digest before asking the
# runtime. Create that exact alias; retaining the tag here makes kubelet miss
# the locally loaded image and attempt an external registry pull.
CONFIGURED_REPOSITORY="$CONFIGURED_REFERENCE"
CONFIGURED_LAST_COMPONENT="${CONFIGURED_REFERENCE##*/}"
if [[ "$CONFIGURED_LAST_COMPONENT" == *:* ]]; then
  CONFIGURED_REPOSITORY="${CONFIGURED_REFERENCE%:*}"
fi
TARGET_REFERENCE="${CONFIGURED_REPOSITORY}@${EXPECTED_DIGEST}"
docker exec "$NODE" ctr --namespace=k8s.io images tag --force "$SOURCE_REFERENCE" "$TARGET_REFERENCE" >/dev/null
docker exec "$NODE" ctr --namespace=k8s.io images inspect "$TARGET_REFERENCE" >/dev/null
printf '[ OK ] Loaded and digest-verified chaincode image: %s\n' "$TARGET_REFERENCE"
