#!/usr/bin/env bash

identity_internal_hosts() {
  local name="$1"
  printf '%s,%s.%s,%s.%s.svc,%s' \
    "$name" "$name" "$(cluster_namespace)" "$name" "$(cluster_namespace)" \
    "$(service_fqdn "$name")"
}

identity_hosts() {
  local kubernetes_name="$1"
  local alternate_name="${2:-}"
  local hosts
  hosts="$(identity_internal_hosts "$kubernetes_name")"
  if [[ -n "$alternate_name" && "$alternate_name" != "$kubernetes_name" ]]; then
    hosts="${hosts},$(identity_internal_hosts "$alternate_name")"
  fi
  if [[ "$(external_dns_enabled)" == true ]]; then
    hosts="${hosts},${kubernetes_name}.$(external_dns_domain)"
    if [[ -n "$alternate_name" && "$alternate_name" != "$kubernetes_name" ]]; then
      hosts="${hosts},${alternate_name}.$(external_dns_domain)"
    fi
  fi
  printf '%s' "$hosts"
}

# kind, CA, enrollment ID, Fabric role, MSP Secret, TLS Secret, required TLS SANs
list_identity_records() {
  local orderer_org orderer_ca orderer_admin orderer_index0 orderer_name fabric_name
  local org_index1 org_name org_ca org_admin peer_index0 peer_name
  local cc_deployment cc_service cc_tls_secret

  orderer_org="$(orderer_organization_name)"
  orderer_ca="$(ca_kubernetes_name "$orderer_org")"
  orderer_admin="${orderer_org}-admin"
  printf 'admin\t%s\t%s\tclient\t%s-admin-msp\t%s-admin-tls\t%s\n' \
    "$orderer_ca" "$orderer_admin" "$orderer_org" "$orderer_org" \
    "$(identity_hosts "$orderer_admin")"
  for ((orderer_index0 = 0; orderer_index0 < $(orderer_count); orderer_index0++)); do
    orderer_name="$(orderer_kubernetes_name "$orderer_index0")"
    fabric_name="$(orderer_fabric_name "$orderer_index0")"
    printf 'node\t%s\t%s\torderer\t%s-msp\t%s-tls\t%s\n' \
      "$orderer_ca" "$orderer_name" "$orderer_name" "$orderer_name" \
      "$(identity_hosts "$orderer_name" "$fabric_name")"
  done

  for ((org_index1 = 1; org_index1 <= $(peer_organization_count); org_index1++)); do
    org_name="$(peer_organization_name "$org_index1")"
    org_ca="$(ca_kubernetes_name "$org_name" "$org_index1")"
    org_admin="${org_name}-admin"
    printf 'admin\t%s\t%s\tclient\t%s-admin-msp\t%s-admin-tls\t%s\n' \
      "$org_ca" "$org_admin" "$org_name" "$org_name" \
      "$(identity_hosts "$org_admin")"
    for ((peer_index0 = 0; peer_index0 < $(peers_per_organization); peer_index0++)); do
      peer_name="$(peer_kubernetes_name "$org_index1" "$peer_index0" "$org_name")"
      printf 'node\t%s\t%s\tpeer\t%s-msp\t%s-tls\t%s\n' \
        "$org_ca" "$peer_name" "$peer_name" "$peer_name" \
        "$(identity_hosts "$peer_name")"
    done
    cc_deployment="$(chaincode_kubernetes_name "$org_index1" "$org_name")"
    cc_service="$(chaincode_service_name "$org_index1" "$org_name" "$cc_deployment")"
    cc_tls_secret="$(chaincode_tls_secret_name "$org_index1" "$org_name" "$cc_deployment")"
    printf 'service\t%s\t%s\tclient\t%s-msp\t%s\t%s\n' \
      "$org_ca" "$cc_service" "$cc_service" "$cc_tls_secret" \
      "$(identity_hosts "$cc_service")"
  done
}

list_node_identity_names() {
  while IFS=$'\t' read -r kind ca_name identity role msp_secret tls_secret hosts; do
    [[ "$kind" == node || "$kind" == service ]] && printf '%s\n' "$identity"
  done < <(list_identity_records)
}

identity_selected() {
  local identity="$1"
  local selection_file="$2"
  [[ "$selection_file" == all ]] || rg -Fxq "$identity" "$selection_file"
}

