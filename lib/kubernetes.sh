#!/usr/bin/env bash

configure_cluster_clients() {
  KUBECTL_ARGS=(--context "$(cluster_context)" -n "$(cluster_namespace)")
  HELM_CLUSTER_ARGS=(--kube-context "$(cluster_context)" --namespace "$(cluster_namespace)")

  if [[ "$(impersonate_service_account)" == true ]]; then
    local identity
    identity="system:serviceaccount:$(cluster_namespace):$(cluster_service_account)"
    KUBECTL_ARGS+=(--as "$identity")
    HELM_CLUSTER_ARGS+=(--kube-as-user "$identity")
  fi
}

cluster_secret_has_key() {
  local secret_name="$1"
  local key="$2"
  local encoded
  encoded="$(kubectl "${KUBECTL_ARGS[@]}" get secret "$secret_name" -o "go-template={{index .data \"$key\"}}" 2>/dev/null || true)"
  [[ -n "$encoded" ]]
}

require_cluster_secret_keys() {
  local secret_name="$1"
  shift
  local key

  kubectl "${KUBECTL_ARGS[@]}" get secret "$secret_name" >/dev/null 2>&1 || die "Missing required Secret: $secret_name"
  for key in "$@"; do
    cluster_secret_has_key "$secret_name" "$key" || die "Secret $secret_name is missing key: $key"
  done
}

cluster_secret_value() {
  local secret_name="$1"
  local key="$2"
  kubectl "${KUBECTL_ARGS[@]}" get secret "$secret_name" -o "go-template={{index .data \"$key\" | base64decode}}"
}

can_inspect_service_endpoints() {
  [[ "$(kubectl "${KUBECTL_ARGS[@]}" auth can-i get endpointslices.discovery.k8s.io)" == yes ]]
}

ready_service_endpoints() {
  local service_name="$1"
  kubectl "${KUBECTL_ARGS[@]}" get endpointslices.discovery.k8s.io \
    -l "kubernetes.io/service-name=$service_name" \
    -o 'jsonpath={.items[*].endpoints[?(@.conditions.ready==true)].addresses[0]}'
}
