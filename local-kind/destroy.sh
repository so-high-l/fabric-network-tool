#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  printf 'Usage: %s --file <development-kind-network.yaml> --confirm <network:context:DELETE>\n' "$0"
}

CONFIG_FILE=''
CONFIRM=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      CONFIG_FILE="$2"
      shift 2
      ;;
    --confirm)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      CONFIRM="$2"
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
command -v kind >/dev/null 2>&1 || { printf 'Missing required command: kind\n' >&2; exit 1; }
command -v yq >/dev/null 2>&1 || { printf 'Missing required command: yq\n' >&2; exit 1; }

"$TOOL_ROOT/fabricctl.sh" validate --file "$CONFIG_FILE" >/dev/null
NETWORK="$(yq e -r '.metadata.name' "$CONFIG_FILE")"
CONTEXT="$(yq e -r '.spec.cluster.context' "$CONFIG_FILE")"
ENVIRONMENT="$(yq e -r '.spec.environment' "$CONFIG_FILE")"
EXPECTED_CONFIRM="${NETWORK}:${CONTEXT}:DELETE"

[[ "$ENVIRONMENT" == development && "$CONTEXT" == kind-* ]] || {
  printf 'Cluster deletion is restricted to development kind configurations.\n' >&2
  exit 1
}
[[ "$CONFIRM" == "$EXPECTED_CONFIRM" ]] || {
  printf 'Refusing deletion. Pass --confirm %s\n' "$EXPECTED_CONFIRM" >&2
  exit 1
}

CLUSTER="${CONTEXT#kind-}"
if kind get clusters | rg -Fxq "$CLUSTER"; then
  kind delete cluster --name "$CLUSTER"
  printf '[ OK ] Deleted disposable kind cluster: %s\n' "$CLUSTER"
else
  printf '[ OK ] Kind cluster is already absent: %s\n' "$CLUSTER"
fi