render_identity_plan() {
  local destination="$1"
  local temp_file kind ca_name identity role msp_secret tls_secret hosts
  local san
  temp_file="$(mktemp "${TMPDIR:-/tmp}/fabric-identity-plan.XXXXXX")"
  {
    printf 'apiVersion: fabric.network.tools/v1alpha1\n'
    printf 'kind: FabricIdentityPlan\n'
    printf 'metadata:\n'
    printf '  name: %s\n' "$(network_name)"
    printf '  configSha256: %s\n' "$FABRIC_TOOL_CONFIG_SHA"
    printf 'spec:\n'
    printf '  namespace: %s\n' "$(cluster_namespace)"
    printf '  renewalPolicy: %s\n' "$(identity_renewal_policy)"
    printf '  registrationSecret:\n'
    printf '    name: %s\n' "$(identity_registration_secret)"
    printf '    mode: %s\n' "$(identity_registration_secret_mode)"
    printf '    requiredKeys:\n'
    while IFS= read -r identity; do
      printf '      - %s\n' "$identity"
    done < <(list_node_identity_names)
    printf '  identities:\n'
    while IFS=$'\t' read -r kind ca_name identity role msp_secret tls_secret hosts; do
      printf '    - name: %s\n' "$identity"
      printf '      kind: %s\n' "$kind"
      printf '      role: %s\n' "$role"
      printf '      ca: %s\n' "$ca_name"
      printf '      mspSecret: %s\n' "$msp_secret"
      printf '      tlsSecret: %s\n' "$tls_secret"
      printf '      requiredTlsDnsNames:\n'
      IFS=',' read -r -a sans <<<"$hosts"
      for san in "${sans[@]}"; do
        printf '        - %s\n' "$san"
      done
    done < <(list_identity_records)
  } >"$temp_file"
  yq e '.' "$temp_file" >/dev/null
  write_if_changed "$temp_file" "$destination"
}

render_enrollment_plan_tsv() {
  local destination="$1"
  local selection_file="$2"
  local temp_file kind ca_name identity role msp_secret tls_secret hosts
  local -A used_cas=()
  temp_file="$(mktemp "${TMPDIR:-/tmp}/fabric-enrollment-plan.XXXXXX")"

  while IFS=$'\t' read -r kind ca_name identity role msp_secret tls_secret hosts; do
    if identity_selected "$identity" "$selection_file"; then
      used_cas["$ca_name"]=1
    fi
  done < <(list_identity_records)

  : >"$temp_file"
  while IFS=$'\t' read -r kind ca_name identity role msp_secret tls_secret hosts; do
    if [[ "$kind" == admin && -n "${used_cas[$ca_name]:-}" ]]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$kind" "$ca_name" "$identity" "$role" "$msp_secret" "$tls_secret" "$hosts" >>"$temp_file"
    elif [[ "$kind" == node || "$kind" == service ]] && identity_selected "$identity" "$selection_file"; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$kind" "$ca_name" "$identity" "$role" "$msp_secret" "$tls_secret" "$hosts" >>"$temp_file"
    fi
  done < <(list_identity_records)
  write_if_changed "$temp_file" "$destination"
}

render_enrollment_script() {
  local destination="$1"
  local temp_file
  temp_file="$(mktemp "${TMPDIR:-/tmp}/fabric-enrollment-script.XXXXXX")"
  cp "$FABRIC_TOOL_ROOT/runtime/enroll-identities.sh" "$temp_file"
  chmod 0755 "$temp_file"
  write_if_changed "$temp_file" "$destination"
}

identity_secret_exists() {
  kubectl "${KUBECTL_ARGS[@]}" get secret "$1" >/dev/null 2>&1
}

extract_identity_secret() {
  local secret_name="$1"
  shift
  local directory="$FABRIC_TOOL_TEMP/identity-secrets/$secret_name"
  local key
  mkdir -p "$directory"
  require_cluster_secret_keys "$secret_name" "$@"
  for key in "$@"; do
    cluster_secret_value "$secret_name" "$key" >"$directory/$key"
  done
  printf '%s' "$directory"
}

certificate_public_key_digest() {
  openssl x509 -in "$1" -pubkey -noout |
    openssl pkey -pubin -outform DER 2>/dev/null |
    openssl dgst -sha256
}

private_public_key_digest() {
  openssl pkey -in "$1" -pubout -outform DER 2>/dev/null |
    openssl dgst -sha256
}

