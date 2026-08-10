#!/usr/bin/env bash
set -euo pipefail

TOOL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export FABRIC_TOOL_ROOT="$TOOL_ROOT"
source "$TOOL_ROOT/lib/common.sh"
source "$TOOL_ROOT/lib/config.sh"
source "$TOOL_ROOT/lib/kubernetes.sh"
source "$TOOL_ROOT/lib/ca-secrets.sh"
source "$TOOL_ROOT/lib/identities.sh"

ACTION="${1:-}"
FABRIC_TOOL_TEMP=''

prepare_identity_step() {
  local missing_file ca_name _organization _admin_name _org_index1 permission

  require_tool_environment
  validate_config
  require_command kubectl
  require_command openssl
  require_command rg
  require_command yq
  configure_cluster_clients
  FABRIC_TOOL_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/fabric-tool-identities.XXXXXX")"
  export FABRIC_TOOL_TEMP
  umask 077
  trap 'rm -rf "$FABRIC_TOOL_TEMP"' EXIT

  verify_all_ca_secrets
  while IFS=$'\t' read -r ca_name _organization _admin_name _org_index1; do
    kubectl "${KUBECTL_ARGS[@]}" rollout status "statefulset/fabric-ca-server-${ca_name}" --timeout=20s >/dev/null ||
      die "Fabric CA is not Ready: $ca_name"
  done < <(list_ca_records)

  missing_file="$FABRIC_TOOL_TEMP/missing-identities.txt"
  scan_identity_secrets "$missing_file" true
  if [[ -s "$missing_file" ]]; then
    require_registration_credentials "$missing_file"
    kubectl "${KUBECTL_ARGS[@]}" get configmap kube-root-ca.crt >/dev/null 2>&1 || die 'Namespace is missing the kube-root-ca.crt ConfigMap required by the publisher'
    for permission in 'get jobs.batch' 'create jobs.batch' 'delete jobs.batch' 'get configmaps' 'create configmaps' 'patch configmaps' 'create secrets' 'get pods' 'get pods/log'; do
      # shellcheck disable=SC2086
      [[ "$(kubectl "${KUBECTL_ARGS[@]}" auth can-i $permission)" == yes ]] || die "Service account lacks required identity-enrollment permission: $permission"
    done
    log_info "Missing identities queued for enrollment: $(tr '\n' ' ' <"$missing_file" | sed 's/ $//')"
  else
    log_ok 'Every expected identity Secret pair already exists and is cryptographically valid'
  fi
  export FABRIC_TOOL_IDENTITY_SELECTION="$missing_file"
}

case "$ACTION" in
  name)
    printf '%s\n' 'Enroll and package identities'
    ;;
  implementation)
    printf '%s\n' 'ready'
    ;;
  plan)
    total_peers=$(( $(peer_organization_count) * $(peers_per_organization) ))
    printf '  Organization admins: %s\n' "$(( $(peer_organization_count) + 1 ))"
    printf '  Orderer identities:  %s\n' "$(orderer_count)"
    printf '  Peer identities:     %s\n' "$total_peers"
    printf '  CCaaS identities:    %s\n' "$(peer_organization_count)"
    printf '  Registration Secret: %s (%s)\n' "$(identity_registration_secret)" "$(identity_registration_secret_mode)"
    printf '  Renewal policy:      %s (valid identities are never replaced)\n' "$(identity_renewal_policy)"
    printf '  Execution:           in-cluster Job; no kubectl cp or pods/exec\n'
    printf '  Verification:        certificate/key pairs, CA chains, roles, expiration, and every required DNS SAN\n'
    ;;
  check)
    prepare_identity_step
    log_ok 'Fabric CAs, identity policy, RBAC, and existing identity material are ready'
    ;;
  render)
    require_tool_environment
    validate_config
    require_command openssl
    require_command rg
    require_command yq
    render_all_identity_artifacts
    ;;
  apply)
    prepare_identity_step
    if [[ ! -s "$FABRIC_TOOL_IDENTITY_SELECTION" ]]; then
      log_ok 'No enrollment required; preserve policy made no cluster changes'
      exit 0
    fi
    if selection_has_nodes "$FABRIC_TOOL_IDENTITY_SELECTION"; then
      create_registration_credentials_if_needed
      require_registration_credentials "$FABRIC_TOOL_IDENTITY_SELECTION"
    fi
    run_identity_enrollment_job "$FABRIC_TOOL_IDENTITY_SELECTION"
    ;;
  verify)
    prepare_identity_step
    [[ ! -s "$FABRIC_TOOL_IDENTITY_SELECTION" ]] || die "Identity enrollment is incomplete: $(tr '\n' ' ' <"$FABRIC_TOOL_IDENTITY_SELECTION" | sed 's/ $//')"
    log_ok 'All topology identities and their Kubernetes Secret packages are valid'
    ;;
  *)
    die "Unsupported action for step 05: $ACTION"
    ;;
esac
