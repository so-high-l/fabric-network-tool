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

ACTION="${1:-}"
FABRIC_TOOL_TEMP=''

verify_peer_channel_identity_contract() {
  local org_index1 org_name org_ca org_admin peer_index0 peer_name
  for ((org_index1 = 1; org_index1 <= $(peer_organization_count); org_index1++)); do
    org_name="$(peer_organization_name "$org_index1")"
    org_ca="$(ca_kubernetes_name "$org_name" "$org_index1")"
    org_admin="${org_name}-admin"
    verify_identity_record admin "$org_ca" "$org_admin" client \
      "${org_name}-admin-msp" "${org_name}-admin-tls" "$(identity_hosts "$org_admin")"
    for ((peer_index0 = 0; peer_index0 < $(peers_per_organization); peer_index0++)); do
      peer_name="$(peer_kubernetes_name "$org_index1" "$peer_index0" "$org_name")"
      verify_identity_record node "$org_ca" "$peer_name" peer \
        "${peer_name}-msp" "${peer_name}-tls" "$(identity_hosts "$peer_name")"
    done
  done
  log_ok 'Verified every peer organization admin and peer TLS identity required by Step 09'
}

require_peer_channel_rbac() {
  local verb resource
  while IFS=' ' read -r verb resource; do
    [[ "$(kubectl "${KUBECTL_ARGS[@]}" auth can-i "$verb" "$resource")" == yes ]] || die "Namespace identity cannot $verb $resource, required by Step 09"
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

prepare_peer_channel_step() {
  require_tool_environment
  validate_config
  require_command kubectl
  require_command openssl
  require_command rg
  require_sha256_command
  require_command yq
  configure_cluster_clients
  FABRIC_TOOL_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/fabric-tool-peer-channel.XXXXXX")"
  export FABRIC_TOOL_TEMP
  umask 077
  trap 'rm -rf "$FABRIC_TOOL_TEMP"' EXIT
  prepare_channel_profile_sha
  prepare_peer_channel_plan_sha
  require_peer_channel_rbac
  verify_peer_channel_identity_contract
  if [[ -n "$(image_pull_secret)" ]]; then require_cluster_secret_keys "$(image_pull_secret)" .dockerconfigjson; fi
  verify_channel_receipt
  verify_channel_job_evidence
  verify_all_orderer_releases
  verify_all_peer_releases
  if peer_channel_receipt_exists; then verify_peer_channel_receipt; fi
}

case "$ACTION" in
  name)
    printf '%s\n' 'Join peers and set anchors'
    ;;
  implementation)
    printf '%s\n' 'ready'
    ;;
  plan)
    total_peers=$(( $(peer_organization_count) * $(peers_per_organization) ))
    printf '  Channel:             %s\n' "$(channel_name)"
    printf '  Peer joins:          %s\n' "$total_peers"
    printf '  Anchor updates:      %s (one per peer organization)\n' "$(peer_organization_count)"
    printf '  Anchor selection:    peer0 (index 0) in every organization\n'
    printf '  Execution:           one sequential restricted Job per organization\n'
    printf '  Idempotency key:     deterministic membership/anchor plan SHA-256 + immutable receipt\n'
    printf '  Verification:        every peer reports the channel, current block height, and expected anchor configuration\n'
    ;;
  check)
    prepare_peer_channel_step
    log_ok 'Channel, peer/admin identities, peer releases, pinned tools image, and namespace RBAC are ready'
    ;;
  render)
    require_tool_environment
    validate_config
    require_command rg
    require_sha256_command
    require_command yq
    FABRIC_TOOL_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/fabric-tool-peer-channel-render.XXXXXX")"
    export FABRIC_TOOL_TEMP
    trap 'rm -rf "$FABRIC_TOOL_TEMP"' EXIT
    prepare_channel_profile_sha
    render_and_validate_peer_channel_artifacts
    ;;
  apply)
    prepare_peer_channel_step
    render_and_validate_peer_channel_artifacts
    admit_peer_channel_artifacts
    deploy_peer_channel_jobs
    ;;
  verify)
    prepare_peer_channel_step
    verify_all_peer_channel_jobs
    log_ok 'Every generated peer is joined and every organization anchor is configured'
    ;;
  *)
    die "Unsupported action for step 09: $ACTION"
    ;;
esac