verify_certificate_role() {
  local certificate="$1"
  local identity="$2"
  local role="$3"
  local subject
  subject="$(openssl x509 -in "$certificate" -noout -subject -nameopt RFC2253)"
  subject="${subject#subject=}"
  printf '%s\n' "$subject" | rg "(^|,)CN=${identity}(,|$)" >/dev/null || die "Certificate CN is not $identity: $certificate"
  printf '%s\n' "$subject" | rg "(^|,)OU=${role}(,|$)" >/dev/null || die "Certificate OU is not $role: $certificate"
}

verify_ca_file_matches() {
  local expected="$1"
  local actual="$2"
  local expected_fingerprint actual_fingerprint
  expected_fingerprint="$(openssl x509 -in "$expected" -noout -fingerprint -sha256)"
  actual_fingerprint="$(openssl x509 -in "$actual" -noout -fingerprint -sha256)"
  [[ "$expected_fingerprint" == "$actual_fingerprint" ]] || die "Packaged CA certificate does not match its configured Fabric CA root"
}

verify_identity_record() {
  local kind="$1" ca_name="$2" identity="$3" role="$4" msp_secret="$5" tls_secret="$6" hosts="$7"
  local msp_dir tls_dir ca_dir ca_cert tls_cert tls_key tls_ca_file san

  msp_dir="$(extract_identity_secret "$msp_secret" admincerts cacerts keystore signcerts tlscacerts)"
  if [[ "$kind" == admin ]]; then
    tls_dir="$(extract_identity_secret "$tls_secret" cacrt clientcrt clientkey)"
    tls_cert="$tls_dir/clientcrt"
    tls_key="$tls_dir/clientkey"
    tls_ca_file="$tls_dir/cacrt"
  elif [[ "$kind" == service ]]; then
    tls_dir="$(extract_identity_secret "$tls_secret" ca.crt client.crt client.key)"
    tls_cert="$tls_dir/client.crt"
    tls_key="$tls_dir/client.key"
    tls_ca_file="$tls_dir/ca.crt"
  else
    tls_dir="$(extract_identity_secret "$tls_secret" cacrt servercrt serverkey)"
    tls_cert="$tls_dir/servercrt"
    tls_key="$tls_dir/serverkey"
    tls_ca_file="$tls_dir/cacrt"
  fi
  ca_dir="$(extract_identity_secret "${ca_name}-certs" tls.crt tls.key)"
  ca_cert="$ca_dir/tls.crt"

  openssl x509 -in "$msp_dir/signcerts" -noout -checkend 86400 >/dev/null || die "MSP certificate is invalid or expires within 24 hours: $msp_secret"
  openssl x509 -in "$msp_dir/admincerts" -noout -checkend 86400 >/dev/null || die "Admin certificate is invalid or expires within 24 hours: $msp_secret"
  openssl pkey -in "$msp_dir/keystore" -noout >/dev/null || die "MSP private key is invalid: $msp_secret"
  [[ "$(certificate_public_key_digest "$msp_dir/signcerts")" == "$(private_public_key_digest "$msp_dir/keystore")" ]] || die "MSP certificate/private-key mismatch: $msp_secret"
  openssl verify -CAfile "$ca_cert" "$msp_dir/signcerts" >/dev/null || die "MSP certificate chain failed: $msp_secret"
  openssl verify -CAfile "$ca_cert" "$msp_dir/admincerts" >/dev/null || die "Admin certificate chain failed: $msp_secret"
  verify_ca_file_matches "$ca_cert" "$msp_dir/cacerts"
  verify_ca_file_matches "$ca_cert" "$msp_dir/tlscacerts"
  verify_certificate_role "$msp_dir/signcerts" "$identity" "$role"

  openssl x509 -in "$tls_cert" -noout -checkend 86400 >/dev/null || die "TLS certificate is invalid or expires within 24 hours: $tls_secret"
  openssl pkey -in "$tls_key" -noout >/dev/null || die "TLS private key is invalid: $tls_secret"
  [[ "$(certificate_public_key_digest "$tls_cert")" == "$(private_public_key_digest "$tls_key")" ]] || die "TLS certificate/private-key mismatch: $tls_secret"
  openssl verify -CAfile "$ca_cert" "$tls_cert" >/dev/null || die "TLS certificate chain failed: $tls_secret"
  verify_ca_file_matches "$ca_cert" "$tls_ca_file"
  verify_certificate_role "$tls_cert" "$identity" "$role"
  IFS=',' read -r -a required_sans <<<"$hosts"
  for san in "${required_sans[@]}"; do
    openssl x509 -in "$tls_cert" -noout -checkhost "$san" >/dev/null || die "TLS certificate $tls_secret lacks DNS SAN: $san"
  done
}

