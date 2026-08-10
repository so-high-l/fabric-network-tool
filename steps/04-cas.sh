#!/usr/bin/env bash
set -euo pipefail

TOOL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export FABRIC_TOOL_ROOT="$TOOL_ROOT"
source "$TOOL_ROOT/lib/common.sh"
source "$TOOL_ROOT/lib/config.sh"
source "$TOOL_ROOT/lib/kubernetes.sh"
source "$TOOL_ROOT/lib/ca-secrets.sh"
source "$TOOL_ROOT/lib/fabric-ca.sh"

ACTION="${1:-}"
FABRIC_TOOL_TEMP=''

prepare_ca_step() {
  local ca_name organization _admin_name org_index1 pvc_name phase

  require_tool_environment
  validate_config
  require_command helm
  require_command kubectl
  require_command openssl
  require_command rg
  require_command yq
  [[ "$(storage_mode)" == existingClaims ]] || die 'Step 04 currently supports existingClaims only'
  [[ -d "$(ca_chart_directory)" ]] || die "Patched Bevel Fabric CA chart is missing: $(ca_chart_directory)"
  configure_cluster_clients
  FABRIC_TOOL_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/fabric-tool-ca-step.XXXXXX")"
  export FABRIC_TOOL_TEMP
  umask 077
  trap 'rm -rf "$FABRIC_TOOL_TEMP"' EXIT

  verify_all_ca_secrets
  if [[ -n "$(image_pull_secret)" ]]; then
    require_cluster_secret_keys "$(image_pull_secret)" .dockerconfigjson
  fi
  while IFS=$'\t' read -r ca_name organization _admin_name org_index1; do
    pvc_name="$(ca_pvc_name "$org_index1" "$organization" "$ca_name")"
    phase="$(kubectl "${KUBECTL_ARGS[@]}" get pvc "$pvc_name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "$phase" == Bound ]] || die "CA PVC is not Bound: $pvc_name ($phase)"
  done < <(list_ca_records)
}

list_cas() {
  local org_index1 org_name
  printf '    - %s\n' "$(ca_kubernetes_name "$(orderer_organization_name)")"
  for ((org_index1 = 1; org_index1 <= $(peer_organization_count); org_index1++)); do
    org_name="$(peer_organization_name "$org_index1")"
    printf '    - %s\n' "$(ca_kubernetes_name "$org_name" "$org_index1")"
  done
}

case "$ACTION" in
  name)
    printf '%s\n' 'Deploy Fabric CAs'
    ;;
  implementation)
    printf '%s\n' 'ready'
    ;;
  plan)
    printf '  Releases (%s):\n' "$(( $(peer_organization_count) + 1 ))"
    list_cas
    printf '  Image: %s\n' "$(fabric_ca_image)"
    printf '  Generated values: %s/values/cas\n' "$FABRIC_TOOL_OUTPUT"
    printf '  Rendered manifests: %s/rendered/cas\n' "$FABRIC_TOOL_OUTPUT"
    printf '  Apply contract: render -> reject cluster scope -> server dry-run -> Helm upgrade --install -> health verify\n'
    ;;
  check)
    prepare_ca_step
    log_ok 'CA secrets, static PVCs, pinned image, and patched chart are ready'
    ;;
  render)
    require_tool_environment
    validate_config
    require_command helm
    require_command rg
    require_command yq
    [[ -d "$(ca_chart_directory)" ]] || die "Patched Bevel Fabric CA chart is missing: $(ca_chart_directory)"
    render_and_validate_all_cas
    ;;
  apply)
    prepare_ca_step
    render_and_admit_all_cas
    deploy_all_cas
    ;;
  verify)
    prepare_ca_step
    verify_all_ca_releases
    log_ok 'All generated Fabric CA releases are healthy'
    ;;
  *)
    die "Unsupported action for step 04: $ACTION"
    ;;
esac
