#!/usr/bin/env bash

orderer_chart_directory() {
  local configured
  configured="$(config_value '.spec.deployment.ordererChart // ""')"
  if [[ -z "$configured" ]]; then
    printf '%s' "$FABRIC_TOOL_ROOT/charts/fabric-orderernode"
  elif [[ "$configured" == /* ]]; then
    printf '%s' "$configured"
  else
    printf '%s/%s' "$FABRIC_TOOL_CALLER_DIR" "${configured#./}"
  fi
}

orderer_values_file() {
  printf '%s/values/orderers/%s.yaml' "$FABRIC_TOOL_OUTPUT" "$1"
}

orderer_render_file() {
  printf '%s/rendered/orderers/%s.yaml' "$FABRIC_TOOL_OUTPUT" "$1"
}

render_orderer_values() {
  local orderer_index0="$1"
  local orderer_name="$2"
  local pvc_name="$3"
  local destination temp_file pull_secret
  destination="$(orderer_values_file "$orderer_name")"
  temp_file="$(mktemp "${TMPDIR:-/tmp}/fabric-orderer-values.XXXXXX")"
  pull_secret="$(image_pull_secret)"

  {
    printf 'global:\n'
    printf '  version: %s\n' "$(fabric_version)"
    printf '  serviceAccountName: %s\n' "$(cluster_service_account)"
    printf '  cluster:\n'
    printf '    provider: namespace-scoped\n'
    printf '    cloudNativeServices: false\n'
    printf '  vault:\n'
    printf '    type: kubernetes\n'
    printf '    address: ""\n'
    printf '    authPath: ""\n'
    printf '    role: ""\n'
    printf '    secretEngine: ""\n'
    printf '    secretPrefix: ""\n'
    printf '    tls: false\n'
    printf '  proxy:\n'
    printf '    provider: none\n'
    printf '    externalUrlSuffix: %s\n' "$(fabric_network_domain)"
    printf 'automountServiceAccountToken: false\n'
    printf 'image:\n'
    printf '  orderer: %s\n' "$(fabric_orderer_image)"
    if [[ -n "$pull_secret" ]]; then
      printf '  pullSecret: %s\n' "$pull_secret"
    else
      printf '  pullSecret: ""\n'
    fi
    printf 'tags:\n'
    printf '  storage: false\n'
    printf '  bevel: false\n'
    printf 'storage:\n'
    printf '  enabled: false\n'
    printf '  existingClaim: %s\n' "$pvc_name"
    printf 'certs:\n'
    printf '  generateCertificates: false\n'
    printf '  useKubernetesSecrets: true\n'
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
    printf 'grpcWeb:\n'
    printf '  enabled: false\n'
    printf 'orderer:\n'
    printf '  consensus: raft\n'
    printf '  logLevel: %s\n' "$(orderer_log_level)"
    printf '  localMspId: %s\n' "$(orderer_msp_id)"
    printf '  tlsStatus: true\n'
    printf '  operationsTLS: %s\n' "$(operations_tls_enabled)"
    printf '  keepAliveServerInterval: 10s\n'
    printf '  serviceType: ClusterIP\n'
    printf '  ports:\n'
    printf '    grpc: {clusterIpPort: 7050}\n'
    printf '    metrics: {enabled: false, clusterIpPort: 9443}\n'
    printf '  resources:\n'
    printf '    requests: {cpu: 250m, memory: 512Mi}\n'
    printf '    limits: {cpu: "1", memory: 1Gi}\n'
    printf '  probes:\n'
    printf '    enabled: true\n'
    printf '    startup: {periodSeconds: 2, failureThreshold: 30}\n'
    printf '    readiness: {periodSeconds: 5, failureThreshold: 3}\n'
    printf '    liveness: {periodSeconds: 10, failureThreshold: 3}\n'
  } >"$temp_file"

  yq e '.' "$temp_file" >/dev/null
  write_if_changed "$temp_file" "$destination"
}

render_all_orderer_values() {
  local orderer_index0 orderer_name pvc_name
  for ((orderer_index0 = 0; orderer_index0 < $(orderer_count); orderer_index0++)); do
    orderer_name="$(orderer_kubernetes_name "$orderer_index0")"
    pvc_name="$(orderer_pvc_name "$orderer_index0" "$orderer_name")"
    render_orderer_values "$orderer_index0" "$orderer_name" "$pvc_name"
  done
}

validate_orderer_render() {
  local orderer_name="$1"
  local expected_pvc="$2"
  local render_file="$3"
  local forbidden wrong_namespace workload_count service_count config_count
  local statefulset_name actual_pvc actual_image service_account secret_names
  local unsafe_image unsafe_container missing_resources init_count container_count
  local expected_probe_scheme config_value pull_secret
  statefulset_name="fabric-orderernode-${orderer_name}"
  pull_secret="$(image_pull_secret)"

  forbidden="$(yq e 'select(.kind == "Namespace" or .kind == "StorageClass" or .kind == "PersistentVolume" or .kind == "ClusterRole" or .kind == "ClusterRoleBinding" or .kind == "CustomResourceDefinition" or .kind == "Role" or .kind == "RoleBinding" or .kind == "ServiceAccount" or .kind == "MutatingWebhookConfiguration" or .kind == "ValidatingWebhookConfiguration") | .kind + "/" + .metadata.name' "$render_file")"
  [[ -z "$forbidden" ]] || die "Forbidden cluster/platform resource rendered for $orderer_name: $forbidden"
  wrong_namespace="$(yq e 'select(.kind != null and .metadata.namespace != "'"$(cluster_namespace)"'") | .kind + "/" + .metadata.name' "$render_file")"
  [[ -z "$wrong_namespace" ]] || die "Orderer resource rendered outside namespace $(cluster_namespace): $wrong_namespace"

  workload_count="$(yq e 'select(.kind == "StatefulSet") | .metadata.name' "$render_file" | awk 'NF {count++} END {print count+0}')"
  service_count="$(yq e 'select(.kind == "Service") | .metadata.name' "$render_file" | awk 'NF {count++} END {print count+0}')"
  config_count="$(yq e 'select(.kind == "ConfigMap") | .metadata.name' "$render_file" | awk 'NF {count++} END {print count+0}')"
  [[ "$workload_count" == 1 && "$service_count" == 1 && "$config_count" == 1 ]] || die "Orderer $orderer_name must render exactly one StatefulSet, Service, and ConfigMap"
  [[ "$(yq e -r 'select(.kind == "StatefulSet") | .metadata.name' "$render_file")" == "$statefulset_name" ]] || die "Unexpected StatefulSet name for $orderer_name"
  [[ "$(yq e -r 'select(.kind == "Service") | .metadata.name' "$render_file")" == "$orderer_name" ]] || die "Unexpected Service name for $orderer_name"
  [[ "$(yq e -r 'select(.kind == "ConfigMap") | .metadata.name' "$render_file")" == "${orderer_name}-config" ]] || die "Unexpected ConfigMap name for $orderer_name"

  unsafe_image="$(yq e '.. | select(tag == "!!map" and has("image")) | .image | select(test(":latest($|@)") or (contains("@sha256:") | not))' "$render_file")"
  [[ -z "$unsafe_image" ]] || die "Orderer render contains an unpinned image: $unsafe_image"
  unsafe_container="$(yq e 'select(.kind == "StatefulSet") as $w | [$w.spec.template.spec.initContainers[]?, $w.spec.template.spec.containers[]?] | .[] | select(.securityContext.allowPrivilegeEscalation != false or ((.securityContext.capabilities.drop // []) | contains(["ALL"]) | not)) | .name' "$render_file")"
  [[ -z "$unsafe_container" ]] || die "Orderer container securityContext is incomplete: $unsafe_container"
  missing_resources="$(yq e 'select(.kind == "StatefulSet") as $w | [$w.spec.template.spec.initContainers[]?, $w.spec.template.spec.containers[]?] | .[] | select(.resources.requests.cpu == null or .resources.requests.memory == null or .resources.limits.cpu == null or .resources.limits.memory == null) | .name' "$render_file")"
  [[ -z "$missing_resources" ]] || die "Orderer container resources are incomplete: $missing_resources"

  [[ "$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.securityContext.runAsNonRoot' "$render_file")" == true ]] || die "$orderer_name is missing runAsNonRoot"
  [[ "$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.securityContext.seccompProfile.type' "$render_file")" == RuntimeDefault ]] || die "$orderer_name is missing RuntimeDefault seccomp"
  [[ "$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.automountServiceAccountToken' "$render_file")" == false ]] || die "$orderer_name must not automount a ServiceAccount token"
  service_account="$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.serviceAccountName' "$render_file")"
  [[ "$service_account" == "$(cluster_service_account)" ]] || die "$orderer_name rendered unexpected ServiceAccount: $service_account"
  init_count="$(yq e 'select(.kind == "StatefulSet") | .spec.template.spec.initContainers[]?.name' "$render_file" | awk 'NF {count++} END {print count+0}')"
  container_count="$(yq e 'select(.kind == "StatefulSet") | .spec.template.spec.containers[]?.name' "$render_file" | awk 'NF {count++} END {print count+0}')"
  [[ "$init_count" == 0 && "$container_count" == 1 ]] || die "$orderer_name must render one orderer container and no init containers"

  actual_image="$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.containers[] | select(.name == "fabric-orderer") | .image' "$render_file")"
  [[ "$actual_image" == "$(fabric_orderer_image)" ]] || die "$orderer_name rendered unexpected orderer image: $actual_image"
  actual_pvc="$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.volumes[] | select(.name == "datadir") | .persistentVolumeClaim.claimName' "$render_file")"
  [[ "$actual_pvc" == "$expected_pvc" ]] || die "$orderer_name rendered PVC $actual_pvc; expected $expected_pvc"
  [[ -z "$(yq e 'select(.kind == "StatefulSet") | .spec.volumeClaimTemplates[]?.metadata.name' "$render_file")" ]] || die "$orderer_name rendered a dynamic volumeClaimTemplate"
  secret_names="$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.volumes[] | select(.name == "certificates") | .projected.sources[].secret.name' "$render_file" | sort)"
  [[ "$secret_names" == "$(printf '%s\n%s\n' "${orderer_name}-msp" "${orderer_name}-tls" | sort)" ]] || die "$orderer_name rendered unexpected certificate Secret projections"

  [[ "$(yq e -r 'select(.kind == "Service") | .spec.clusterIP' "$render_file")" == None ]] || die "$orderer_name Service must be headless"
  [[ "$(yq e -r 'select(.kind == "Service") | .spec.ports[] | select(.name == "grpc") | .port' "$render_file")" == 7050 ]] || die "$orderer_name Service is missing gRPC port 7050"
  [[ "$(yq e -r 'select(.kind == "Service") | .spec.ports[] | select(.name == "operations") | .port' "$render_file")" == 9443 ]] || die "$orderer_name Service is missing operations port 9443"
  [[ "$(yq e -r 'select(.kind == "Service") | .spec.ports[] | select(.name == "onsadmin") | .port' "$render_file")" == 7055 ]] || die "$orderer_name Service is missing admin port 7055"

  [[ "$(yq e -r 'select(.kind == "ConfigMap") | .data.ORDERER_GENERAL_BOOTSTRAPMETHOD' "$render_file")" == none ]] || die "$orderer_name must use participation-mode bootstrap method none"
  [[ "$(yq e -r 'select(.kind == "ConfigMap") | .data.ORDERER_CHANNELPARTICIPATION_ENABLED' "$render_file")" == true ]] || die "$orderer_name must enable the channel participation API"
  [[ "$(yq e -r 'select(.kind == "ConfigMap") | .data.ORDERER_GENERAL_LOCALMSPID' "$render_file")" == "$(orderer_msp_id)" ]] || die "$orderer_name rendered the wrong local MSP ID"
  [[ "$(yq e -r 'select(.kind == "ConfigMap") | .data.ORDERER_GENERAL_TLS_ENABLED' "$render_file")" == true ]] || die "$orderer_name must enable general TLS"
  [[ "$(yq e -r 'select(.kind == "ConfigMap") | .data.ORDERER_ADMIN_TLS_ENABLED' "$render_file")" == true ]] || die "$orderer_name must enable mutual TLS on the admin API"
  expected_probe_scheme=HTTP
  if [[ "$(operations_tls_enabled)" == true ]]; then
    expected_probe_scheme=HTTPS
    config_value="$(yq e -r 'select(.kind == "ConfigMap") | .data.ORDERER_OPERATIONS_TLS_ENABLED' "$render_file")"
    [[ "$config_value" == true ]] || die "$orderer_name must enable operations TLS"
  fi
  [[ "$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.containers[] | select(.name == "fabric-orderer") | .startupProbe.httpGet.scheme' "$render_file")" == "$expected_probe_scheme" ]] || die "$orderer_name startup probe uses the wrong scheme"
  [[ "$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.containers[] | select(.name == "fabric-orderer") | .readinessProbe.httpGet.scheme' "$render_file")" == "$expected_probe_scheme" ]] || die "$orderer_name readiness probe uses the wrong scheme"
  [[ "$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.containers[] | select(.name == "fabric-orderer") | .livenessProbe.httpGet.scheme' "$render_file")" == "$expected_probe_scheme" ]] || die "$orderer_name liveness probe uses the wrong scheme"

  if [[ -n "$pull_secret" ]]; then
    [[ "$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.imagePullSecrets[0].name' "$render_file")" == "$pull_secret" ]] || die "$orderer_name rendered the wrong imagePullSecret"
  fi
  if rg -q 'REPLACE_WITH|adminpw|caAdminPassword:|kind: Ingress|kind: ServiceMonitor' "$render_file"; then
    die "$orderer_name rendered an unsafe placeholder, credential, ingress, or monitoring CR"
  fi
}

render_and_validate_all_orderers() {
  local chart_dir orderer_index0 orderer_name pvc_name values_file render_file temp_file
  chart_dir="$(orderer_chart_directory)"
  render_all_orderer_values
  for ((orderer_index0 = 0; orderer_index0 < $(orderer_count); orderer_index0++)); do
    orderer_name="$(orderer_kubernetes_name "$orderer_index0")"
    pvc_name="$(orderer_pvc_name "$orderer_index0" "$orderer_name")"
    values_file="$(orderer_values_file "$orderer_name")"
    render_file="$(orderer_render_file "$orderer_name")"
    temp_file="$(mktemp "${TMPDIR:-/tmp}/fabric-orderer-render.XXXXXX")"
    helm template "$orderer_name" "$chart_dir" \
      --namespace "$(cluster_namespace)" \
      -f "$values_file" >"$temp_file"
    yq e '.' "$temp_file" >/dev/null
    write_if_changed "$temp_file" "$render_file"
    validate_orderer_render "$orderer_name" "$pvc_name" "$render_file"
    log_ok "Rendered and validated orderer release: $orderer_name"
  done
}

admit_all_orderer_renders() {
  local orderer_index0 orderer_name render_file
  for ((orderer_index0 = 0; orderer_index0 < $(orderer_count); orderer_index0++)); do
    orderer_name="$(orderer_kubernetes_name "$orderer_index0")"
    render_file="$(orderer_render_file "$orderer_name")"
    [[ -f "$render_file" ]] || die "Rendered orderer manifest is missing: $render_file"
    kubectl "${KUBECTL_ARGS[@]}" apply --server-side --dry-run=server \
      --field-manager=fabricctl-admission --force-conflicts \
      -f "$render_file" >/dev/null
    log_ok "Server-side admission passed for orderer release: $orderer_name"
  done
}

render_and_admit_all_orderers() {
  render_and_validate_all_orderers
  admit_all_orderer_renders
}

deploy_all_orderers() {
  local chart_dir orderer_index0 orderer_name values_file helm_version helm_major
  local -a helm_safety_args
  chart_dir="$(orderer_chart_directory)"
  helm_version="$(helm version --template '{{.Version}}')"
  helm_major="${helm_version#v}"
  helm_major="${helm_major%%.*}"
  if [[ "$helm_major" =~ ^[0-9]+$ ]] && ((helm_major >= 4)); then
    helm_safety_args=(--rollback-on-failure --wait=legacy)
  else
    helm_safety_args=(--atomic --wait)
  fi

  for ((orderer_index0 = 0; orderer_index0 < $(orderer_count); orderer_index0++)); do
    orderer_name="$(orderer_kubernetes_name "$orderer_index0")"
    values_file="$(orderer_values_file "$orderer_name")"
    log_info "Reconciling Fabric orderer release: $orderer_name"
    helm upgrade --install "$orderer_name" "$chart_dir" \
      "${HELM_CLUSTER_ARGS[@]}" \
      -f "$values_file" \
      "${helm_safety_args[@]}" \
      --timeout 5m \
      --history-max 10
  done
}

verify_all_orderer_releases() {
  local orderer_index0 orderer_name statefulset_name pod_name pvc_name
  local ready_replicas current_revision update_revision observed_generation generation
  local container_ready restart_count image image_id endpoint release_status probe_scheme port_name
  local can_get_endpointslices=false

  if can_inspect_service_endpoints; then
    can_get_endpointslices=true
  else
    log_warn 'Skipping orderer EndpointSlice inspection because RBAC does not allow get endpointslices.discovery.k8s.io'
  fi

  for ((orderer_index0 = 0; orderer_index0 < $(orderer_count); orderer_index0++)); do
    orderer_name="$(orderer_kubernetes_name "$orderer_index0")"
    statefulset_name="fabric-orderernode-${orderer_name}"
    pvc_name="$(orderer_pvc_name "$orderer_index0" "$orderer_name")"
    kubectl "${KUBECTL_ARGS[@]}" rollout status "statefulset/$statefulset_name" --timeout=2m >/dev/null
    ready_replicas="$(kubectl "${KUBECTL_ARGS[@]}" get statefulset "$statefulset_name" -o jsonpath='{.status.readyReplicas}')"
    current_revision="$(kubectl "${KUBECTL_ARGS[@]}" get statefulset "$statefulset_name" -o jsonpath='{.status.currentRevision}')"
    update_revision="$(kubectl "${KUBECTL_ARGS[@]}" get statefulset "$statefulset_name" -o jsonpath='{.status.updateRevision}')"
    observed_generation="$(kubectl "${KUBECTL_ARGS[@]}" get statefulset "$statefulset_name" -o jsonpath='{.status.observedGeneration}')"
    generation="$(kubectl "${KUBECTL_ARGS[@]}" get statefulset "$statefulset_name" -o jsonpath='{.metadata.generation}')"
    [[ "$ready_replicas" == 1 ]] || die "$statefulset_name does not have one Ready replica"
    [[ -n "$current_revision" && "$current_revision" == "$update_revision" ]] || die "$statefulset_name has not completed its update"
    [[ "$observed_generation" == "$generation" ]] || die "$statefulset_name controller has not observed the latest generation"
    [[ "$(kubectl "${KUBECTL_ARGS[@]}" get statefulset "$statefulset_name" -o jsonpath='{.spec.template.spec.automountServiceAccountToken}')" == false ]] || die "$statefulset_name still automounts a ServiceAccount token"
    [[ "$(kubectl "${KUBECTL_ARGS[@]}" get statefulset "$statefulset_name" -o 'jsonpath={.spec.template.spec.volumes[?(@.name=="datadir")].persistentVolumeClaim.claimName}')" == "$pvc_name" ]] || die "$statefulset_name uses the wrong PVC"

    for port_name in grpc operations onsadmin; do
      [[ -n "$(kubectl "${KUBECTL_ARGS[@]}" get service "$orderer_name" -o "jsonpath={.spec.ports[?(@.name==\"${port_name}\")].port}")" ]] || die "Orderer Service $orderer_name is missing port: $port_name"
    done
    if [[ "$can_get_endpointslices" == true ]]; then
      endpoint="$(ready_service_endpoints "$orderer_name")"
      [[ -n "$endpoint" ]] || die "Orderer Service $orderer_name has no Ready endpoint"
    fi

    [[ "$(kubectl "${KUBECTL_ARGS[@]}" get configmap "${orderer_name}-config" -o 'jsonpath={.data.ORDERER_GENERAL_BOOTSTRAPMETHOD}')" == none ]] || die "$orderer_name is not running in participation mode"
    [[ "$(kubectl "${KUBECTL_ARGS[@]}" get configmap "${orderer_name}-config" -o 'jsonpath={.data.ORDERER_CHANNELPARTICIPATION_ENABLED}')" == true ]] || die "$orderer_name has channel participation disabled"
    if [[ "$(operations_tls_enabled)" == true ]]; then
      [[ "$(kubectl "${KUBECTL_ARGS[@]}" get configmap "${orderer_name}-config" -o 'jsonpath={.data.ORDERER_OPERATIONS_TLS_ENABLED}')" == true ]] || die "$orderer_name operations TLS is disabled"
      probe_scheme=HTTPS
    else
      probe_scheme=HTTP
    fi
    [[ "$(kubectl "${KUBECTL_ARGS[@]}" get statefulset "$statefulset_name" -o 'jsonpath={.spec.template.spec.containers[?(@.name=="fabric-orderer")].readinessProbe.httpGet.scheme}')" == "$probe_scheme" ]] || die "$statefulset_name readiness probe uses the wrong scheme"

    pod_name="$(kubectl "${KUBECTL_ARGS[@]}" get pod -l "app=$orderer_name" -o jsonpath='{.items[0].metadata.name}')"
    container_ready="$(kubectl "${KUBECTL_ARGS[@]}" get pod "$pod_name" -o 'jsonpath={.status.containerStatuses[?(@.name=="fabric-orderer")].ready}')"
    restart_count="$(kubectl "${KUBECTL_ARGS[@]}" get pod "$pod_name" -o 'jsonpath={.status.containerStatuses[?(@.name=="fabric-orderer")].restartCount}')"
    image="$(kubectl "${KUBECTL_ARGS[@]}" get pod "$pod_name" -o 'jsonpath={.spec.containers[?(@.name=="fabric-orderer")].image}')"
    image_id="$(kubectl "${KUBECTL_ARGS[@]}" get pod "$pod_name" -o 'jsonpath={.status.containerStatuses[?(@.name=="fabric-orderer")].imageID}')"
    [[ "$container_ready" == true ]] || die "$pod_name/fabric-orderer is not Ready"
    [[ "$image" == "$(fabric_orderer_image)" ]] || die "$pod_name is running unexpected image: $image"
    [[ "$image_id" == *@"${image##*@}" ]] || die "$pod_name runtime image digest does not match the configured digest: $image_id"
    if [[ "$restart_count" != 0 ]]; then
      log_warn "$pod_name/fabric-orderer has restarted $restart_count time(s); it is currently Ready"
    fi
    if kubectl "${KUBECTL_ARGS[@]}" logs "$pod_name" -c fabric-orderer --tail=300 | rg 'panic|FATAL|Failed to initialize|Error reading genesis block|TLS handshake failed' >/dev/null; then
      die "$pod_name logs contain a fatal orderer startup or TLS error"
    fi
    release_status="$(helm status "$orderer_name" "${HELM_CLUSTER_ARGS[@]}" -o json | yq e -p=json -r '.info.status' -)"
    [[ "$release_status" == deployed ]] || die "Helm release $orderer_name is not deployed: $release_status"
    log_ok "Healthy participation-mode orderer release: $orderer_name"
  done
}