scan_identity_secrets() {
  local missing_file="$1"
  local verify_existing="${2:-true}"
  local kind ca_name identity role msp_secret tls_secret hosts msp_exists tls_exists
  : >"$missing_file"
  while IFS=$'\t' read -r kind ca_name identity role msp_secret tls_secret hosts; do
    msp_exists=false
    tls_exists=false
    identity_secret_exists "$msp_secret" && msp_exists=true
    identity_secret_exists "$tls_secret" && tls_exists=true
    if [[ "$msp_exists" == false && "$tls_exists" == false ]]; then
      printf '%s\n' "$identity" >>"$missing_file"
    elif [[ "$msp_exists" != "$tls_exists" ]]; then
      die "Partial identity Secret pair for $identity; preserve policy refuses automatic replacement"
    elif [[ "$verify_existing" == true ]]; then
      verify_identity_record "$kind" "$ca_name" "$identity" "$role" "$msp_secret" "$tls_secret" "$hosts"
      log_ok "Preserving valid identity: $identity"
    fi
  done < <(list_identity_records)
}

selection_has_nodes() {
  local selection_file="$1"
  local identity
  while IFS= read -r identity; do
    if list_node_identity_names | rg -Fxq "$identity"; then
      return 0
    fi
  done <"$selection_file"
  return 1
}

require_registration_credentials() {
  local selection_file="$1"
  local secret_name identity
  selection_has_nodes "$selection_file" || return 0
  secret_name="$(identity_registration_secret)"
  if ! identity_secret_exists "$secret_name"; then
    [[ "$(identity_registration_secret_mode)" == generate ]] || die "Missing externally provisioned identity registration Secret: $secret_name"
    log_info "Registration Secret $secret_name will be generated during apply"
    return 0
  fi
  while IFS= read -r identity; do
    if list_node_identity_names | rg -Fxq "$identity"; then
      cluster_secret_has_key "$secret_name" "$identity" || die "Secret $secret_name is missing registration key: $identity"
    fi
  done <"$selection_file"
}

create_registration_credentials_if_needed() {
  local secret_name temp_dir identity
  local -a create_args
  secret_name="$(identity_registration_secret)"
  if identity_secret_exists "$secret_name"; then
    return 0
  fi
  [[ "$(identity_registration_secret_mode)" == generate ]] || die "Missing externally provisioned identity registration Secret: $secret_name"
  [[ "$(environment_name)" == development && "$(cluster_context)" == kind-* ]] || die 'Refusing registration credential generation outside development kind'

  temp_dir="$FABRIC_TOOL_TEMP/registration"
  mkdir -p "$temp_dir"
  create_args=(create secret generic "$secret_name")
  while IFS= read -r identity; do
    openssl rand -hex 24 >"$temp_dir/$identity"
    create_args+=(--from-file="$identity=$temp_dir/$identity")
  done < <(list_node_identity_names)
  kubectl "${KUBECTL_ARGS[@]}" "${create_args[@]}" >/dev/null
  log_ok "Created development registration Secret: $secret_name"
}

emit_publisher_container() {
  local index="$1" secret_name="$2"
  shift 2
  local argument
  printf '        - name: publish-%02d\n' "$index"
  printf '          image: %s\n' "$(kubectl_image)"
  printf '          imagePullPolicy: IfNotPresent\n'
  printf '          args:\n'
  printf '            - --namespace=%s\n' "$(cluster_namespace)"
  printf '            - create\n'
  printf '            - secret\n'
  printf '            - generic\n'
  printf '            - %s\n' "$secret_name"
  for argument in "$@"; do
    printf '            - --from-file=%s=/work/packages/%s/%s\n' "$argument" "$secret_name" "$argument"
  done
  printf '          securityContext:\n'
  printf '            allowPrivilegeEscalation: false\n'
  printf '            readOnlyRootFilesystem: true\n'
  printf '            capabilities: {drop: [ALL]}\n'
  printf '          resources:\n'
  printf '            requests: {cpu: 10m, memory: 24Mi}\n'
  printf '            limits: {cpu: 100m, memory: 64Mi}\n'
  printf '          volumeMounts:\n'
  printf '            - {name: work, mountPath: /work, readOnly: true}\n'
  printf '            - {name: api-access, mountPath: /var/run/secrets/kubernetes.io/serviceaccount, readOnly: true}\n'
}

