#!/usr/bin/env bash

reset_expected_purge_confirmation() {
  printf '%s:%s:%s:PURGE' "$(network_name)" "$(cluster_context)" "$(cluster_namespace)"
}

reset_require_confirmation() {
  [[ "$RESET_CONFIRM_NAME" == "$(network_name)" ]] || \
    die "reset requires --confirm $(network_name)"
  [[ "$RESET_CONFIRM_CONTEXT" == "$(cluster_context)" ]] || \
    die "reset requires --confirm-context $(cluster_context)"
  [[ "$RESET_CONFIRM_NAMESPACE" == "$(cluster_namespace)" ]] || \
    die "reset requires --confirm-namespace $(cluster_namespace)"

  if [[ "$RESET_PURGE_DATA" == true ]]; then
    [[ "$(environment_name)" == development ]] || \
      die 'Refusing --purge-data outside a development environment'
    [[ "$(cluster_context)" == kind-* ]] || \
      die 'Refusing --purge-data outside a kind-* Kubernetes context'
    [[ "$RESET_CONFIRM_PURGE" == "$(reset_expected_purge_confirmation)" ]] || \
      die "--purge-data requires --confirm-purge $(reset_expected_purge_confirmation)"
  elif [[ -n "$RESET_CONFIRM_PURGE" ]]; then
    die '--confirm-purge is valid only with --purge-data'
  fi
}

reset_require_rbac() {
  local resource
  for resource in jobs configmaps deployments services statefulsets secrets; do
    kubectl "${KUBECTL_ARGS[@]}" auth can-i delete "$resource" --quiet || \
      die "Configured cluster identity cannot delete $resource in namespace $(cluster_namespace)"
  done
  if [[ "$RESET_PURGE_DATA" == true ]]; then
    kubectl "${KUBECTL_ARGS[@]}" auth can-i delete persistentvolumeclaims --quiet || \
      die "Configured cluster identity cannot delete persistentvolumeclaims in namespace $(cluster_namespace)"
  fi
}

reset_delete_resource() {
  local resource="$1"
  local name="$2"
  [[ -n "$name" ]] || die "Refusing to delete an unnamed $resource"
  is_rfc1123_label "$name" || die "Refusing to delete $resource with invalid generated name: $name"
  kubectl "${KUBECTL_ARGS[@]}" delete "$resource" "$name" \
    --ignore-not-found=true --wait=true --timeout=10m >/dev/null
}

reset_delete_resources_with_prefix() {
  local resource="$1"
  local prefix="$2"
  local objects names name
  [[ -n "$prefix" && "$prefix" == *- ]] || \
    die "Refusing unsafe $resource deletion prefix: $prefix"
  objects="$(kubectl "${KUBECTL_ARGS[@]}" get "$resource" -o json)"
  names="$(printf '%s' "$objects" | jq -r --arg prefix "$prefix" \
    '.items[].metadata.name | select(startswith($prefix))')"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    reset_delete_resource "$resource" "$name"
  done <<<"$names"
}

reset_uninstall_release() {
  local release="$1"
  is_rfc1123_label "$release" || die "Refusing to uninstall invalid Helm release name: $release"
  if helm status "$release" "${HELM_CLUSTER_ARGS[@]}" >/dev/null 2>&1; then
    helm uninstall "$release" "${HELM_CLUSTER_ARGS[@]}" \
      --wait --timeout 10m >/dev/null
    log_ok "Removed Helm release: $release"
  else
    log_info "Helm release already absent: $release"
  fi
}

reset_print_scope() {
  local mode='workloads and lifecycle evidence; Secrets and PVCs preserved'
  if [[ "$RESET_PURGE_DATA" == true ]]; then
    mode='workloads, lifecycle evidence, generated Fabric Secrets, and configured PVC claims'
  fi
  cat <<EOF

Reset scope
  network:   $(network_name)
  context:   $(cluster_context)
  namespace: $(cluster_namespace)
  mode:      $mode
EOF
  if [[ "$RESET_PURGE_DATA" == true ]]; then
    cat <<'EOF'
  warning:   PVC deletion can permanently destroy ledger and CA data.
             existingClaims storage must be reprovisioned before the next apply.
EOF
  fi
}

reset_remove_lifecycle_resources() {
  local identity_job org_index1 org_name cc_name service_name
  identity_job="$(identity_job_name)"

  # Stop and remove mutating/evidence Jobs before removing their dependencies.
  reset_delete_resource job "$identity_job"
  reset_delete_resource configmap "${identity_job}-config"
  for prefix in \
    "$(chaincode_operation_name)-" \
    "$(peer_channel_operation_name)-" \
    "$(channel_operation_name)-"
  do
    reset_delete_resources_with_prefix job "$prefix"
    reset_delete_resources_with_prefix configmap "$prefix"
  done

  # CCaaS resources use generated, version-bound Deployment names and stable Services.
  for ((org_index1 = 1; org_index1 <= $(peer_organization_count); org_index1++)); do
    org_name="$(peer_organization_name "$org_index1")"
    cc_name="$(chaincode_kubernetes_name "$org_index1" "$org_name")"
    service_name="$(chaincode_service_name "$org_index1" "$org_name" "$cc_name")"
    reset_delete_resource deployment "$cc_name"
    reset_delete_resource service "$service_name"
    if [[ "$service_name" != "$cc_name" ]]; then
      # Remove a deterministic pre-stable-service resource left by older tool revisions.
      reset_delete_resource service "$cc_name"
    fi
    reset_delete_resource configmap "$(chaincode_package_configmap "$org_index1" "$org_name")"
  done
  reset_delete_resource configmap "$(chaincode_receipt_name)"
}

