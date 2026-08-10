#!/usr/bin/env bash
set -euo pipefail

TOOL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export FABRIC_TOOL_ROOT="$TOOL_ROOT"
source "$TOOL_ROOT/lib/common.sh"
source "$TOOL_ROOT/lib/config.sh"
source "$TOOL_ROOT/lib/kubernetes.sh"
source "$TOOL_ROOT/lib/identities.sh"
source "$TOOL_ROOT/lib/orderers.sh"
source "$TOOL_ROOT/lib/peers.sh"
source "$TOOL_ROOT/lib/channels.sh"
source "$TOOL_ROOT/lib/peer-channels.sh"
source "$TOOL_ROOT/lib/chaincodes.sh"

ACTION="${1:-}"
FABRIC_TOOL_TEMP=''

require_chaincode_rbac() {
  local verb resource
  while IFS=' ' read -r verb resource; do
    [[ "$(kubectl "${KUBECTL_ARGS[@]}" auth can-i "$verb" "$resource")" == yes ]] || die "Namespace identity cannot $verb $resource, required by Step 10"
  done <<'RBAC'
create jobs.batch
get jobs.batch
list jobs.batch
watch jobs.batch
delete jobs.batch
create configmaps
get configmaps
patch configmaps
create deployments.apps
get deployments.apps
patch deployments.apps
create services
get services
patch services
get pods
list pods
get pods/log
RBAC
}

verify_chaincode_prerequisites() {
  local org_index1 org_name cc_name peer_index0 peer_name
  require_cluster_secret_keys "$(orderer_kubernetes_name 0)-tls" cacrt
  for ((org_index1=1; org_index1<=$(peer_organization_count); org_index1++)); do
    org_name="$(peer_organization_name "$org_index1")"; cc_name="$(chaincode_kubernetes_name "$org_index1" "$org_name")"
    require_cluster_secret_keys "${org_name}-admin-msp" admincerts cacerts keystore signcerts tlscacerts
    require_cluster_secret_keys "$(chaincode_tls_secret_name "$org_index1" "$org_name" "$cc_name")" ca.crt client.crt client.key
    for ((peer_index0=0; peer_index0<$(peers_per_organization); peer_index0++)); do peer_name="$(peer_kubernetes_name "$org_index1" "$peer_index0" "$org_name")"; require_cluster_secret_keys "${peer_name}-tls" cacrt; done
  done
  [[ -z "$(image_pull_secret)" ]] || require_cluster_secret_keys "$(image_pull_secret)" .dockerconfigjson
  verify_channel_receipt; verify_all_peer_channel_jobs; verify_all_peer_releases
}

prepare_chaincode_step() {
  require_tool_environment; validate_config
  require_command kubectl; require_command rg; require_sha256_command; require_command yq
  configure_cluster_clients
  FABRIC_TOOL_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/fabric-tool-chaincode.XXXXXX")"; export FABRIC_TOOL_TEMP
  trap 'rm -rf "$FABRIC_TOOL_TEMP"' EXIT
  prepare_channel_profile_sha; prepare_peer_channel_plan_sha; prepare_chaincode_plan_sha
  require_chaincode_rbac; verify_chaincode_prerequisites
}

case "$ACTION" in
  name) printf '%s\n' 'Deploy and commit CCaaS chaincode' ;;
  implementation) printf '%s\n' ready ;;
  plan)
    printf '  Chaincode:           %s version %s, sequence %s\n' "$(chaincode_name)" "$(chaincode_version)" "$(chaincode_sequence)"
    printf '  Channel:             %s\n' "$(channel_name)"
    printf '  External servers:    %s (one per organization)\n' "$(peer_organization_count)"
    printf '  Lifecycle:           deterministic mTLS packages; install/approve per org; commit once\n'
    printf '  Verification:        retained lifecycle evidence plus end-to-end expected-error execution probe\n'
    ;;
  check) prepare_chaincode_step; log_ok 'Channel, peers, chaincode TLS material, registry access Secret, and namespace RBAC are ready' ;;
  render)
    require_tool_environment; validate_config; require_command rg; require_sha256_command; require_command yq
    FABRIC_TOOL_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/fabric-tool-chaincode-render.XXXXXX")"; export FABRIC_TOOL_TEMP; trap 'rm -rf "$FABRIC_TOOL_TEMP"' EXIT
    render_and_validate_chaincode_artifacts
    ;;
  apply)
    prepare_chaincode_step; render_and_validate_chaincode_artifacts
    for ((org_index1=1; org_index1<=$(peer_organization_count); org_index1++)); do org_name="$(peer_organization_name "$org_index1")"; kubectl "${KUBECTL_ARGS[@]}" apply --server-side --dry-run=server --field-manager=fabricctl-admission --force-conflicts -f "$(chaincode_org_render_file "$org_name")" >/dev/null; done
    for local_file in "$(chaincode_runtime_render_file)" "$(chaincode_commit_render_file)" "$(chaincode_receipt_render_file)"; do kubectl "${KUBECTL_ARGS[@]}" apply --server-side --dry-run=server --field-manager=fabricctl-admission --force-conflicts -f "$local_file" >/dev/null; done
    deploy_chaincode
    ;;
  verify) prepare_chaincode_step; verify_chaincode_deployment ;;
  *) die "Unsupported action for step 10: $ACTION" ;;
esac