render_identity_job() {
  local destination="$1" selection_file="$2" plan_file="$3"
  local temp_file kind ca_name identity role msp_secret tls_secret hosts index=0
  local pull_secret registration_volume=false
  local -A used_cas=()
  local -a used_ca_names=()
  temp_file="$(mktemp "${TMPDIR:-/tmp}/fabric-identity-job.XXXXXX")"
  pull_secret="$(image_pull_secret)"
  selection_has_nodes "$selection_file" && registration_volume=true
  while IFS=$'\t' read -r kind ca_name identity role msp_secret tls_secret hosts; do
    used_cas["$ca_name"]=1
  done <"$plan_file"
  mapfile -t used_ca_names < <(printf '%s\n' "${!used_cas[@]}" | sort)

  {
    printf 'apiVersion: batch/v1\n'
    printf 'kind: Job\n'
    printf 'metadata:\n'
    printf '  name: %s\n' "$(identity_job_name)"
    printf '  namespace: %s\n' "$(cluster_namespace)"
    printf '  labels:\n'
    printf '    app.kubernetes.io/name: %s\n' "$(identity_job_name)"
    printf '    app.kubernetes.io/managed-by: fabricctl\n'
    printf '    fabric.network.tools/network: %s\n' "$(network_name)"
    printf 'spec:\n'
    printf '  backoffLimit: 0\n'
    printf '  activeDeadlineSeconds: 600\n'
    printf '  template:\n'
    printf '    metadata:\n'
    printf '      labels:\n'
    printf '        app.kubernetes.io/name: %s\n' "$(identity_job_name)"
    printf '        fabric.network.tools/network: %s\n' "$(network_name)"
    printf '    spec:\n'
    printf '      serviceAccountName: %s\n' "$(cluster_service_account)"
    printf '      automountServiceAccountToken: false\n'
    printf '      restartPolicy: Never\n'
    printf '      securityContext:\n'
    printf '        runAsNonRoot: true\n'
    printf '        runAsUser: 1000\n'
    printf '        runAsGroup: 1000\n'
    printf '        fsGroup: 1000\n'
    printf '        seccompProfile: {type: RuntimeDefault}\n'
    if [[ -n "$pull_secret" ]]; then
      printf '      imagePullSecrets:\n'
      printf '        - {name: %s}\n' "$pull_secret"
    fi
    printf '      initContainers:\n'
    printf '        - name: enroll-identities\n'
    printf '          image: %s\n' "$(fabric_ca_image)"
    printf '          imagePullPolicy: IfNotPresent\n'
    printf '          command: [/bin/sh, /scripts/enroll-identities.sh]\n'
    printf '          securityContext:\n'
    printf '            allowPrivilegeEscalation: false\n'
    printf '            readOnlyRootFilesystem: true\n'
    printf '            capabilities: {drop: [ALL]}\n'
    printf '          resources:\n'
    printf '            requests: {cpu: 100m, memory: 128Mi}\n'
    printf '            limits: {cpu: 500m, memory: 512Mi}\n'
    printf '          volumeMounts:\n'
    printf '            - {name: config, mountPath: /config, readOnly: true}\n'
    printf '            - {name: scripts, mountPath: /scripts, readOnly: true}\n'
    printf '            - {name: work, mountPath: /work}\n'
    if [[ "$registration_volume" == true ]]; then
      printf '            - {name: registration, mountPath: /registration, readOnly: true}\n'
    fi
    for ca_name in "${used_ca_names[@]}"; do
      printf '            - {name: %s-bootstrap, mountPath: /bootstrap/%s, readOnly: true}\n' "$ca_name" "$ca_name"
      printf '            - {name: %s-root, mountPath: /ca-roots/%s, readOnly: true}\n' "$ca_name" "$ca_name"
    done
    printf '      containers:\n'
    while IFS=$'\t' read -r kind ca_name identity role msp_secret tls_secret hosts; do
      identity_selected "$identity" "$selection_file" || continue
      index=$((index + 1))
      emit_publisher_container "$index" "$msp_secret" admincerts cacerts keystore signcerts tlscacerts
      index=$((index + 1))
      if [[ "$kind" == admin ]]; then
        emit_publisher_container "$index" "$tls_secret" cacrt clientcrt clientkey
      elif [[ "$kind" == service ]]; then
        emit_publisher_container "$index" "$tls_secret" ca.crt client.crt client.key
      else
        emit_publisher_container "$index" "$tls_secret" cacrt servercrt serverkey
      fi
    done < <(list_identity_records)
    printf '      volumes:\n'
    printf '        - name: config\n'
    printf '          configMap: {name: %s-config, defaultMode: 0444}\n' "$(identity_job_name)"
    printf '        - name: scripts\n'
    printf '          configMap: {name: %s-config, defaultMode: 0555}\n' "$(identity_job_name)"
    printf '        - name: work\n'
    printf '          emptyDir: {sizeLimit: 128Mi}\n'
    printf '        - name: api-access\n'
    printf '          projected:\n'
    printf '            defaultMode: 0440\n'
    printf '            sources:\n'
    printf '              - serviceAccountToken: {path: token, expirationSeconds: 600}\n'
    printf '              - configMap: {name: kube-root-ca.crt, items: [{key: ca.crt, path: ca.crt}]}\n'
    printf '              - downwardAPI: {items: [{path: namespace, fieldRef: {apiVersion: v1, fieldPath: metadata.namespace}}]}\n'
    if [[ "$registration_volume" == true ]]; then
      printf '        - name: registration\n'
      printf '          secret: {secretName: %s, defaultMode: 0440}\n' "$(identity_registration_secret)"
    fi
    for ca_name in "${used_ca_names[@]}"; do
      printf '        - name: %s-bootstrap\n' "$ca_name"
      printf '          secret: {secretName: %s-bootstrap, defaultMode: 0440}\n' "$ca_name"
      printf '        - name: %s-root\n' "$ca_name"
      printf '          secret: {secretName: %s-certs, defaultMode: 0440, items: [{key: tls.crt, path: tls.crt}]}\n' "$ca_name"
    done
  } >"$temp_file"
  yq e '.' "$temp_file" >/dev/null
  write_if_changed "$temp_file" "$destination"
}