reset_remove_helm_releases() {
  local org_index1 org_name peer_index0 peer_name orderer_index0
  local ca_name _organization _admin_name _ca_org_index1

  # Reverse dependency order: peers, orderers, then certificate authorities.
  for ((org_index1 = 1; org_index1 <= $(peer_organization_count); org_index1++)); do
    org_name="$(peer_organization_name "$org_index1")"
    for ((peer_index0 = 0; peer_index0 < $(peers_per_organization); peer_index0++)); do
      peer_name="$(peer_kubernetes_name "$org_index1" "$peer_index0" "$org_name")"
      reset_uninstall_release "$peer_name"
    done
  done
  for ((orderer_index0 = 0; orderer_index0 < $(orderer_count); orderer_index0++)); do
    reset_uninstall_release "$(orderer_kubernetes_name "$orderer_index0")"
  done
  while IFS=$'\t' read -r ca_name _organization _admin_name _ca_org_index1; do
    reset_uninstall_release "$ca_name"
  done < <(list_ca_records)
}

reset_purge_generated_secrets() {
  local msp_secret tls_secret
  local org_index1 org_name peer_index0 peer_name
  local ca_record_name _kind _ca_name _identity _role _hosts
  local _organization _admin_name _ca_org_index1

  # Step 5 creates these identities, regardless of who supplied CA registration input.
  while IFS=$'\t' read -r _kind _ca_name _identity _role msp_secret tls_secret _hosts; do
    reset_delete_resource secret "$msp_secret"
    reset_delete_resource secret "$tls_secret"
  done < <(list_identity_records)

  if [[ "$(identity_registration_secret_mode)" == generate ]]; then
    reset_delete_resource secret "$(identity_registration_secret)"
  fi
  if [[ "$(couchdb_credentials_mode)" == generate ]]; then
    for ((org_index1 = 1; org_index1 <= $(peer_organization_count); org_index1++)); do
      org_name="$(peer_organization_name "$org_index1")"
      for ((peer_index0 = 0; peer_index0 < $(peers_per_organization); peer_index0++)); do
        peer_name="$(peer_kubernetes_name "$org_index1" "$peer_index0" "$org_name")"
        reset_delete_resource secret "$(couchdb_credential_secret_name "$peer_name")"
      done
    done
  fi
  if [[ "$(ca_bootstrap_mode)" == generate ]]; then
    while IFS=$'\t' read -r ca_record_name _organization _admin_name _ca_org_index1; do
      reset_delete_resource secret "${ca_record_name}-bootstrap"
      reset_delete_resource secret "${ca_record_name}-certs"
    done < <(list_ca_records)
  fi

  log_info 'Preserved the externally supplied image-pull Secret'
}

reset_purge_claims() {
  local ca_name organization _admin_name org_index1
  local orderer_index0 orderer_name peer_index0 peer_name

  while IFS=$'\t' read -r ca_name organization _admin_name org_index1; do
    reset_delete_resource persistentvolumeclaim \
      "$(ca_pvc_name "$org_index1" "$organization" "$ca_name")"
  done < <(list_ca_records)
  for ((orderer_index0 = 0; orderer_index0 < $(orderer_count); orderer_index0++)); do
    orderer_name="$(orderer_kubernetes_name "$orderer_index0")"
    reset_delete_resource persistentvolumeclaim \
      "$(orderer_pvc_name "$orderer_index0" "$orderer_name")"
  done
  for ((org_index1 = 1; org_index1 <= $(peer_organization_count); org_index1++)); do
    organization="$(peer_organization_name "$org_index1")"
    for ((peer_index0 = 0; peer_index0 < $(peers_per_organization); peer_index0++)); do
      peer_name="$(peer_kubernetes_name "$org_index1" "$peer_index0" "$organization")"
      reset_delete_resource persistentvolumeclaim \
        "$(peer_pvc_name "$org_index1" "$peer_index0" "$organization" "$peer_name")"
      reset_delete_resource persistentvolumeclaim \
        "$(couchdb_pvc_name "$org_index1" "$peer_index0" "$organization" "$peer_name")"
    done
  done
}

reset_clear_local_completion_state() {
  local state_file
  for state_file in "$STATE_DIR"/[0-9][0-9].done; do
    [[ -e "$state_file" ]] || continue
    rm -f "$state_file"
  done
  log_ok "Cleared local completion records under $STATE_DIR"
}

reset_network() {
  require_command kubectl
  require_command helm
  require_command jq
  reset_require_confirmation
  configure_cluster_clients
  kubectl "${KUBECTL_ARGS[@]}" get namespace "$(cluster_namespace)" >/dev/null
  reset_require_rbac
  reset_print_scope

  reset_remove_lifecycle_resources
  reset_remove_helm_releases
  if [[ "$RESET_PURGE_DATA" == true ]]; then
    reset_purge_generated_secrets
    reset_purge_claims
  fi
  reset_clear_local_completion_state

  log_ok "Reset completed for $(network_name) in $(cluster_context)/$(cluster_namespace)"
}
