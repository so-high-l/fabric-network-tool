#!/usr/bin/env bash

peer_chart_directory() {
  local configured
  configured="$(config_value '.spec.deployment.peerChart // ""')"
  if [[ -z "$configured" ]]; then
    printf '%s' "$FABRIC_TOOL_ROOT/charts/fabric-peernode"
  elif [[ "$configured" == /* ]]; then
    printf '%s' "$configured"
  else
    printf '%s/%s' "$FABRIC_TOOL_CALLER_DIR" "${configured#./}"
  fi
}

peer_values_file() {
  printf '%s/values/peers/%s.yaml' "$FABRIC_TOOL_OUTPUT" "$1"
}

peer_render_file() {
  printf '%s/rendered/peers/%s.yaml' "$FABRIC_TOOL_OUTPUT" "$1"
}

couchdb_requirements_file() {
  printf '%s/secrets/couchdb-requirements.yaml' "$FABRIC_TOOL_OUTPUT"
}

couchdb_credential_secret_name() {
  printf '%s-couchdb' "$1"
}

peer_gossip_bootstrap() {
  local org_index1="$1" peer_index0="$2" org_name="$3" target_index target_name
  if (( $(peers_per_organization) > 1 )); then
    if ((peer_index0 == 0)); then
      target_index=1
    else
      target_index=0
    fi
  else
    target_index=0
  fi
  target_name="$(peer_kubernetes_name "$org_index1" "$target_index" "$org_name")"
  printf '%s:7051' "$(service_fqdn "$target_name")"
}

peer_gossip_external_endpoint() {
  local peer_name="$1"
  if [[ "$(external_dns_enabled)" == true ]]; then
    printf '%s.%s:7051' "$peer_name" "$(external_dns_domain)"
  else
    printf '%s:7051' "$(service_fqdn "$peer_name")"
  fi
}

render_couchdb_requirements() {
  local destination temp_file org_index1 org_name peer_index0 peer_name secret_name
  destination="$(couchdb_requirements_file)"
  temp_file="$(mktemp "${TMPDIR:-/tmp}/fabric-couchdb-requirements.XXXXXX")"
  {
    printf 'apiVersion: fabric.network.tools/v1alpha1\n'
    printf 'kind: FabricSecretRequirements\n'
    printf 'metadata:\n'
    printf '  name: %s-couchdb\n' "$(network_name)"
    printf '  configSha256: %s\n' "$FABRIC_TOOL_CONFIG_SHA"
    printf 'spec:\n'
    printf '  namespace: %s\n' "$(cluster_namespace)"
    printf '  provider: %s\n' "$(secret_provider)"
    printf '  mode: %s\n' "$(couchdb_credentials_mode)"
    printf '  items:\n'
    for ((org_index1 = 1; org_index1 <= $(peer_organization_count); org_index1++)); do
      org_name="$(peer_organization_name "$org_index1")"
      for ((peer_index0 = 0; peer_index0 < $(peers_per_organization); peer_index0++)); do
        peer_name="$(peer_kubernetes_name "$org_index1" "$peer_index0" "$org_name")"
        secret_name="$(couchdb_credential_secret_name "$peer_name")"
        printf '    - name: %s\n' "$secret_name"
        printf '      purpose: couchdb-credentials\n'
        printf '      peer: %s\n' "$peer_name"
        printf '      requiredKeys: [username, password]\n'
      done
    done
  } >"$temp_file"
  yq e '.' "$temp_file" >/dev/null
  write_if_changed "$temp_file" "$destination"
}

render_peer_values() {
  local org_index1="$1" peer_index0="$2" org_name="$3" peer_name="$4"
  local peer_pvc="$5" couchdb_pvc="$6" destination temp_file pull_secret
  local credential_secret orderer0
  destination="$(peer_values_file "$peer_name")"
  temp_file="$(mktemp "${TMPDIR:-/tmp}/fabric-peer-values.XXXXXX")"
  pull_secret="$(image_pull_secret)"
  credential_secret="$(couchdb_credential_secret_name "$peer_name")"
  orderer0="$(orderer_kubernetes_name 0)"

  {
    printf 'global:\n'
    printf '  version: %s\n' "$(fabric_version)"
    printf '  serviceAccountName: %s\n' "$(cluster_service_account)"
    printf '  cluster: {provider: namespace-scoped, cloudNativeServices: false}\n'
    printf '  vault: {type: kubernetes, address: "", authPath: "", role: "", secretEngine: "", secretPrefix: "", tls: false}\n'
    printf '  proxy: {provider: none, externalUrlSuffix: %s}\n' "$(fabric_network_domain)"
    printf 'automountServiceAccountToken: false\n'
    printf 'image:\n'
    printf '  peer: %s\n' "$(fabric_peer_image)"
    printf '  couchdb: %s\n' "$(couchdb_image)"
    if [[ -n "$pull_secret" ]]; then
      printf '  pullSecret: %s\n' "$pull_secret"
    else
      printf '  pullSecret: ""\n'
    fi
    printf 'tags: {storage: false, bevel: false}\n'
    printf 'storage:\n'
    printf '  enabled: false\n'
    printf '  peerExistingClaim: %s\n' "$peer_pvc"
    printf '  couchdbExistingClaim: %s\n' "$couchdb_pvc"
    printf 'certs: {generateCertificates: false, useKubernetesSecrets: true}\n'
    printf 'grpcWeb: {enabled: false}\n'
    printf 'podSecurityContext:\n'
    printf '  enabled: true\n'
    printf '  runAsNonRoot: true\n'
    printf '  runAsUser: 1000\n'
    printf '  runAsGroup: 1000\n'
    printf '  fsGroup: 1000\n'
    printf '  seccompProfile: {type: RuntimeDefault}\n'
    printf 'containerSecurityContext:\n'
    printf '  enabled: true\n'
    printf '  allowPrivilegeEscalation: false\n'
    printf '  capabilities: {drop: [ALL]}\n'
    printf 'sidecarResources:\n'
    printf '  couchdb:\n'
    printf '    requests: {cpu: 250m, memory: 512Mi}\n'
    printf '    limits: {cpu: "1", memory: 2Gi}\n'
    printf 'peer:\n'
    printf '  vmEndpoint: ""\n'
    printf '  dockerSocket: {enabled: false}\n'
    printf '  gossipPeerAddress: %s\n' "$(peer_gossip_bootstrap "$org_index1" "$peer_index0" "$org_name")"
    printf '  gossipExternalEndpoint: %s\n' "$(peer_gossip_external_endpoint "$peer_name")"
    printf '  logLevel: %s\n' "$(peer_log_level)"
    printf '  localMspId: %s\n' "$(peer_organization_msp_id "$org_index1" "$org_name")"
    printf '  tlsStatus: true\n'
    printf '  operationsTLS: %s\n' "$(operations_tls_enabled)"
    printf '  cliEnabled: false\n'
    printf '  ordererAddress: %s:7050\n' "$(service_fqdn "$orderer0")"
    printf '  serviceType: ClusterIP\n'
    printf '  ports:\n'
    printf '    grpc: {clusterIpPort: 7051}\n'
    printf '    events: {clusterIpPort: 7053}\n'
    printf '    couchdb: {clusterIpPort: 5984, expose: false}\n'
    printf '    metrics: {enabled: false, clusterIpPort: 9443}\n'
    printf '  couchdb:\n'
    printf '    username: ""\n'
    printf '    password: ""\n'
    printf '    existingSecret: %s\n' "$credential_secret"
    printf '    usernameKey: username\n'
    printf '    passwordKey: password\n'
    printf '    manageFilePermissions: false\n'
    printf '    probes:\n'
    printf '      enabled: true\n'
    printf '      startup: {periodSeconds: 2, failureThreshold: 60}\n'
    printf '      readiness: {periodSeconds: 5, failureThreshold: 6}\n'
    printf '      liveness: {periodSeconds: 10, failureThreshold: 6}\n'
    printf '  resources:\n'
    printf '    requests: {cpu: 250m, memory: 512Mi}\n'
    printf '    limits: {cpu: "1", memory: 1Gi}\n'
    printf '  probes:\n'
    printf '    enabled: true\n'
    printf '    startup: {periodSeconds: 2, failureThreshold: 60}\n'
    printf '    readiness: {periodSeconds: 5, failureThreshold: 6}\n'
    printf '    liveness: {periodSeconds: 10, failureThreshold: 6}\n'
  } >"$temp_file"

  yq e '.' "$temp_file" >/dev/null
  write_if_changed "$temp_file" "$destination"
}

render_all_peer_values() {
  local org_index1 org_name peer_index0 peer_name peer_pvc couchdb_pvc
  render_couchdb_requirements
  for ((org_index1 = 1; org_index1 <= $(peer_organization_count); org_index1++)); do
    org_name="$(peer_organization_name "$org_index1")"
    for ((peer_index0 = 0; peer_index0 < $(peers_per_organization); peer_index0++)); do
      peer_name="$(peer_kubernetes_name "$org_index1" "$peer_index0" "$org_name")"
      peer_pvc="$(peer_pvc_name "$org_index1" "$peer_index0" "$org_name" "$peer_name")"
      couchdb_pvc="$(couchdb_pvc_name "$org_index1" "$peer_index0" "$org_name" "$peer_name")"
      render_peer_values "$org_index1" "$peer_index0" "$org_name" "$peer_name" "$peer_pvc" "$couchdb_pvc"
    done
  done
}

validate_peer_render() {
  local peer_name="$1" expected_peer_pvc="$2" expected_couchdb_pvc="$3" expected_bootstrap="$4" expected_external="$5" render_file="$6"
  local statefulset_name forbidden wrong_namespace workload_count service_count config_count
  local unsafe_image unsafe_container missing_resources init_count container_count pull_secret
  local expected_probe_scheme actual secret_name core_file
  statefulset_name="fabric-peernode-${peer_name}"
  pull_secret="$(image_pull_secret)"
  secret_name="$(couchdb_credential_secret_name "$peer_name")"

  forbidden="$(yq e 'select(.kind == "Namespace" or .kind == "StorageClass" or .kind == "PersistentVolume" or .kind == "ClusterRole" or .kind == "ClusterRoleBinding" or .kind == "CustomResourceDefinition" or .kind == "Role" or .kind == "RoleBinding" or .kind == "ServiceAccount" or .kind == "MutatingWebhookConfiguration" or .kind == "ValidatingWebhookConfiguration") | .kind + "/" + .metadata.name' "$render_file")"
  [[ -z "$forbidden" ]] || die "Forbidden cluster/platform resource rendered for $peer_name: $forbidden"
  wrong_namespace="$(yq e 'select(.kind != null and .metadata.namespace != "'"$(cluster_namespace)"'") | .kind + "/" + .metadata.name' "$render_file")"
  [[ -z "$wrong_namespace" ]] || die "Peer resource rendered outside namespace $(cluster_namespace): $wrong_namespace"

  workload_count="$(yq ea '[select(.kind == "StatefulSet")] | length' "$render_file")"
  service_count="$(yq ea '[select(.kind == "Service")] | length' "$render_file")"
  config_count="$(yq ea '[select(.kind == "ConfigMap")] | length' "$render_file")"
  [[ "$workload_count" == 1 && "$service_count" == 1 && "$config_count" == 3 ]] || die "$peer_name must render exactly one StatefulSet, one Service, and three ConfigMaps"
  [[ "$(yq e -r 'select(.kind == "StatefulSet") | .metadata.name' "$render_file")" == "$statefulset_name" ]] || die "Unexpected StatefulSet name for $peer_name"
  [[ "$(yq e -r 'select(.kind == "Service") | .metadata.name' "$render_file")" == "$peer_name" ]] || die "Unexpected Service name for $peer_name"

  init_count="$(yq e -r 'select(.kind == "StatefulSet") | (.spec.template.spec.initContainers // []) | length' "$render_file")"
  container_count="$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.containers | length' "$render_file")"
  [[ "$init_count" == 0 && "$container_count" == 2 ]] || die "$peer_name must render zero init containers and exactly peer plus CouchDB"
  [[ "$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.automountServiceAccountToken' "$render_file")" == false ]] || die "$peer_name must not automount a ServiceAccount token"
  [[ "$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.serviceAccountName' "$render_file")" == "$(cluster_service_account)" ]] || die "$peer_name rendered the wrong ServiceAccount"
  [[ "$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.securityContext.runAsNonRoot' "$render_file")" == true ]] || die "$peer_name is missing runAsNonRoot"

  unsafe_image="$(yq e '.. | select(tag == "!!map" and has("image")) | .image | select(test(":latest($|@)") or (contains("@sha256:") | not))' "$render_file")"
  [[ -z "$unsafe_image" ]] || die "$peer_name contains an unpinned image: $unsafe_image"
  unsafe_container="$(yq e 'select(.kind == "StatefulSet") as $w | [$w.spec.template.spec.initContainers[]?, $w.spec.template.spec.containers[]?] | .[] | select(.securityContext.allowPrivilegeEscalation != false or ((.securityContext.capabilities.drop // []) | contains(["ALL"]) | not)) | .name' "$render_file")"
  [[ -z "$unsafe_container" ]] || die "$peer_name container securityContext is incomplete: $unsafe_container"
  missing_resources="$(yq e 'select(.kind == "StatefulSet") as $w | [$w.spec.template.spec.initContainers[]?, $w.spec.template.spec.containers[]?] | .[] | select(.resources.requests.cpu == null or .resources.requests.memory == null or .resources.limits.cpu == null or .resources.limits.memory == null) | .name' "$render_file")"
  [[ -z "$missing_resources" ]] || die "$peer_name container resources are incomplete: $missing_resources"
  [[ "$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.containers[] | select(.name == "'"$peer_name"'") | .image' "$render_file")" == "$(fabric_peer_image)" ]] || die "$peer_name rendered the wrong Fabric peer image"
  [[ "$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.containers[] | select(.name == "couchdb") | .image' "$render_file")" == "$(couchdb_image)" ]] || die "$peer_name rendered the wrong CouchDB image"

  [[ "$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.volumes[] | select(.name == "datadir") | .persistentVolumeClaim.claimName' "$render_file")" == "$expected_peer_pvc" ]] || die "$peer_name rendered the wrong peer PVC"
  [[ "$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.volumes[] | select(.name == "datadir-couchdb") | .persistentVolumeClaim.claimName' "$render_file")" == "$expected_couchdb_pvc" ]] || die "$peer_name rendered the wrong CouchDB PVC"
  [[ "$(yq e -r 'select(.kind == "StatefulSet") | (.spec.volumeClaimTemplates // []) | length' "$render_file")" == 0 ]] || die "$peer_name rendered unexpected dynamic PVC templates"
  [[ -z "$(yq e 'select(.kind == "StatefulSet") | .spec.template.spec.volumes[]? | select(has("hostPath")) | .name' "$render_file")" ]] || die "$peer_name rendered a forbidden hostPath"

  for actual in "${peer_name}-msp" "${peer_name}-tls"; do
    [[ -n "$(yq e 'select(.kind == "StatefulSet") | .spec.template.spec.volumes[] | select(.name == "certificates") | .projected.sources[].secret.name | select(. == "'"$actual"'")' "$render_file")" ]] || die "$peer_name does not project identity Secret $actual"
  done
  actual="$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.containers[] | select(.name == "couchdb") | .env[] | select(.name == "COUCHDB_PASSWORD") | .valueFrom.secretKeyRef.name' "$render_file")"
  [[ "$actual" == "$secret_name" ]] || die "$peer_name CouchDB container does not use credential Secret $secret_name"
  actual="$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.containers[] | select(.name == "'"$peer_name"'") | .env[] | select(.name == "CORE_LEDGER_STATE_COUCHDBCONFIG_PASSWORD") | .valueFrom.secretKeyRef.name' "$render_file")"
  [[ "$actual" == "$secret_name" ]] || die "$peer_name Fabric container does not use credential Secret $secret_name"

  [[ "$(yq e -r 'select(.kind == "Service") | .spec.clusterIP' "$render_file")" == None ]] || die "$peer_name Service must be headless"
  for actual in grpc events operations; do
    [[ -n "$(yq e 'select(.kind == "Service") | .spec.ports[] | select(.name == "'"$actual"'") | .port' "$render_file")" ]] || die "$peer_name Service is missing port $actual"
  done
  [[ -z "$(yq e 'select(.kind == "Service") | .spec.ports[] | select(.name == "couchdb" or .name == "grpc-web") | .name' "$render_file")" ]] || die "$peer_name exposes disabled CouchDB or gRPC-Web ports"

  [[ "$(yq e -r 'select(.kind == "ConfigMap" and .metadata.name == "'"${peer_name}-config"'") | .data.CORE_VM_ENDPOINT' "$render_file")" == "" ]] || die "$peer_name still configures a Docker VM endpoint"
  [[ "$(yq e -r 'select(.kind == "ConfigMap" and .metadata.name == "'"${peer_name}-config"'") | .data.CORE_LEDGER_STATE_STATEDATABASE' "$render_file")" == CouchDB ]] || die "$peer_name is not configured for CouchDB"
  [[ "$(yq e -r 'select(.kind == "ConfigMap" and .metadata.name == "'"${peer_name}-config"'") | .data.CORE_PEER_GOSSIP_BOOTSTRAP' "$render_file")" == "$expected_bootstrap" ]] || die "$peer_name rendered the wrong gossip bootstrap"
  [[ "$(yq e -r 'select(.kind == "ConfigMap" and .metadata.name == "'"${peer_name}-config"'") | .data.CORE_PEER_GOSSIP_EXTERNALENDPOINT' "$render_file")" == "$expected_external" ]] || die "$peer_name rendered the wrong gossip external endpoint"
  [[ "$(yq e -r 'select(.kind == "ConfigMap" and .metadata.name == "'"${peer_name}-config"'") | .data.CORE_OPERATIONS_TLS_ENABLED' "$render_file")" == "$(operations_tls_enabled)" ]] || die "$peer_name rendered the wrong operations TLS mode"

  if [[ "$(operations_tls_enabled)" == true ]]; then expected_probe_scheme=HTTPS; else expected_probe_scheme=HTTP; fi
  for actual in startupProbe readinessProbe livenessProbe; do
    [[ "$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.containers[] | select(.name == "'"$peer_name"'") | .'"$actual"'.httpGet.scheme' "$render_file")" == "$expected_probe_scheme" ]] || die "$peer_name $actual uses the wrong scheme"
  done
  [[ "$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.containers[] | select(.name == "couchdb") | .readinessProbe.tcpSocket.port' "$render_file")" == couchdb ]] || die "$peer_name CouchDB readiness probe is missing"

  core_file="$(mktemp "${TMPDIR:-/tmp}/fabric-peer-core.XXXXXX")"
  yq e -r 'select(.kind == "ConfigMap" and .metadata.name == "'"${peer_name}-builders-config"'") | .data."core.yaml"' "$render_file" >"$core_file"
  yq e '.' "$core_file" >/dev/null || die "$peer_name rendered invalid core.yaml"
  [[ "$(yq e -r '.vm.endpoint' "$core_file")" == "" ]] || die "$peer_name core.yaml still configures a VM endpoint"
  [[ "$(yq e -r '.chaincode.externalBuilders[] | select(.name == "ccaas_builder") | .path' "$core_file")" == /opt/hyperledger/ccaas_builder ]] || die "$peer_name lacks the CCaaS external builder"
  rm -f "$core_file"

  if [[ -n "$pull_secret" ]]; then
    [[ "$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.imagePullSecrets[0].name' "$render_file")" == "$pull_secret" ]] || die "$peer_name rendered the wrong imagePullSecret"
  fi
  if rg -q 'REPLACE_WITH|supplychain-userpw|kind: Ingress|kind: ServiceMonitor' "$render_file"; then
    die "$peer_name rendered an unsafe placeholder, ingress, or monitoring CR"
  fi
}

render_and_validate_all_peers() {
  local chart_dir org_index1 org_name peer_index0 peer_name peer_pvc couchdb_pvc values_file render_file temp_file
  chart_dir="$(peer_chart_directory)"
  render_all_peer_values
  for ((org_index1 = 1; org_index1 <= $(peer_organization_count); org_index1++)); do
    org_name="$(peer_organization_name "$org_index1")"
    for ((peer_index0 = 0; peer_index0 < $(peers_per_organization); peer_index0++)); do
      peer_name="$(peer_kubernetes_name "$org_index1" "$peer_index0" "$org_name")"
      peer_pvc="$(peer_pvc_name "$org_index1" "$peer_index0" "$org_name" "$peer_name")"
      couchdb_pvc="$(couchdb_pvc_name "$org_index1" "$peer_index0" "$org_name" "$peer_name")"
      values_file="$(peer_values_file "$peer_name")"
      render_file="$(peer_render_file "$peer_name")"
      temp_file="$(mktemp "${TMPDIR:-/tmp}/fabric-peer-render.XXXXXX")"
      helm template "$peer_name" "$chart_dir" --namespace "$(cluster_namespace)" -f "$values_file" >"$temp_file"
      yq e '.' "$temp_file" >/dev/null
      write_if_changed "$temp_file" "$render_file"
      validate_peer_render "$peer_name" "$peer_pvc" "$couchdb_pvc" \
        "$(peer_gossip_bootstrap "$org_index1" "$peer_index0" "$org_name")" \
        "$(peer_gossip_external_endpoint "$peer_name")" "$render_file"
      log_ok "Rendered and validated peer release: $peer_name"
    done
  done
}

admit_all_peer_renders() {
  local org_index1 org_name peer_index0 peer_name render_file
  for ((org_index1 = 1; org_index1 <= $(peer_organization_count); org_index1++)); do
    org_name="$(peer_organization_name "$org_index1")"
    for ((peer_index0 = 0; peer_index0 < $(peers_per_organization); peer_index0++)); do
      peer_name="$(peer_kubernetes_name "$org_index1" "$peer_index0" "$org_name")"
      render_file="$(peer_render_file "$peer_name")"
      kubectl "${KUBECTL_ARGS[@]}" apply --server-side --dry-run=server --field-manager=fabricctl-admission --force-conflicts -f "$render_file" >/dev/null
      log_ok "Server-side admission passed for peer release: $peer_name"
    done
  done
}

render_and_admit_all_peers() {
  render_and_validate_all_peers
  admit_all_peer_renders
}

validate_couchdb_credential_secret() {
  local secret_name="$1" directory username_file password_file username password_length
  directory="$FABRIC_TOOL_TEMP/couchdb-credentials/$secret_name"
  mkdir -p "$directory"
  require_cluster_secret_keys "$secret_name" username password
  username_file="$directory/username"
  password_file="$directory/password"
  cluster_secret_value "$secret_name" username >"$username_file"
  cluster_secret_value "$secret_name" password >"$password_file"
  username="$(<"$username_file")"
  [[ "$username" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die "Secret $secret_name contains an invalid CouchDB username"
  cmp -s "$username_file" <(tr -d '\r\n' <"$username_file") || die "Secret $secret_name username contains a line break"
  cmp -s "$password_file" <(tr -d '\r\n' <"$password_file") || die "Secret $secret_name password contains a line break"
  password_length="$(wc -c <"$password_file" | tr -d ' ')"
  ((password_length >= 24)) || die "Secret $secret_name CouchDB password must contain at least 24 bytes"
  log_ok "Valid CouchDB credential contract: $secret_name"
}

inspect_all_couchdb_credentials() {
  local allow_missing_generate="${1:-false}" org_index1 org_name peer_index0 peer_name secret_name
  for ((org_index1 = 1; org_index1 <= $(peer_organization_count); org_index1++)); do
    org_name="$(peer_organization_name "$org_index1")"
    for ((peer_index0 = 0; peer_index0 < $(peers_per_organization); peer_index0++)); do
      peer_name="$(peer_kubernetes_name "$org_index1" "$peer_index0" "$org_name")"
      secret_name="$(couchdb_credential_secret_name "$peer_name")"
      if kubectl "${KUBECTL_ARGS[@]}" get secret "$secret_name" >/dev/null 2>&1; then
        validate_couchdb_credential_secret "$secret_name"
      elif [[ "$allow_missing_generate" == true && "$(couchdb_credentials_mode)" == generate ]]; then
        log_info "CouchDB credential Secret will be generated once during apply: $secret_name"
      else
        die "Missing externally provisioned CouchDB credential Secret: $secret_name"
      fi
    done
  done
}

ensure_all_couchdb_credentials() {
  local org_index1 org_name peer_index0 peer_name secret_name credential_dir
  for ((org_index1 = 1; org_index1 <= $(peer_organization_count); org_index1++)); do
    org_name="$(peer_organization_name "$org_index1")"
    for ((peer_index0 = 0; peer_index0 < $(peers_per_organization); peer_index0++)); do
      peer_name="$(peer_kubernetes_name "$org_index1" "$peer_index0" "$org_name")"
      secret_name="$(couchdb_credential_secret_name "$peer_name")"
      if ! kubectl "${KUBECTL_ARGS[@]}" get secret "$secret_name" >/dev/null 2>&1; then
        [[ "$(couchdb_credentials_mode)" == generate ]] || die "Missing externally provisioned CouchDB credential Secret: $secret_name"
        credential_dir="$FABRIC_TOOL_TEMP/couchdb-new/$secret_name"
        mkdir -p "$credential_dir"
        printf '%s' "${peer_name}-user" >"$credential_dir/username"
        openssl rand -hex 24 | tr -d '\r\n' >"$credential_dir/password"
        kubectl "${KUBECTL_ARGS[@]}" create secret generic "$secret_name" \
          --from-file="username=$credential_dir/username" \
          --from-file="password=$credential_dir/password" >/dev/null
        log_ok "Generated one-time CouchDB credential Secret: $secret_name"
      fi
      validate_couchdb_credential_secret "$secret_name"
    done
  done
}

deploy_all_peers() {
  local chart_dir org_index1 org_name peer_index0 peer_name values_file helm_version helm_major
  local -a helm_safety_args
  chart_dir="$(peer_chart_directory)"
  helm_version="$(helm version --template '{{.Version}}')"
  helm_major="${helm_version#v}"; helm_major="${helm_major%%.*}"
  if [[ "$helm_major" =~ ^[0-9]+$ ]] && ((helm_major >= 4)); then
    helm_safety_args=(--rollback-on-failure --wait=legacy)
  else
    helm_safety_args=(--atomic --wait)
  fi
  for ((org_index1 = 1; org_index1 <= $(peer_organization_count); org_index1++)); do
    org_name="$(peer_organization_name "$org_index1")"
    for ((peer_index0 = 0; peer_index0 < $(peers_per_organization); peer_index0++)); do
      peer_name="$(peer_kubernetes_name "$org_index1" "$peer_index0" "$org_name")"
      values_file="$(peer_values_file "$peer_name")"
      log_info "Reconciling Fabric peer/CouchDB release: $peer_name"
      helm upgrade --install "$peer_name" "$chart_dir" "${HELM_CLUSTER_ARGS[@]}" -f "$values_file" \
        "${helm_safety_args[@]}" --timeout 8m --history-max 10
    done
  done
}

verify_all_peer_releases() {
  local org_index1 org_name peer_index0 peer_name statefulset_name pod_name peer_pvc couchdb_pvc
  local ready_replicas current_revision update_revision observed_generation generation endpoint release_status probe_scheme
  local container_name container_ready restart_count image image_id expected_image port_name can_get_endpointslices=false
  if can_inspect_service_endpoints; then can_get_endpointslices=true; fi

  for ((org_index1 = 1; org_index1 <= $(peer_organization_count); org_index1++)); do
    org_name="$(peer_organization_name "$org_index1")"
    for ((peer_index0 = 0; peer_index0 < $(peers_per_organization); peer_index0++)); do
      peer_name="$(peer_kubernetes_name "$org_index1" "$peer_index0" "$org_name")"
      statefulset_name="fabric-peernode-${peer_name}"
      peer_pvc="$(peer_pvc_name "$org_index1" "$peer_index0" "$org_name" "$peer_name")"
      couchdb_pvc="$(couchdb_pvc_name "$org_index1" "$peer_index0" "$org_name" "$peer_name")"
      kubectl "${KUBECTL_ARGS[@]}" rollout status "statefulset/$statefulset_name" --timeout=3m >/dev/null
      ready_replicas="$(kubectl "${KUBECTL_ARGS[@]}" get statefulset "$statefulset_name" -o jsonpath='{.status.readyReplicas}')"
      current_revision="$(kubectl "${KUBECTL_ARGS[@]}" get statefulset "$statefulset_name" -o jsonpath='{.status.currentRevision}')"
      update_revision="$(kubectl "${KUBECTL_ARGS[@]}" get statefulset "$statefulset_name" -o jsonpath='{.status.updateRevision}')"
      observed_generation="$(kubectl "${KUBECTL_ARGS[@]}" get statefulset "$statefulset_name" -o jsonpath='{.status.observedGeneration}')"
      generation="$(kubectl "${KUBECTL_ARGS[@]}" get statefulset "$statefulset_name" -o jsonpath='{.metadata.generation}')"
      [[ "$ready_replicas" == 1 && -n "$current_revision" && "$current_revision" == "$update_revision" && "$observed_generation" == "$generation" ]] || die "$statefulset_name has not completed a healthy rollout"
      [[ "$(kubectl "${KUBECTL_ARGS[@]}" get statefulset "$statefulset_name" -o jsonpath='{.spec.template.spec.automountServiceAccountToken}')" == false ]] || die "$statefulset_name still automounts a ServiceAccount token"
      [[ "$(kubectl "${KUBECTL_ARGS[@]}" get statefulset "$statefulset_name" -o 'jsonpath={.spec.template.spec.volumes[?(@.name=="datadir")].persistentVolumeClaim.claimName}')" == "$peer_pvc" ]] || die "$statefulset_name uses the wrong peer PVC"
      [[ "$(kubectl "${KUBECTL_ARGS[@]}" get statefulset "$statefulset_name" -o 'jsonpath={.spec.template.spec.volumes[?(@.name=="datadir-couchdb")].persistentVolumeClaim.claimName}')" == "$couchdb_pvc" ]] || die "$statefulset_name uses the wrong CouchDB PVC"
      [[ "$(kubectl "${KUBECTL_ARGS[@]}" get pvc "$peer_pvc" -o jsonpath='{.status.phase}')" == Bound ]] || die "Peer PVC is not Bound: $peer_pvc"
      [[ "$(kubectl "${KUBECTL_ARGS[@]}" get pvc "$couchdb_pvc" -o jsonpath='{.status.phase}')" == Bound ]] || die "CouchDB PVC is not Bound: $couchdb_pvc"

      for port_name in grpc events operations; do
        [[ -n "$(kubectl "${KUBECTL_ARGS[@]}" get service "$peer_name" -o "jsonpath={.spec.ports[?(@.name==\"${port_name}\")].port}")" ]] || die "$peer_name Service is missing port $port_name"
      done
      [[ -z "$(kubectl "${KUBECTL_ARGS[@]}" get service "$peer_name" -o 'jsonpath={.spec.ports[?(@.name=="couchdb")].port}')" ]] || die "$peer_name still exposes CouchDB through its Service"
      [[ -z "$(kubectl "${KUBECTL_ARGS[@]}" get service "$peer_name" -o 'jsonpath={.spec.ports[?(@.name=="grpc-web")].port}')" ]] || die "$peer_name unexpectedly exposes gRPC-Web"
      if [[ "$can_get_endpointslices" == true ]]; then
        endpoint="$(ready_service_endpoints "$peer_name")"
        [[ -n "$endpoint" ]] || die "$peer_name Service has no Ready endpoint"
      fi

      [[ "$(kubectl "${KUBECTL_ARGS[@]}" get configmap "${peer_name}-config" -o 'jsonpath={.data.CORE_VM_ENDPOINT}')" == "" ]] || die "$peer_name still configures a Docker endpoint"
      [[ "$(kubectl "${KUBECTL_ARGS[@]}" get configmap "${peer_name}-config" -o 'jsonpath={.data.CORE_LEDGER_STATE_STATEDATABASE}')" == CouchDB ]] || die "$peer_name is not configured for CouchDB"
      [[ "$(kubectl "${KUBECTL_ARGS[@]}" get configmap "${peer_name}-config" -o 'jsonpath={.data.CORE_OPERATIONS_TLS_ENABLED}')" == "$(operations_tls_enabled)" ]] || die "$peer_name operations TLS does not match the input"
      if [[ "$(operations_tls_enabled)" == true ]]; then probe_scheme=HTTPS; else probe_scheme=HTTP; fi
      [[ "$(kubectl "${KUBECTL_ARGS[@]}" get statefulset "$statefulset_name" -o 'jsonpath={.spec.template.spec.containers[?(@.name=="'"$peer_name"'")].readinessProbe.httpGet.scheme}')" == "$probe_scheme" ]] || die "$peer_name readiness probe uses the wrong scheme"

      pod_name="$(kubectl "${KUBECTL_ARGS[@]}" get pod -l "app=$peer_name" -o jsonpath='{.items[0].metadata.name}')"
      for container_name in "$peer_name" couchdb; do
        if [[ "$container_name" == couchdb ]]; then expected_image="$(couchdb_image)"; else expected_image="$(fabric_peer_image)"; fi
        container_ready="$(kubectl "${KUBECTL_ARGS[@]}" get pod "$pod_name" -o "jsonpath={.status.containerStatuses[?(@.name==\"${container_name}\")].ready}")"
        restart_count="$(kubectl "${KUBECTL_ARGS[@]}" get pod "$pod_name" -o "jsonpath={.status.containerStatuses[?(@.name==\"${container_name}\")].restartCount}")"
        image="$(kubectl "${KUBECTL_ARGS[@]}" get pod "$pod_name" -o "jsonpath={.spec.containers[?(@.name==\"${container_name}\")].image}")"
        image_id="$(kubectl "${KUBECTL_ARGS[@]}" get pod "$pod_name" -o "jsonpath={.status.containerStatuses[?(@.name==\"${container_name}\")].imageID}")"
        [[ "$container_ready" == true && "$image" == "$expected_image" && "$image_id" == *@"${image##*@}" ]] || die "$pod_name/$container_name is not Ready on the configured image digest"
        if [[ "$restart_count" != 0 ]]; then log_warn "$pod_name/$container_name has restarted $restart_count time(s); it is currently Ready"; fi
      done
      # Remote-client handshake failures are request-scoped evidence, not peer
      # startup failures; readiness and the Fabric-level checks cover live TLS.
      if kubectl "${KUBECTL_ARGS[@]}" logs "$pod_name" -c "$peer_name" --tail=300 | rg 'panic|FATAL|Failed to initialize|Cannot run peer' >/dev/null; then die "$pod_name peer logs contain a fatal startup error"; fi
      if kubectl "${KUBECTL_ARGS[@]}" logs "$pod_name" -c couchdb --tail=300 | rg 'Error! Please provide|Permission denied|FATAL' >/dev/null; then die "$pod_name CouchDB logs contain a fatal startup error"; fi
      release_status="$(helm status "$peer_name" "${HELM_CLUSTER_ARGS[@]}" -o json | yq e -p=json -r '.info.status' -)"
      [[ "$release_status" == deployed ]] || die "Helm release $peer_name is not deployed: $release_status"
      log_ok "Healthy Fabric peer/CouchDB release: $peer_name"
    done
  done
}