validate_identity_job() {
  local manifest="$1" unsafe_image unsafe_container publisher_count
  [[ "$(yq e -r '.kind' "$manifest")" == Job ]] || die "Identity workload is not a Job: $manifest"
  [[ "$(yq e -r '.metadata.namespace' "$manifest")" == "$(cluster_namespace)" ]] || die 'Identity Job rendered into the wrong namespace'
  [[ "$(yq e -r '.spec.template.spec.serviceAccountName' "$manifest")" == "$(cluster_service_account)" ]] || die 'Identity Job uses the wrong ServiceAccount'
  [[ "$(yq e -r '.spec.template.spec.automountServiceAccountToken' "$manifest")" == false ]] || die 'Identity Job must disable automatic ServiceAccount token mounting'
  [[ "$(yq e '[.spec.template.spec.initContainers[] | .volumeMounts[]?.name | select(. == "api-access")] | length' "$manifest")" == 0 ]] || die 'Fabric CA enrollment container must not receive Kubernetes API credentials'
  [[ "$(yq e '[.spec.template.spec.containers[] | select(([.volumeMounts[]?.name | select(. == "api-access")] | length) == 0) | .name] | length' "$manifest")" == 0 ]] || die 'Every Secret publisher must mount the scoped projected API token'
  [[ -z "$(yq e 'select(.spec.template.spec.volumes[]?.hostPath != null) | .metadata.name' "$manifest")" ]] || die 'Identity Job must not use hostPath'
  unsafe_image="$(yq e '[.spec.template.spec.initContainers[]?, .spec.template.spec.containers[]?] | .[] | .image | select(contains("@sha256:") | not)' "$manifest")"
  [[ -z "$unsafe_image" ]] || die "Identity Job contains an unpinned image: $unsafe_image"
  unsafe_container="$(yq e '[.spec.template.spec.initContainers[]?, .spec.template.spec.containers[]?] | .[] | select(.securityContext.allowPrivilegeEscalation != false or ((.securityContext.capabilities.drop // []) | contains(["ALL"]) | not)) | .name' "$manifest")"
  [[ -z "$unsafe_container" ]] || die "Identity Job container has incomplete security controls: $unsafe_container"
  unsafe_container="$(yq e '[.spec.template.spec.initContainers[]?, .spec.template.spec.containers[]?] | .[] | select(.securityContext.readOnlyRootFilesystem != true) | .name' "$manifest")"
  [[ -z "$unsafe_container" ]] || die "Identity Job container has a writable root filesystem: $unsafe_container"
  publisher_count="$(yq e '.spec.template.spec.containers | length' "$manifest")"
  ((publisher_count > 0)) || die 'Identity Job must contain at least one Secret publisher'
  if rg -q 'kubectl cp|pods/exec|hostPath:' "$manifest"; then
    die 'Identity Job contains a forbidden extraction mechanism'
  fi
}

