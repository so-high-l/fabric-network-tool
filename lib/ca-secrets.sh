#!/usr/bin/env bash

render_ca_secret_requirements() {
  local destination="$1"
  local temp_file ca_name organization admin_name _org_index1 provisioner
  provisioner="$(ca_bootstrap_mode)"
  temp_file="$(mktemp "${TMPDIR:-/tmp}/fabric-secret-requirements.XXXXXX")"

  {
    printf 'apiVersion: fabric.network.tools/v1alpha1\n'
    printf 'kind: FabricSecretRequirements\n'
    printf 'metadata:\n'
    printf '  name: %s\n' "$(network_name)"
    printf '  configSha256: %s\n' "$FABRIC_TOOL_CONFIG_SHA"
    printf 'spec:\n'
    printf '  namespace: %s\n' "$(cluster_namespace)"
    printf '  provider: %s\n' "$(secret_provider)"
    printf '  caBootstrapMode: %s\n' "$provisioner"
    printf '  items:\n'
    while IFS=$'\t' read -r ca_name organization admin_name _org_index1; do
      printf '    - name: %s-bootstrap\n' "$ca_name"
      printf '      type: Opaque\n'
      printf '      purpose: Fabric CA bootstrap registrar\n'
      printf '      expectedUsername: %s\n' "$admin_name"
      printf '      keys: [username, password]\n'
      printf '      provision: %s\n' "$provisioner"
      printf '    - name: %s-certs\n' "$ca_name"
      printf '      type: kubernetes.io/tls\n'
      printf '      purpose: Fabric CA signing and TLS keypair\n'
      printf '      organization: %s\n' "$organization"
      printf '      requiredDnsName: %s\n' "$(service_fqdn "$ca_name")"
      printf '      keys: [tls.crt, tls.key]\n'
      printf '      provision: %s\n' "$provisioner"
    done < <(list_ca_records)
  } >"$temp_file"

  yq e '.' "$temp_file" >/dev/null
  write_if_changed "$temp_file" "$destination"
}

verify_ca_tls_secret() {
  local ca_name="$1"
  local secret_name="${ca_name}-certs"
  local secret_dir="$FABRIC_TOOL_TEMP/$secret_name"
  local cert_file="$secret_dir/tls.crt"
  local key_file="$secret_dir/tls.key"
  local certificate_public_key private_public_key

  require_cluster_secret_keys "$secret_name" tls.crt tls.key
  mkdir -p "$secret_dir"
  cluster_secret_value "$secret_name" tls.crt >"$cert_file"
  cluster_secret_value "$secret_name" tls.key >"$key_file"

  openssl x509 -in "$cert_file" -noout -checkend 86400 >/dev/null || die "CA certificate is invalid or expires within 24 hours: $secret_name"
  openssl pkey -in "$key_file" -noout >/dev/null || die "CA private key is invalid: $secret_name"
  openssl x509 -in "$cert_file" -noout -checkhost "$(service_fqdn "$ca_name")" >/dev/null || die "CA certificate lacks internal service DNS SAN: $(service_fqdn "$ca_name")"
  if [[ "$(external_dns_enabled)" == true ]]; then
    openssl x509 -in "$cert_file" -noout -checkhost "${ca_name}.$(external_dns_domain)" >/dev/null || die "CA certificate lacks external DNS SAN: ${ca_name}.$(external_dns_domain)"
  fi
  openssl x509 -in "$cert_file" -noout -text | rg 'CA:TRUE' >/dev/null || die "Certificate does not have CA:TRUE: $secret_name"

  certificate_public_key="$(openssl x509 -in "$cert_file" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256)"
  private_public_key="$(openssl pkey -in "$key_file" -pubout -outform DER 2>/dev/null | openssl dgst -sha256)"
  [[ "$certificate_public_key" == "$private_public_key" ]] || die "Certificate/private-key mismatch: $secret_name"
}

verify_ca_bootstrap_secret() {
  local ca_name="$1"
  local expected_username="$2"
  local secret_name="${ca_name}-bootstrap"
  local actual_username

  require_cluster_secret_keys "$secret_name" username password
  actual_username="$(cluster_secret_value "$secret_name" username)"
  [[ "$actual_username" == "$expected_username" ]] || die "Secret $secret_name username must be $expected_username"
}

