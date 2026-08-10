#!/usr/bin/env bash
set -euo pipefail

TOOL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export FABRIC_TOOL_ROOT="$TOOL_ROOT"
source "$TOOL_ROOT/lib/common.sh"
source "$TOOL_ROOT/lib/config.sh"
source "$TOOL_ROOT/lib/kubernetes.sh"
source "$TOOL_ROOT/lib/ca-secrets.sh"

ACTION="${1:-}"
FABRIC_TOOL_TEMP=''

prepare_secret_checks() {
  require_tool_environment
  validate_config
  require_command kubectl
  require_command openssl
  require_command rg
  configure_cluster_clients
  FABRIC_TOOL_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/fabric-tool-ca-secrets.XXXXXX")"
  export FABRIC_TOOL_TEMP
  umask 077
  trap 'rm -rf "$FABRIC_TOOL_TEMP"' EXIT
}

case "$ACTION" in
  name)
    printf '%s\n' 'Establish secret management'
    ;;
  implementation)
    printf '%s\n' 'ready'
    ;;
  plan)
    printf '  Provider:           %s\n' "$(secret_provider)"
    printf '  Enrollment source:  %s\n' "$(enrollment_mode)"
    printf '  CA material mode:   %s\n' "$(ca_bootstrap_mode)"
    printf '  CA bootstrap sets:  %s\n' "$(( $(peer_organization_count) + 1 ))"
    printf '  Rule:               no passwords, tokens, or private keys in network YAML or generated values\n'
    ;;
  check)
    prepare_secret_checks
    kubectl config get-contexts "$(cluster_context)" -o name | grep -qx "$(cluster_context)" || die "Kubernetes context not found: $(cluster_context)"
    kubectl "${KUBECTL_ARGS[@]}" auth can-i get secrets | grep -qx yes || die 'RBAC missing: get secrets'
    if [[ "$(ca_bootstrap_mode)" == generate ]]; then
      kubectl "${KUBECTL_ARGS[@]}" auth can-i create secrets | grep -qx yes || die 'RBAC missing: create secrets'
    fi
    validate_existing_ca_secrets_if_present
    log_ok 'Secret mode, RBAC, and any existing CA secret sets are valid'
    ;;
  render)
    require_tool_environment
    validate_config
    render_ca_secret_requirements "$FABRIC_TOOL_OUTPUT/secrets/requirements.yaml"
    ;;
  apply)
    prepare_secret_checks
    render_ca_secret_requirements "$FABRIC_TOOL_OUTPUT/secrets/requirements.yaml"
    if [[ "$(ca_bootstrap_mode)" == generate ]]; then
      create_development_ca_secrets
    else
      log_info "External CA material mode: provision every item in $FABRIC_TOOL_OUTPUT/secrets/requirements.yaml"
    fi
    ;;
  verify)
    prepare_secret_checks
    [[ -f "$FABRIC_TOOL_OUTPUT/secrets/requirements.yaml" ]] || die 'CA secret requirements artifact is missing'
    [[ "$(yq e -r '.metadata.configSha256' "$FABRIC_TOOL_OUTPUT/secrets/requirements.yaml")" == "$FABRIC_TOOL_CONFIG_SHA" ]] || die 'CA secret requirements artifact is stale'
    verify_all_ca_secrets
    log_ok 'All CA bootstrap and certificate Secrets are ready'
    ;;
  *)
    die "Unsupported action for step 03: $ACTION"
    ;;
esac
