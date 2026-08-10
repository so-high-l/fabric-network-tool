#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  printf 'Usage: %s --file <development-kind-network.yaml>\n' "$0"
}

CONFIG_FILE=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      CONFIG_FILE="$2"
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

for command_name in bash docker helm kind kubectl openssl rg yq; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$command_name" >&2
    exit 1
  }
done
docker info >/dev/null 2>&1 || {
  printf 'Docker is not reachable. Start Docker Desktop or the Docker daemon first.\n' >&2
  exit 1
}

"$TOOL_ROOT/fabricctl.sh" validate --file "$CONFIG_FILE" >/dev/null
ENVIRONMENT="$(yq e -r '.spec.environment' "$CONFIG_FILE")"
CONTEXT="$(yq e -r '.spec.cluster.context' "$CONFIG_FILE")"
NAMESPACE="$(yq e -r '.spec.cluster.namespace' "$CONFIG_FILE")"
NETWORK="$(yq e -r '.metadata.name' "$CONFIG_FILE")"

[[ "$ENVIRONMENT" == development ]] || {
  printf 'Local setup refuses non-development configuration: %s\n' "$ENVIRONMENT" >&2
  exit 1
}
[[ "$CONTEXT" == kind-* ]] || {
  printf 'Local setup refuses a non-kind context: %s\n' "$CONTEXT" >&2
  exit 1
}

CLUSTER="${CONTEXT#kind-}"
NODE="${CLUSTER}-control-plane"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fabric-kind-setup.XXXXXX")"
PLATFORM_MANIFEST="$TEMP_DIR/platform.yaml"
PREVIOUS_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"

restore_context() {
  rm -rf "$TEMP_DIR"
  if [[ -n "$PREVIOUS_CONTEXT" && "$PREVIOUS_CONTEXT" != "$CONTEXT" ]]; then
    kubectl config use-context "$PREVIOUS_CONTEXT" >/dev/null 2>&1 || true
  fi
}
trap restore_context EXIT

if kind get clusters | rg -Fxq "$CLUSTER"; then
  printf '[ OK ] Reusing kind cluster: %s\n' "$CLUSTER"
else
  printf '[INFO] Creating kind cluster: %s\n' "$CLUSTER"
  kind create cluster --name "$CLUSTER" --config "$SCRIPT_DIR/kind-cluster.yaml"
fi

kubectl --context "$CONTEXT" wait --for=condition=Ready node --all --timeout=180s >/dev/null
"$SCRIPT_DIR/render-platform.sh" --file "$CONFIG_FILE" >"$PLATFORM_MANIFEST"
yq e '.' "$PLATFORM_MANIFEST" >/dev/null

while IFS= read -r host_path; do
  [[ -n "$host_path" ]] || continue
  docker exec "$NODE" mkdir -p "$host_path"
  docker exec "$NODE" chown 1000:1000 "$host_path"
done < <(yq ea -N -r 'select(.kind == "PersistentVolume") | .spec.hostPath.path' "$PLATFORM_MANIFEST")

kubectl --context "$CONTEXT" apply -f "$PLATFORM_MANIFEST" >/dev/null

while IFS= read -r claim; do
  [[ -n "$claim" ]] || continue
  kubectl --context "$CONTEXT" -n "$NAMESPACE" wait \
    --for=jsonpath='{.status.phase}'=Bound "persistentvolumeclaim/$claim" --timeout=120s >/dev/null
done < <(yq ea -N -r 'select(.kind == "PersistentVolumeClaim") | .metadata.name' "$PLATFORM_MANIFEST")

"$TOOL_ROOT/fabricctl.sh" preflight --file "$CONFIG_FILE" --from 2 --to 2

printf '\n[ OK ] Local kind platform is ready for network %s.\n' "$NETWORK"
printf '       Context:   %s\n' "$CONTEXT"
printf '       Namespace: %s\n' "$NAMESPACE"