verify_all_ca_secrets() {
  local ca_name _organization admin_name _org_index1
  while IFS=$'\t' read -r ca_name _organization admin_name _org_index1; do
    verify_ca_bootstrap_secret "$ca_name" "$admin_name"
    verify_ca_tls_secret "$ca_name"
    log_ok "Verified CA secret set: $ca_name"
  done < <(list_ca_records)
}

validate_existing_ca_secrets_if_present() {
  local ca_name _organization admin_name _org_index1 bootstrap_exists cert_exists
  while IFS=$'\t' read -r ca_name _organization admin_name _org_index1; do
    bootstrap_exists=false
    cert_exists=false
    kubectl "${KUBECTL_ARGS[@]}" get secret "${ca_name}-bootstrap" >/dev/null 2>&1 && bootstrap_exists=true
    kubectl "${KUBECTL_ARGS[@]}" get secret "${ca_name}-certs" >/dev/null 2>&1 && cert_exists=true

    if [[ "$bootstrap_exists" == true || "$cert_exists" == true ]]; then
      [[ "$bootstrap_exists" == true && "$cert_exists" == true ]] || die "Partial CA secret set exists for $ca_name"
      verify_ca_bootstrap_secret "$ca_name" "$admin_name"
      verify_ca_tls_secret "$ca_name"
    fi
  done < <(list_ca_records)
}

create_development_ca_secrets() {
  local ca_name organization admin_name _org_index1 secret_dir dns_names
  local bootstrap_secret cert_secret

  [[ "$(environment_name)" == development ]] || die 'Refusing CA secret generation outside development'
  [[ "$(cluster_context)" == kind-* ]] || die 'Refusing CA secret generation outside a kind context'
  [[ "$(secret_provider)" == kubernetes ]] || die 'Generated CA secrets require the kubernetes provider'
  require_command tr

  while IFS=$'\t' read -r ca_name organization admin_name _org_index1; do
    bootstrap_secret="${ca_name}-bootstrap"
    cert_secret="${ca_name}-certs"

    if ! kubectl "${KUBECTL_ARGS[@]}" get secret "$bootstrap_secret" >/dev/null 2>&1; then
      secret_dir="$FABRIC_TOOL_TEMP/$bootstrap_secret"
      mkdir -p "$secret_dir"
      printf '%s' "$admin_name" >"$secret_dir/username"
      openssl rand -hex 24 | tr -d '\r\n' >"$secret_dir/password"
      kubectl "${KUBECTL_ARGS[@]}" create secret generic "$bootstrap_secret" \
        --from-file="username=$secret_dir/username" \
        --from-file="password=$secret_dir/password" >/dev/null
      log_ok "Created development bootstrap Secret: $bootstrap_secret"
    else
      log_ok "Keeping existing bootstrap Secret: $bootstrap_secret"
    fi

    if ! kubectl "${KUBECTL_ARGS[@]}" get secret "$cert_secret" >/dev/null 2>&1; then
      secret_dir="$FABRIC_TOOL_TEMP/$cert_secret"
      mkdir -p "$secret_dir"
      dns_names="DNS:${ca_name},DNS:${ca_name}.$(cluster_namespace),DNS:${ca_name}.$(cluster_namespace).svc,DNS:$(service_fqdn "$ca_name")"
      if [[ "$(external_dns_enabled)" == true ]]; then
        dns_names="${dns_names},DNS:${ca_name}.$(external_dns_domain)"
      fi
      openssl ecparam -name prime256v1 -genkey -noout -out "$secret_dir/tls.key"
      openssl req -new -x509 -sha256 \
        -key "$secret_dir/tls.key" \
        -out "$secret_dir/tls.crt" \
        -days "$(generated_ca_validity_days)" \
        -subj "/O=${organization}/CN=${ca_name}" \
        -addext "subjectAltName=${dns_names}" \
        -addext 'basicConstraints=critical,CA:TRUE' \
        -addext 'keyUsage=critical,digitalSignature,keyCertSign,cRLSign' \
        -addext 'extendedKeyUsage=serverAuth,clientAuth'
      kubectl "${KUBECTL_ARGS[@]}" create secret tls "$cert_secret" \
        --cert="$secret_dir/tls.crt" \
        --key="$secret_dir/tls.key" >/dev/null
      log_ok "Created development CA certificate Secret: $cert_secret"
    else
      log_ok "Keeping existing CA certificate Secret: $cert_secret"
    fi
  done < <(list_ca_records)
}
