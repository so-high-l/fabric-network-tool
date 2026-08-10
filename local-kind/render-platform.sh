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

CONFIG_DIR="$(cd "$(dirname "$CONFIG_FILE")" && pwd)"
export FABRIC_TOOL_ROOT="$TOOL_ROOT"
export FABRIC_TOOL_CALLER_DIR="$PWD"
FABRIC_TOOL_CONFIG="$CONFIG_DIR/$(basename "$CONFIG_FILE")"
export FABRIC_TOOL_CONFIG
export FABRIC_TOOL_OUTPUT='unused-by-local-kind-renderer'

# shellcheck source=../lib/common.sh
source "$TOOL_ROOT/lib/common.sh"
# shellcheck source=../lib/config.sh
source "$TOOL_ROOT/lib/config.sh"
# shellcheck source=../lib/inventory.sh
source "$TOOL_ROOT/lib/inventory.sh"

require_sha256_command
FABRIC_TOOL_CONFIG_SHA="$(sha256_file "$FABRIC_TOOL_CONFIG")"
export FABRIC_TOOL_CONFIG_SHA
validate_config >&2
[[ "$(environment_name)" == development ]] || die 'Local kind platform rendering requires spec.environment: development'
[[ "$(cluster_context)" == kind-* ]] || die 'Local kind platform rendering requires a kind-* context'
[[ "$(storage_mode)" == existingClaims ]] || die 'Local kind platform rendering currently requires storage.mode: existingClaims'

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fabric-kind-platform.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
INVENTORY="$TEMP_DIR/inventory.yaml"
render_inventory "$INVENTORY" >&2

NETWORK="$(network_name)"
NAMESPACE="$(cluster_namespace)"
SERVICE_ACCOUNT="$(cluster_service_account)"
ROLE_NAME='fabric-network-deployer'

emit_separator() {
  printf '%s\n' '---'
}

printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: %s\n  labels:\n' "$NAMESPACE"
printf '    pod-security.kubernetes.io/enforce: restricted\n'
printf '    pod-security.kubernetes.io/enforce-version: latest\n'
printf '    pod-security.kubernetes.io/audit: restricted\n'
printf '    pod-security.kubernetes.io/audit-version: latest\n'
printf '    pod-security.kubernetes.io/warn: restricted\n'
printf '    pod-security.kubernetes.io/warn-version: latest\n'

emit_separator
printf 'apiVersion: v1\nkind: ServiceAccount\nmetadata:\n  name: %s\n  namespace: %s\nautomountServiceAccountToken: false\n' \
  "$SERVICE_ACCOUNT" "$NAMESPACE"

emit_separator
printf 'apiVersion: rbac.authorization.k8s.io/v1\nkind: Role\nmetadata:\n  name: %s\n  namespace: %s\nrules:\n' \
  "$ROLE_NAME" "$NAMESPACE"
printf '%s\n' \
  '  - apiGroups: [""]' \
  '    resources: [pods]' \
  '    verbs: [get, list, watch, create, delete]' \
  '  - apiGroups: [""]' \
  '    resources: [pods/log]' \
  '    verbs: [get]' \
  '  - apiGroups: [""]' \
  '    resources: [services, configmaps, secrets, persistentvolumeclaims]' \
  '    verbs: [get, list, watch, create, update, patch, delete]' \
  '  - apiGroups: [""]' \
  '    resources: [events, resourcequotas]' \
  '    verbs: [get, list, watch]' \
  '  - apiGroups: [discovery.k8s.io]' \
  '    resources: [endpointslices]' \
  '    verbs: [get, list, watch]' \
  '  - apiGroups: [apps]' \
  '    resources: [deployments, statefulsets, replicasets]' \
  '    verbs: [get, list, watch, create, update, patch, delete]' \
  '  - apiGroups: [batch]' \
  '    resources: [jobs]' \
  '    verbs: [get, list, watch, create, update, patch, delete]'

emit_separator
printf 'apiVersion: rbac.authorization.k8s.io/v1\nkind: RoleBinding\nmetadata:\n  name: %s\n  namespace: %s\nsubjects:\n' \
  "$ROLE_NAME" "$NAMESPACE"
printf '  - kind: ServiceAccount\n    name: %s\n    namespace: %s\n' "$SERVICE_ACCOUNT" "$NAMESPACE"
printf 'roleRef:\n  apiGroup: rbac.authorization.k8s.io\n  kind: Role\n  name: %s\n' "$ROLE_NAME"

while IFS=$'\t' read -r claim size component; do
  [[ -n "$claim" ]] || continue
  pv_name="${NAMESPACE}-${NETWORK}-${claim}"
  host_path="/var/local/fabric-network-tool/${NAMESPACE}/${NETWORK}/${claim}"

  emit_separator
  printf 'apiVersion: v1\nkind: PersistentVolume\nmetadata:\n  name: %s\n  labels:\n' "$pv_name"
  printf '    fabric.network.tools/network: %s\n    fabric.network.tools/claim: %s\n' "$NETWORK" "$claim"
  printf 'spec:\n  capacity: {storage: %s}\n  accessModes: [ReadWriteOnce]\n' "$size"
  printf '  persistentVolumeReclaimPolicy: Retain\n  storageClassName: ""\n  volumeMode: Filesystem\n'
  printf '  hostPath:\n    path: %s\n    type: DirectoryOrCreate\n' "$host_path"

  emit_separator
  printf 'apiVersion: v1\nkind: PersistentVolumeClaim\nmetadata:\n  name: %s\n  namespace: %s\n  labels:\n' "$claim" "$NAMESPACE"
  printf '    fabric.network.tools/network: %s\n    fabric.network.tools/component: %s\n' "$NETWORK" "$component"
  printf 'spec:\n  accessModes: [ReadWriteOnce]\n  storageClassName: ""\n  volumeMode: Filesystem\n'
  printf '  resources:\n    requests: {storage: %s}\n' "$size"
  printf '  selector:\n    matchLabels:\n      fabric.network.tools/network: %s\n      fabric.network.tools/claim: %s\n' "$NETWORK" "$claim"
done < <(
  yq e -r '
    (
      [.spec.ordererOrganization.ca.pvc, "5Gi", "fabric-ca"],
      (.spec.ordererOrganization.orderers[] | [.pvc, "10Gi", "orderer"]),
      (.spec.peerOrganizations[] | [.ca.pvc, "5Gi", "fabric-ca"]),
      (.spec.peerOrganizations[].peers[] | [.peerPvc, "20Gi", "peer"]),
      (.spec.peerOrganizations[].peers[] | [.couchdbPvc, "20Gi", "couchdb"])
    ) | @tsv
  ' "$INVENTORY"
)
