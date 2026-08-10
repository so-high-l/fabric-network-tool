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
for command_name in helm kubectl yq; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$command_name" >&2
    exit 1
  }
done

"$TOOL_ROOT/fabricctl.sh" validate --file "$CONFIG_FILE" >/dev/null
NETWORK="$(yq e -r '.metadata.name' "$CONFIG_FILE")"
CONTEXT="$(yq e -r '.spec.cluster.context' "$CONFIG_FILE")"
NAMESPACE="$(yq e -r '.spec.cluster.namespace' "$CONFIG_FILE")"
ORDERERS="$(yq e -r '.spec.topology.orderers' "$CONFIG_FILE")"
ORGANIZATIONS="$(yq e -r '.spec.topology.peerOrganizations' "$CONFIG_FILE")"
PEERS_PER_ORGANIZATION="$(yq e -r '.spec.topology.peersPerOrganization' "$CONFIG_FILE")"
EXPECTED_RELEASES=$((ORGANIZATIONS + 1 + ORDERERS + ORGANIZATIONS * PEERS_PER_ORGANIZATION))

# A healthy second apply performs deep verification and skips all ten steps.
"$TOOL_ROOT/fabricctl.sh" apply --file "$CONFIG_FILE" --from 1 --to 10 --confirm "$NETWORK"

PODS_JSON="$(kubectl --context "$CONTEXT" -n "$NAMESPACE" get pods -o json)"
BAD_PHASES="$(printf '%s' "$PODS_JSON" | yq -p=json -r '.items[] | select(.status.phase != "Running" and .status.phase != "Succeeded") | .metadata.name')"
UNREADY="$(printf '%s' "$PODS_JSON" | yq -p=json -r '.items[] | select(.status.phase == "Running") | select([.status.containerStatuses[]? | select(.ready != true)] | length > 0) | .metadata.name')"
RESTARTED="$(printf '%s' "$PODS_JSON" | yq -p=json -r '.items[] | select(([.status.initContainerStatuses[]?.restartCount, .status.containerStatuses[]?.restartCount] | map(select(. != null and . > 0)) | length) > 0) | .metadata.name')"

[[ -z "$BAD_PHASES" ]] || { printf 'Pods in failed/pending phases:\n%s\n' "$BAD_PHASES" >&2; exit 1; }
[[ -z "$UNREADY" ]] || { printf 'Running pods with unready containers:\n%s\n' "$UNREADY" >&2; exit 1; }
[[ -z "$RESTARTED" ]] || { printf 'Pods with container restarts:\n%s\n' "$RESTARTED" >&2; exit 1; }

RELEASES_JSON="$(helm --kube-context "$CONTEXT" --namespace "$NAMESPACE" list --output json)"
RELEASE_COUNT="$(printf '%s' "$RELEASES_JSON" | yq -p=json -r 'length')"
BAD_RELEASES="$(printf '%s' "$RELEASES_JSON" | yq -p=json -r '.[] | select(.status != "deployed") | .name')"
[[ "$RELEASE_COUNT" == "$EXPECTED_RELEASES" ]] || {
  printf 'Expected %s Helm releases, found %s.\n' "$EXPECTED_RELEASES" "$RELEASE_COUNT" >&2
  exit 1
}
[[ -z "$BAD_RELEASES" ]] || { printf 'Non-deployed Helm releases:\n%s\n' "$BAD_RELEASES" >&2; exit 1; }

printf '\n[ OK ] Local Fabric network verification passed.\n'
printf '       Network:       %s\n' "$NETWORK"
printf '       Helm releases: %s\n' "$RELEASE_COUNT"
printf '       Pod restarts:  0\n'
