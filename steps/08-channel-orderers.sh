#!/usr/bin/env bash
set -euo pipefail

TOOL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export FABRIC_TOOL_ROOT="$TOOL_ROOT"
source "$TOOL_ROOT/lib/common.sh"
source "$TOOL_ROOT/lib/config.sh"
source "$TOOL_ROOT/lib/kubernetes.sh"
source "$TOOL_ROOT/lib/ca-secrets.sh"
source "$TOOL_ROOT/lib/identities.sh"
source "$TOOL_ROOT/lib/orderers.sh"
source "$TOOL_ROOT/lib/channels.sh"

ACTION="${1:-}"
FABRIC_TOOL_TEMP=''

verify_channel_identity_contract() {
  local orderer_org orderer_ca orderer_admin orderer_index0 orderer_name fabric_name
  local org_index1 org_name org_ca org_admin
  orderer_org="$(orderer_organization_name)"
  orderer_ca="$(ca_kubernetes_name "$orderer_org")"
  orderer_admin="${orderer_org}-admin"
  verify_identity_record admin "$orderer_ca" "$orderer_admin" client \
    "${orderer_org}-admin-msp" "${orderer_org}-admin-tls" "$(identity_hosts "$orderer_admin")"
  for ((orderer_index0 = 0; orderer_index0 < $(orderer_count); orderer_index0++)); do
    orderer_name="$(orderer_kubernetes_name "$orderer_index0")"
    fabric_name="$(orderer_fabric_name "$orderer_index0")"
    verify_identity_record node "$orderer_ca" "$orderer_name" orderer \
      "${orderer_name}-msp" "${orderer_name}-tls" "$(identity_hosts "$orderer_name" "$fabric_name")"
  done
  for ((org_index1 = 1; org_index1 <= $(peer_organization_count); org_index1++)); do
    org_name="$(peer_organization_name "$org_index1")"
    org_ca="$(ca_kubernetes_name "$org_name" "$org_index1")"
    org_admin="${org_name}-admin"
    verify_identity_record admin "$org_ca" "$org_admin" client \
      "${org_name}-admin-msp" "${org_name}-admin-tls" "$(identity_hosts "$org_admin")"
  done
  log_ok 'Verified all channel MSP roots, admins, consenters, and admin TLS material'
}

require_channel_rbac() {
  local verb resource
  while IFS=' ' read -r verb resource; do
    [[ "$(kubectl "${KUBECTL_ARGS[@]}" auth can-i "$verb" "$resource")" == yes ]] || die "Namespace identity cannot $verb $resource, required by Step 08"
  done <<'RBAC'
create jobs.batch
get jobs.batch
list jobs.batch
watch jobs.batch
delete jobs.batch
create configmaps
get configmaps
patch configmaps
get pods
list pods
get pods/log
RBAC
}

prepare_channel_step() {
  require_tool_environment
  validate_config
  require_command kubectl
  require_command openssl
  require_command rg
  require_sha256_command
  require_command yq
  configure_cluster_clients
  FABRIC_TOOL_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/fabric-tool-channel.XXXXXX")"
  export FABRIC_TOOL_TEMP
  umask 077
  trap 'rm -rf "$FABRIC_TOOL_TEMP"' EXIT
  prepare_channel_profile_sha
  require_channel_rbac
  verify_channel_identity_contract
  if [[ -n "$(image_pull_secret)" ]]; then require_cluster_secret_keys "$(image_pull_secret)" .dockerconfigjson; fi
  verify_all_orderer_releases
  if channel_receipt_exists; then verify_channel_receipt; fi
}

case "$ACTION" in
  name)
    printf '%s\n' 'Create channel and activate Raft'
    ;;
  implementation)
    printf '%s\n' 'ready'
    ;;
  plan)
    printf '  Channel:             %s\n' "$(channel_name)"
    printf '  Application orgs:    %s\n' "$(peer_organization_count)"
    printf '  Consenters:          %s\n' "$(orderer_count)"
    printf '  Fabric tools image:  %s\n' "$(fabric_tools_image)"
    printf '  Idempotency key:     channel name + deterministic profile SHA-256\n'
    printf '  Join method:         restricted in-cluster Job + TLS Channel Participation API\n'
    printf '  Completion gate:     all consenters active, Raft startup/leader evidence, immutable receipt\n'
    ;;
  check)
    prepare_channel_step
    [[ "$(operations_tls_enabled)" == true ]] || log_warn 'Operations TLS is disabled outside production; orderer admin TLS remains required'
    log_ok 'Channel profile, identities, orderers, digest-pinned tools image, and namespace RBAC are ready'
    ;;
  render)
    require_tool_environment
    validate_config
    require_command rg
    require_sha256_command
    require_command yq
    render_and_validate_channel_artifacts
    ;;
  apply)
    prepare_channel_step
    render_and_validate_channel_artifacts
    admit_channel_artifacts
    deploy_channel_job
    ;;
  verify)
    prepare_channel_step
    verify_channel_receipt
    verify_channel_job_evidence
    verify_raft_log_evidence
    log_ok 'Application channel is active on every Raft consenter'
    ;;
  *)
    die "Unsupported action for step 08: $ACTION"
    ;;
esac
