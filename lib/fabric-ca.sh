#!/usr/bin/env bash

ca_chart_directory() {
  local configured
  configured="$(config_value '.spec.deployment.caChart // ""')"
  if [[ -z "$configured" ]]; then
    printf '%s' "$FABRIC_TOOL_ROOT/charts/fabric-ca-server"
  elif [[ "$configured" == /* ]]; then
    printf '%s' "$configured"
  else
    printf '%s/%s' "$FABRIC_TOOL_CALLER_DIR" "${configured#./}"
  fi
}

ca_values_file() {
  printf '%s/values/cas/%s.yaml' "$FABRIC_TOOL_OUTPUT" "$1"
}

ca_render_file() {
  printf '%s/rendered/cas/%s.yaml' "$FABRIC_TOOL_OUTPUT" "$1"
}

render_ca_values() {
  local ca_name="$1"
  local organization="$2"
  local pvc_name="$3"
  local destination temp_file pull_secret
  destination="$(ca_values_file "$ca_name")"
  temp_file="$(mktemp "${TMPDIR:-/tmp}/fabric-ca-values.XXXXXX")"
  pull_secret="$(image_pull_secret)"

  {
    printf 'nameOverride: %s\n' "$ca_name"
    printf 'global:\n'
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
    printf 'image:\n'
    printf '  ca: %s\n' "$(fabric_ca_image)"
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
    printf 'podSecurityContext:\n'
    printf '  enabled: true\n'
    printf '  runAsNonRoot: true\n'
    printf '  runAsUser: 1000\n'
    printf '  runAsGroup: 1000\n'
    printf '  fsGroup: 1000\n'
    printf '  seccompProfile:\n'
    printf '    type: RuntimeDefault\n'
    printf 'containerSecurityContext:\n'
    printf '  enabled: true\n'
    printf '  allowPrivilegeEscalation: false\n'
    printf '  capabilities:\n'
    printf '    drop: [ALL]\n'
    printf 'certs:\n'
    printf '  generateCertificates: false\n'
    printf 'server:\n'
    printf '  serviceName: %s\n' "$ca_name"
    printf '  opensslConfigMapName: %s-openssl-config\n' "$ca_name"
    printf '  bootstrapSecret:\n'
    printf '    name: %s-bootstrap\n' "$ca_name"
    printf '    usernameKey: username\n'
    printf '    passwordKey: password\n'
    printf '  certificateSecret: %s-certs\n' "$ca_name"
    printf '  subject: /O=%s\n' "$organization"
    printf '  clusterIpPort: 7054\n'
    printf '  tlsStatus: true\n'
    printf '  debug: %s\n' "$(fabric_ca_debug_enabled)"
    printf '  removeCertsOnDelete: false\n'
    printf '  cleanup:\n'
    printf '    enabled: false\n'
    printf 'resources:\n'
    printf '  init:\n'
    printf '    requests: {cpu: 50m, memory: 64Mi}\n'
    printf '    limits: {cpu: 250m, memory: 256Mi}\n'
    printf '  ca:\n'
    printf '    requests: {cpu: 100m, memory: 256Mi}\n'
    printf '    limits: {cpu: 500m, memory: 1Gi}\n'
    printf '  cleanup:\n'
    printf '    requests: {cpu: 25m, memory: 64Mi}\n'
    printf '    limits: {cpu: 100m, memory: 128Mi}\n'
  } >"$temp_file"

  yq e '.' "$temp_file" >/dev/null
  write_if_changed "$temp_file" "$destination"
}

render_all_ca_values() {
  local ca_name organization _admin_name org_index1 ca_pvc
  while IFS=$'\t' read -r ca_name organization _admin_name org_index1; do
    ca_pvc="$(ca_pvc_name "$org_index1" "$organization" "$ca_name")"
    render_ca_values "$ca_name" "$organization" "$ca_pvc"
  done < <(list_ca_records)
}

validate_ca_render() {
  local ca_name="$1"
  local expected_pvc="$2"
  local render_file="$3"
  local forbidden wrong_namespace missing_security missing_resources unsafe_image unsafe_container
  local actual_pvc statefulset_count init_count service_account certificate_secret bootstrap_secret cleanup_jobs

  forbidden="$(yq e 'select(.kind == "Namespace" or .kind == "StorageClass" or .kind == "PersistentVolume" or .kind == "ClusterRole" or .kind == "ClusterRoleBinding" or .kind == "CustomResourceDefinition" or .kind == "Role" or .kind == "RoleBinding" or .kind == "ServiceAccount" or .kind == "MutatingWebhookConfiguration" or .kind == "ValidatingWebhookConfiguration") | .kind + "/" + .metadata.name' "$render_file")"
  [[ -z "$forbidden" ]] || die "Forbidden cluster/platform resource rendered for $ca_name: $forbidden"

  wrong_namespace="$(yq e 'select(.kind != null and .metadata.namespace != "'"$(cluster_namespace)"'") | .kind + "/" + .metadata.name' "$render_file")"
  [[ -z "$wrong_namespace" ]] || die "Resource rendered outside namespace $(cluster_namespace): $wrong_namespace"

  statefulset_count="$(yq e 'select(.kind == "StatefulSet") | .metadata.name' "$render_file" | awk 'NF {count++} END {print count+0}')"
  [[ "$statefulset_count" == 1 ]] || die "Expected one CA StatefulSet for $ca_name; rendered $statefulset_count"

  missing_security="$(yq e 'select(.kind == "StatefulSet" or .kind == "Deployment" or .kind == "Job") | select(.spec.template.spec.securityContext.runAsNonRoot != true) | .kind + "/" + .metadata.name' "$render_file")"
  [[ -z "$missing_security" ]] || die "Workload missing runAsNonRoot: $missing_security"

  missing_resources="$(yq e 'select(.kind == "StatefulSet" or .kind == "Deployment" or .kind == "Job") as $w | [$w.spec.template.spec.initContainers[]?, $w.spec.template.spec.containers[]?] | .[] | select(.resources.requests.cpu == null or .resources.requests.memory == null or .resources.limits.cpu == null or .resources.limits.memory == null) | $w.kind + "/" + $w.metadata.name + ":" + .name' "$render_file")"
  [[ -z "$missing_resources" ]] || die "Container resources are incomplete: $missing_resources"

  unsafe_container="$(yq e 'select(.kind == "StatefulSet" or .kind == "Deployment" or .kind == "Job") as $w | [$w.spec.template.spec.initContainers[]?, $w.spec.template.spec.containers[]?] | .[] | select(.securityContext.allowPrivilegeEscalation != false or ((.securityContext.capabilities.drop // []) | contains(["ALL"]) | not)) | $w.kind + "/" + $w.metadata.name + ":" + .name' "$render_file")"
  [[ -z "$unsafe_container" ]] || die "Container securityContext is incomplete: $unsafe_container"

  unsafe_image="$(yq e '.. | select(tag == "!!map" and has("image")) | .image | select(test(":latest($|@)") or (contains("@sha256:") | not))' "$render_file")"
  [[ -z "$unsafe_image" ]] || die "Unpinned or latest image rendered for $ca_name: $unsafe_image"

  actual_pvc="$(yq e 'select(.kind == "StatefulSet") | .spec.template.spec.volumes[]? | select(.name == "ca-server-db-pvc") | .persistentVolumeClaim.claimName' "$render_file")"
  [[ "$actual_pvc" == "$expected_pvc" ]] || die "CA $ca_name rendered PVC $actual_pvc; expected $expected_pvc"
  [[ -z "$(yq e 'select(.kind == "StatefulSet") | .spec.volumeClaimTemplates[]?.metadata.name' "$render_file")" ]] || die "CA $ca_name rendered a dynamic volumeClaimTemplate"

  init_count="$(yq e 'select(.kind == "StatefulSet") | .spec.template.spec.initContainers[]?.name' "$render_file" | awk 'NF {count++} END {print count+0}')"
  [[ "$init_count" == 0 ]] || die "CA $ca_name unexpectedly rendered certificate init containers"
  cleanup_jobs="$(yq e 'select(.kind == "Job") | .metadata.name' "$render_file" | awk 'NF {count++} END {print count+0}')"
  [[ "$cleanup_jobs" == 0 ]] || die "CA $ca_name unexpectedly rendered a cleanup Job"
  service_account="$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.serviceAccountName' "$render_file")"
  [[ "$service_account" == "$(cluster_service_account)" ]] || die "CA $ca_name rendered unexpected ServiceAccount: $service_account"
  certificate_secret="$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.volumes[] | select(.name == "certificates") | .secret.secretName' "$render_file")"
  [[ "$certificate_secret" == "${ca_name}-certs" ]] || die "CA $ca_name rendered unexpected certificate Secret: $certificate_secret"
  bootstrap_secret="$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.containers[] | select(.name == "ca") | .env[] | select(.name == "FABRIC_CA_BOOTSTRAP_PASSWORD") | .valueFrom.secretKeyRef.name' "$render_file")"
  [[ "$bootstrap_secret" == "${ca_name}-bootstrap" ]] || die "CA $ca_name rendered unexpected bootstrap Secret: $bootstrap_secret"
  [[ "$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.containers[] | select(.name == "ca") | .readinessProbe.tcpSocket.port' "$render_file")" == 7054 ]] || die "CA $ca_name readiness probe is missing"
  [[ "$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.containers[] | select(.name == "ca") | .livenessProbe.tcpSocket.port' "$render_file")" == 9443 ]] || die "CA $ca_name liveness probe is missing"

  if rg -q 'REPLACE_WITH|adminpw|adminPassword:' "$render_file"; then
    die "Unsafe placeholder or inline CA password rendered for $ca_name"
  fi
}

render_and_validate_all_cas() {
  local chart_dir ca_name organization _admin_name org_index1 expected_pvc
  local values_file render_file temp_file
  chart_dir="$(ca_chart_directory)"

  render_all_ca_values
  while IFS=$'\t' read -r ca_name organization _admin_name org_index1; do
    expected_pvc="$(ca_pvc_name "$org_index1" "$organization" "$ca_name")"
    values_file="$(ca_values_file "$ca_name")"
    render_file="$(ca_render_file "$ca_name")"
    temp_file="$(mktemp "${TMPDIR:-/tmp}/fabric-ca-render.XXXXXX")"

    helm template "$ca_name" "$chart_dir" \
      --namespace "$(cluster_namespace)" \
      -f "$values_file" >"$temp_file"
    yq e '.' "$temp_file" >/dev/null
    write_if_changed "$temp_file" "$render_file"
    validate_ca_render "$ca_name" "$expected_pvc" "$render_file"
    log_ok "Rendered and validated CA release: $ca_name"
  done < <(list_ca_records)
}

admit_all_ca_renders() {
  local ca_name _organization _admin_name _org_index1 render_file
  while IFS=$'\t' read -r ca_name _organization _admin_name _org_index1; do
    render_file="$(ca_render_file "$ca_name")"
    [[ -f "$render_file" ]] || die "Rendered CA manifest is missing: $render_file"
    kubectl "${KUBECTL_ARGS[@]}" apply --dry-run=server -f "$render_file" >/dev/null
    log_ok "Server-side admission passed for CA release: $ca_name"
  done < <(list_ca_records)
}

render_and_admit_all_cas() {
  render_and_validate_all_cas
  admit_all_ca_renders
}

deploy_all_cas() {
  local chart_dir ca_name _organization _admin_name _org_index1 values_file helm_version helm_major
  local -a helm_safety_args
  chart_dir="$(ca_chart_directory)"
  helm_version="$(helm version --template '{{.Version}}')"
  helm_major="${helm_version#v}"
  helm_major="${helm_major%%.*}"
  if [[ "$helm_major" =~ ^[0-9]+$ ]] && ((helm_major >= 4)); then
    helm_safety_args=(--rollback-on-failure --wait=legacy)
  else
    helm_safety_args=(--atomic --wait)
  fi

  while IFS=$'\t' read -r ca_name _organization _admin_name _org_index1; do
    values_file="$(ca_values_file "$ca_name")"
    log_info "Reconciling Fabric CA release: $ca_name"
    helm upgrade --install "$ca_name" "$chart_dir" \
      "${HELM_CLUSTER_ARGS[@]}" \
      -f "$values_file" \
      "${helm_safety_args[@]}" \
      --timeout 5m \
      --history-max 10
  done < <(list_ca_records)
}

verify_all_ca_releases() {
  local ca_name organization _admin_name org_index1 statefulset_name pod_name
  local ready_replicas container_ready restart_count endpoint image can_get_endpointslices release_status

  can_get_endpointslices=false
  if can_inspect_service_endpoints; then
    can_get_endpointslices=true
  else
    log_warn 'Skipping CA EndpointSlice inspection because RBAC does not allow get endpointslices.discovery.k8s.io'
  fi

  while IFS=$'\t' read -r ca_name organization _admin_name org_index1; do
    statefulset_name="fabric-ca-server-${ca_name}"
    kubectl "${KUBECTL_ARGS[@]}" rollout status "statefulset/$statefulset_name" --timeout=2m >/dev/null
    ready_replicas="$(kubectl "${KUBECTL_ARGS[@]}" get statefulset "$statefulset_name" -o jsonpath='{.status.readyReplicas}')"
    [[ "$ready_replicas" == 1 ]] || die "$statefulset_name does not have one Ready replica"

    [[ -n "$(kubectl "${KUBECTL_ARGS[@]}" get service "$ca_name" -o 'jsonpath={.spec.ports[?(@.name=="tcp")].port}')" ]] || die "CA Service $ca_name is missing the enrollment port"
    [[ -n "$(kubectl "${KUBECTL_ARGS[@]}" get service "$ca_name" -o 'jsonpath={.spec.ports[?(@.name=="operations")].port}')" ]] || die "CA Service $ca_name is missing the operations port"
    if [[ "$can_get_endpointslices" == true ]]; then
      endpoint="$(ready_service_endpoints "$ca_name")"
      [[ -n "$endpoint" ]] || die "CA Service $ca_name has no Ready endpoint"
    fi

    pod_name="$(kubectl "${KUBECTL_ARGS[@]}" get pod -l "app=$ca_name" -o jsonpath='{.items[0].metadata.name}')"
    container_ready="$(kubectl "${KUBECTL_ARGS[@]}" get pod "$pod_name" -o 'jsonpath={.status.containerStatuses[?(@.name=="ca")].ready}')"
    restart_count="$(kubectl "${KUBECTL_ARGS[@]}" get pod "$pod_name" -o 'jsonpath={.status.containerStatuses[?(@.name=="ca")].restartCount}')"
    image="$(kubectl "${KUBECTL_ARGS[@]}" get pod "$pod_name" -o 'jsonpath={.spec.containers[?(@.name=="ca")].image}')"
    [[ "$container_ready" == true ]] || die "$pod_name/ca is not Ready"
    [[ "$image" == "$(fabric_ca_image)" ]] || die "$pod_name is running unexpected image: $image"
    if [[ "$restart_count" != 0 ]]; then
      log_warn "$pod_name/ca has restarted $restart_count time(s); it is currently Ready"
    fi
    [[ "$(kubectl "${KUBECTL_ARGS[@]}" get statefulset "$statefulset_name" -o 'jsonpath={.spec.template.spec.containers[?(@.name=="ca")].readinessProbe.tcpSocket.port}')" == 7054 ]] || die "$statefulset_name is missing the CA readiness probe"
    [[ "$(kubectl "${KUBECTL_ARGS[@]}" get statefulset "$statefulset_name" -o 'jsonpath={.spec.template.spec.containers[?(@.name=="ca")].livenessProbe.tcpSocket.port}')" == 9443 ]] || die "$statefulset_name is missing the CA liveness probe"
    if kubectl "${KUBECTL_ARGS[@]}" logs "$pod_name" -c ca --tail=250 | rg 'panic|FATAL|Failed to initialize|Permission denied' >/dev/null; then
      die "$pod_name logs contain a fatal CA error"
    fi
    release_status="$(helm status "$ca_name" "${HELM_CLUSTER_ARGS[@]}" -o json | yq e -p=json -r '.info.status' -)"
    [[ "$release_status" == deployed ]] || die "Helm release $ca_name is not deployed: $release_status"
    log_ok "Healthy Fabric CA release: $ca_name"
  done < <(list_ca_records)
}
