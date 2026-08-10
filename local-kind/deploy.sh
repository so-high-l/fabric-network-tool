#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  printf 'Usage: %s --file <development-kind-network.yaml> [--chaincode-image <local-docker-tag>]\n' "$0"
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
    --chaincode-image)
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
for command_name in docker kubectl yq; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$command_name" >&2
    exit 1
  }
done

"$TOOL_ROOT/fabricctl.sh" validate --file "$CONFIG_FILE" >/dev/null
NETWORK="$(yq e -r '.metadata.name' "$CONFIG_FILE")"
CONTEXT="$(yq e -r '.spec.cluster.context' "$CONFIG_FILE")"
NAMESPACE="$(yq e -r '.spec.cluster.namespace' "$CONFIG_FILE")"
CONFIGURED_IMAGE="$(yq e -r '.spec.images.chaincode' "$CONFIG_FILE")"
CONFIGURED_TAG="${CONFIGURED_IMAGE%@sha256:*}"
PULL_SECRET="$(yq e -r '.spec.images.pullSecret // ""' "$CONFIG_FILE")"

"$SCRIPT_DIR/setup.sh" --file "$CONFIG_FILE"

if [[ -n "$SOURCE_IMAGE" ]]; then
  "$SCRIPT_DIR/load-image.sh" --file "$CONFIG_FILE" --source "$SOURCE_IMAGE"
elif docker image inspect "$CONFIGURED_TAG" >/dev/null 2>&1; then
  "$SCRIPT_DIR/load-image.sh" --file "$CONFIG_FILE"
elif [[ "$CONFIGURED_TAG" != */* ]]; then
  printf 'The unqualified local chaincode image is not present in Docker: %s\n' "$CONFIGURED_TAG" >&2
  printf 'Build it first or pass --chaincode-image with a trusted local tag.\n' >&2
  exit 1
else
  printf '[INFO] Chaincode image is registry-qualified; kind will pull its configured digest.\n'
fi

if [[ -n "$PULL_SECRET" ]]; then
  kubectl --context "$CONTEXT" -n "$NAMESPACE" get secret "$PULL_SECRET" >/dev/null 2>&1 || {
    printf 'Missing configured registry Secret %s in namespace %s.\n' "$PULL_SECRET" "$NAMESPACE" >&2
    printf 'Create it securely before deployment; never put registry credentials in the network YAML.\n' >&2
    exit 1
  }
fi

"$TOOL_ROOT/fabricctl.sh" apply --file "$CONFIG_FILE" --from 1 --to 10 --confirm "$NETWORK"
"$SCRIPT_DIR/verify.sh" --file "$CONFIG_FILE"
