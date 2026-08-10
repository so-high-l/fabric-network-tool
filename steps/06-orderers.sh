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

ACTION="${1:-}"
FABRIC_TOOL_TEMP=''

verify_orderer_identity_contract() {
  local orderer_org orderer_ca orderer_admin orderer_index0 orderer_name fabric_name
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
    log_ok "Verified orderer identity contract: $orderer_name"
  done
}

prepare_orderer_step() {
  local orderer_index0 orderer_name pvc_name phase
  require_tool_environment
  validate_config
  require_command helm
  require_command kubectl
  require_command openssl
  require_command rg
  require_command yq
  [[ "$(storage_mode)" == existingClaims ]] || die 'Step 06 currently supports existingClaims only'
  [[ -d "$(orderer_chart_directory)" ]] || die "Patched Bevel Fabric orderer chart is missing: $(orderer_chart_directory)"
  configure_cluster_clients
  FABRIC_TOOL_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/fabric-tool-orderers.XXXXXX")"
  export FABRIC_TOOL_TEMP
  umask 077
  trap 'rm -rf "$FABRIC_TOOL_TEMP"' EXIT

  verify_orderer_identity_contract
  if [[ -n "$(image_pull_secret)" ]]; then
    require_cluster_secret_keys "$(image_pull_secret)" .dockerconfigjson
  fi
  for ((orderer_index0 = 0; orderer_index0 < $(orderer_count); orderer_index0++)); do
    orderer_name="$(orderer_kubernetes_name "$orderer_index0")"
    pvc_name="$(orderer_pvc_name "$orderer_index0" "$orderer_name")"
    phase="$(kubectl "${KUBECTL_ARGS[@]}" get pvc "$pvc_name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "$phase" == Bound ]] || die "Orderer PVC is not Bound: $pvc_name ($phase)"
  done
}

list_orderers() {
  local orderer_index0 name
  for ((orderer_index0 = 0; orderer_index0 < $(orderer_count); orderer_index0++)); do
    name="$(orderer_kubernetes_name "$orderer_index0")"
    printf '    - %s (%s), %s\n' "$name" "$(orderer_fabric_name "$orderer_index0")" "$(service_fqdn "$name")"
  done
}

case "$ACTION" in
  name)
    printf '%s\n' 'Deploy Raft orderers'
    ;;
  implementation)
    printf '%s\n' 'ready'
    ;;
  plan)
    printf '  Raft members:\n'
    list_orderers
    printf '  Fabric/image: %s / %s\n' "$(fabric_version)" "$(fabric_orderer_image)"
    printf '  Initial state: healthy participation-mode orderers with zero channels\n'
    printf '  Safety: render all -> reject cluster scope -> server-admit all -> sequential Helm reconciliation\n'
    ;;
  check)
    prepare_orderer_step
    log_ok 'Orderer identities, static PVCs, pinned image, and patched chart are ready'
    ;;
  render)
    require_tool_environment
    validate_config
    require_command helm
    require_command rg
    require_command yq
    [[ -d "$(orderer_chart_directory)" ]] || die "Patched Bevel Fabric orderer chart is missing: $(orderer_chart_directory)"
    render_and_validate_all_orderers
    ;;
  apply)
    prepare_orderer_step
    render_and_admit_all_orderers
    deploy_all_orderers
    ;;
  verify)
    prepare_orderer_step
    verify_all_orderer_releases
    log_ok 'All generated participation-mode orderer releases are healthy'
    ;;
  *)
    die "Unsupported action for step 06: $ACTION"
    ;;
esac
