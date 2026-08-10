#!/usr/bin/env bash
set -euo pipefail

TOOL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export FABRIC_TOOL_ROOT="$TOOL_ROOT"
source "$TOOL_ROOT/lib/common.sh"
source "$TOOL_ROOT/lib/config.sh"
source "$TOOL_ROOT/lib/kubernetes.sh"

ACTION="${1:-}"

check_permission() {
  local verb="$1"
  local resource="$2"
  local answer
  answer="$(kubectl "${KUBECTL_ARGS[@]}" auth can-i "$verb" "$resource")"
  [[ "$answer" == yes ]] || {
    log_warn "RBAC missing: $verb $resource"
    return 1
  }
}

check_existing_claim() {
  local pvc="$1"
  local phase
  if ! kubectl "${KUBECTL_ARGS[@]}" get pvc "$pvc" >/dev/null 2>&1; then
    log_warn "Expected existing PVC is missing: $pvc"
    return 1
  fi
  phase="$(kubectl "${KUBECTL_ARGS[@]}" get pvc "$pvc" -o jsonpath='{.status.phase}')"
  [[ "$phase" == Bound ]] || {
    log_warn "PVC is not Bound: $pvc ($phase)"
    return 1
  }
}

platform_check() {
  local failures=0 verb resource
  local orderers orgs peers orderer_index0 org_index1 peer_index0
  local org_name ca_name peer_name

  require_tool_environment
  validate_config
  require_command kubectl
  configure_cluster_clients

  kubectl config get-contexts "$(cluster_context)" -o name | grep -qx "$(cluster_context)" || die "Kubernetes context not found: $(cluster_context)"
  kubectl "${KUBECTL_ARGS[@]}" get pods --request-timeout=10s >/dev/null || die "Cannot read namespace $(cluster_namespace) through context $(cluster_context)"

  while read -r verb resource; do
    check_permission "$verb" "$resource" || failures=$((failures + 1))
  done <<'PERMISSIONS'
get pods
list pods
watch pods
create pods
delete pods
get pods/log
get persistentvolumeclaims
list persistentvolumeclaims
create persistentvolumeclaims
patch persistentvolumeclaims
get configmaps
list configmaps
create configmaps
patch configmaps
get secrets
list secrets
create secrets
patch secrets
get services
list services
create services
patch services
get statefulsets.apps
list statefulsets.apps
watch statefulsets.apps
create statefulsets.apps
patch statefulsets.apps
get jobs.batch
list jobs.batch
watch jobs.batch
create jobs.batch
delete jobs.batch
PERMISSIONS

  if ! check_permission get resourcequotas; then
    log_warn 'Quota visibility is optional; ask the platform team to confirm headroom before a real apply'
  fi
  if ! check_permission get endpointslices.discovery.k8s.io; then
    log_warn 'EndpointSlice visibility is optional; workload and Service readiness will be verified without it'
  fi

  if [[ "$(storage_mode)" == existingClaims ]]; then
    orderers="$(orderer_count)"
    orgs="$(peer_organization_count)"
    peers="$(peers_per_organization)"

    ca_name="$(ca_kubernetes_name "$(orderer_organization_name)")"
    check_existing_claim "$(ca_pvc_name 0 "$(orderer_organization_name)" "$ca_name")" || failures=$((failures + 1))
    for ((orderer_index0 = 0; orderer_index0 < orderers; orderer_index0++)); do
      check_existing_claim "$(orderer_pvc_name "$orderer_index0" "$(orderer_kubernetes_name "$orderer_index0")")" || failures=$((failures + 1))
    done
    for ((org_index1 = 1; org_index1 <= orgs; org_index1++)); do
      org_name="$(peer_organization_name "$org_index1")"
      ca_name="$(ca_kubernetes_name "$org_name" "$org_index1")"
      check_existing_claim "$(ca_pvc_name "$org_index1" "$org_name" "$ca_name")" || failures=$((failures + 1))
      for ((peer_index0 = 0; peer_index0 < peers; peer_index0++)); do
        peer_name="$(peer_kubernetes_name "$org_index1" "$peer_index0" "$org_name")"
        check_existing_claim "$(peer_pvc_name "$org_index1" "$peer_index0" "$org_name" "$peer_name")" || failures=$((failures + 1))
        check_existing_claim "$(couchdb_pvc_name "$org_index1" "$peer_index0" "$org_name" "$peer_name")" || failures=$((failures + 1))
      done
    done
  fi

  ((failures == 0)) || die "$failures platform prerequisite(s) failed"
  log_ok 'Namespace access, RBAC, and expected PVCs are ready'
}

case "$ACTION" in
  name)
    printf '%s\n' 'Verify Kubernetes platform'
    ;;
  implementation)
    printf '%s\n' 'ready'
    ;;
  plan)
    printf '  Context/namespace: %s / %s\n' "$(cluster_context)" "$(cluster_namespace)"
    printf '  Access model:      namespace-scoped'
    if [[ "$(impersonate_service_account)" == true ]]; then
      printf ' as serviceaccount/%s\n' "$(cluster_service_account)"
    else
      printf ' as current credential\n'
    fi
    printf '  Storage mode:      %s\n' "$(storage_mode)"
    printf '  Action:            read-only RBAC, namespace, optional quota visibility, and PVC checks\n'
    ;;
  check)
    platform_check
    ;;
  render)
    log_info 'Step 02 has no generated artifacts; the platform contract is represented in inventory.yaml'
    ;;
  apply)
    log_info 'Platform resources are cluster-admin inputs in limited-access mode; this step performs no Kubernetes writes'
    ;;
  verify)
    platform_check
    ;;
  *)
    die "Unsupported action for step 02: $ACTION"
    ;;
esac