render_all_identity_artifacts() {
  local identity_dir rendered_dir selection_file plan_file script_file job_file
  identity_dir="$FABRIC_TOOL_OUTPUT/identities"
  rendered_dir="$FABRIC_TOOL_OUTPUT/rendered/identities"
  selection_file="$identity_dir/all-identities.txt"
  plan_file="$identity_dir/enrollment-plan.tsv"
  script_file="$identity_dir/enroll-identities.sh"
  job_file="$rendered_dir/enroller-job.yaml"
  mkdir -p "$identity_dir" "$rendered_dir"
  list_identity_records | cut -f3 >"$selection_file"
  render_identity_plan "$identity_dir/identity-plan.yaml"
  render_enrollment_plan_tsv "$plan_file" "$selection_file"
  render_enrollment_script "$script_file"
  render_identity_job "$job_file" "$selection_file" "$plan_file"
  validate_identity_job "$job_file"
  log_ok "Rendered and validated identity enrollment artifacts"
}

publish_identity_configmap() {
  local plan_file="$1" script_file="$2" configmap_name
  configmap_name="$(identity_job_name)-config"
  kubectl "${KUBECTL_ARGS[@]}" create configmap "$configmap_name" \
    --from-file="identities.tsv=$plan_file" \
    --from-file="enroll-identities.sh=$script_file" \
    --dry-run=client -o yaml |
    kubectl "${KUBECTL_ARGS[@]}" apply -f - >/dev/null
  log_ok "Reconciled identity enrollment ConfigMap: $configmap_name"
}

run_identity_enrollment_job() {
  local selection_file="$1"
  local runtime_dir plan_file script_file job_file job_name pod_name active_count
  runtime_dir="$FABRIC_TOOL_OUTPUT/runtime/identities"
  plan_file="$runtime_dir/enrollment-plan.tsv"
  script_file="$runtime_dir/enroll-identities.sh"
  job_file="$runtime_dir/enroller-job.yaml"
  job_name="$(identity_job_name)"
  mkdir -p "$runtime_dir"
  render_enrollment_plan_tsv "$plan_file" "$selection_file"
  render_enrollment_script "$script_file"
  render_identity_job "$job_file" "$selection_file" "$plan_file"
  validate_identity_job "$job_file"
  if kubectl "${KUBECTL_ARGS[@]}" get job "$job_name" >/dev/null 2>&1; then
    active_count="$(kubectl "${KUBECTL_ARGS[@]}" get job "$job_name" -o jsonpath='{.status.active}')"
    [[ -z "$active_count" || "$active_count" == 0 ]] || die "Refusing to replace active identity enrollment Job: $job_name"
    kubectl "${KUBECTL_ARGS[@]}" delete job "$job_name" --wait=true >/dev/null
  fi
  kubectl "${KUBECTL_ARGS[@]}" apply --dry-run=server -f "$job_file" >/dev/null
  publish_identity_configmap "$plan_file" "$script_file"
  kubectl "${KUBECTL_ARGS[@]}" apply -f "$job_file" >/dev/null
  log_info "Waiting for in-cluster identity enrollment and Secret publication"
  if ! kubectl "${KUBECTL_ARGS[@]}" wait --for=condition=Complete "job/$job_name" --timeout=10m; then
    pod_name="$(kubectl "${KUBECTL_ARGS[@]}" get pod -l "job-name=$job_name" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -n "$pod_name" ]]; then
      kubectl "${KUBECTL_ARGS[@]}" logs "$pod_name" -c enroll-identities --tail=200 || true
    fi
    die "Identity enrollment Job failed or timed out: $job_name"
  fi
  log_ok "Identity enrollment Job completed: $job_name"
}
