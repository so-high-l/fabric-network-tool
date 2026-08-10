#!/usr/bin/env bash
set -euo pipefail

TOOL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export FABRIC_TOOL_ROOT="$TOOL_ROOT"
source "$TOOL_ROOT/lib/common.sh"
source "$TOOL_ROOT/lib/config.sh"
source "$TOOL_ROOT/lib/kubernetes.sh"
source "$TOOL_ROOT/lib/ca-secrets.sh"
source "$TOOL_ROOT/lib/identities.sh"
source "$TOOL_ROOT/lib/peers.sh"

ACTION="${1:-}"
FABRIC_TOOL_TEMP=''

verify_peer_identity_contract() {
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
      log_ok "Verified peer identity contract: $peer_name"
    done
  done
}

prepare_peer_step() {
  local allow_missing_credentials="${1:-false}" org_index1 org_name peer_index0 peer_name pvc_name phase
  require_tool_environment
  validate_config
  require_command helm
  require_command kubectl
  require_command openssl
  require_command rg
  require_command yq
  [[ "$(storage_mode)" == existingClaims ]] || die 'Step 07 currently supports existingClaims only'
  [[ -d "$(peer_chart_directory)" ]] || die "Patched Bevel Fabric peer chart is missing: $(peer_chart_directory)"
  configure_cluster_clients
  FABRIC_TOOL_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/fabric-tool-peers.XXXXXX")"
  export FABRIC_TOOL_TEMP
  umask 077
  trap 'rm -rf "$FABRIC_TOOL_TEMP"' EXIT

  verify_peer_identity_contract
  if [[ -n "$(image_pull_secret)" ]]; then
    require_cluster_secret_keys "$(image_pull_secret)" .dockerconfigjson
  fi
  for ((org_index1 = 1; org_index1 <= $(peer_organization_count); org_index1++)); do
    org_name="$(peer_organization_name "$org_index1")"
    for ((peer_index0 = 0; peer_index0 < $(peers_per_organization); peer_index0++)); do
      peer_name="$(peer_kubernetes_name "$org_index1" "$peer_index0" "$org_name")"
      for pvc_name in \
        "$(peer_pvc_name "$org_index1" "$peer_index0" "$org_name" "$peer_name")" \
        "$(couchdb_pvc_name "$org_index1" "$peer_index0" "$org_name" "$peer_name")"
      do
        phase="$(kubectl "${KUBECTL_ARGS[@]}" get pvc "$pvc_name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
        [[ "$phase" == Bound ]] || die "Peer/CouchDB PVC is not Bound: $pvc_name ($phase)"
      done
    done
  done
  inspect_all_couchdb_credentials "$allow_missing_credentials"
}

list_peers() {
  local org_index1 peer_index0 org_name peer_name
  for ((org_index1 = 1; org_index1 <= $(peer_organization_count); org_index1++)); do
    org_name="$(peer_organization_name "$org_index1")"
    for ((peer_index0 = 0; peer_index0 < $(peers_per_organization); peer_index0++)); do
      peer_name="$(peer_kubernetes_name "$org_index1" "$peer_index0" "$org_name")"
      printf '    - %s (%s), CouchDB, %s\n' "$peer_name" "$(peer_organization_msp_id "$org_index1" "$org_name")" "$(service_fqdn "$peer_name")"
    done
  done
}

case "$ACTION" in
  name)
    printf '%s\n' 'Deploy peers and CouchDB'
    ;;
  implementation)
    printf '%s\n' 'ready'
    ;;
  plan)
    printf '  Peer releases:\n'
    list_peers
    printf '  Images: %s / %s\n' "$(fabric_peer_image)" "$(couchdb_image)"
    printf '  CouchDB credentials: %s (one preserved Secret per peer)\n' "$(couchdb_credentials_mode)"
    printf '  Safety: no Docker socket; no CouchDB Service port; operations TLS; no API token; pinned images\n'
    printf '  Reconciliation: render all -> reject unsafe scope -> server-admit all -> sequential Helm rollout\n'
    ;;
  check)
    prepare_peer_step true
    log_ok 'Peer identities, static PVCs, CouchDB credential contract, pinned images, and patched chart are ready'
    ;;
  render)
    require_tool_environment
    validate_config
    require_command helm
    require_command rg
    require_command yq
    [[ -d "$(peer_chart_directory)" ]] || die "Patched Bevel Fabric peer chart is missing: $(peer_chart_directory)"
    render_and_validate_all_peers
    ;;
  apply)
    prepare_peer_step true
    ensure_all_couchdb_credentials
    render_and_admit_all_peers
    deploy_all_peers
    ;;
  verify)
    prepare_peer_step false
    verify_all_peer_releases
    log_ok 'All generated Fabric peer and CouchDB releases are healthy'
    ;;
  *)
    die "Unsupported action for step 07: $ACTION"
    ;;
esac
