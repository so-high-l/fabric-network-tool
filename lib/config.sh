#!/usr/bin/env bash

config_value() {
  local expression="$1"
  yq e -r "$expression" "$FABRIC_TOOL_CONFIG"
}

network_name() {
  config_value '.metadata.name'
}

environment_name() {
  config_value '.spec.environment // "development"'
}

cluster_context() {
  config_value '.spec.cluster.context'
}

cluster_namespace() {
  config_value '.spec.cluster.namespace'
}

cluster_service_account() {
  config_value '.spec.cluster.serviceAccount // ""'
}

impersonate_service_account() {
  config_value '.spec.cluster.impersonateServiceAccount // false'
}

cluster_domain() {
  config_value '.spec.dns.clusterDomain // "cluster.local"'
}

external_dns_enabled() {
  config_value '.spec.dns.external.enabled // false'
}

external_dns_domain() {
  config_value '.spec.dns.external.domain // ""'
}

fabric_network_domain() {
  config_value '.spec.network.domain'
}

fabric_version() {
  config_value '.spec.fabric.version // ""'
}

orderer_count() {
  config_value '.spec.topology.orderers'
}

peer_organization_count() {
  config_value '.spec.topology.peerOrganizations'
}

peers_per_organization() {
  config_value '.spec.topology.peersPerOrganization'
}

channel_name() {
  config_value '.spec.channel.name'
}

orderer_organization_name() {
  config_value '.spec.naming.ordererOrganization // "ordererorg"'
}

orderer_msp_id() {
  config_value '.spec.naming.ordererMspId // "ordererorgMSP"'
}

storage_mode() {
  config_value '.spec.storage.mode // "existingClaims"'
}

secret_provider() {
  config_value '.spec.secrets.provider // "kubernetes"'
}

enrollment_mode() {
  config_value '.spec.secrets.enrollment // "fabric-ca"'
}

operations_tls_enabled() {
  config_value '.spec.security.operationsTLS // true'
}

fabric_ca_debug_enabled() {
  config_value '.spec.security.fabricCaDebug // false'
}

ca_bootstrap_mode() {
  config_value '.spec.secrets.caBootstrapMode // "existing"'
}

generated_ca_validity_days() {
  config_value '.spec.secrets.generatedCaValidityDays // 3650'
}

fabric_ca_image() {
  config_value '.spec.images.fabricCA // ""'
}

fabric_orderer_image() {
  config_value '.spec.images.fabricOrderer // ""'
}

fabric_peer_image() {
  config_value '.spec.images.fabricPeer // ""'
}

couchdb_image() {
  config_value '.spec.images.couchDB // ""'
}

fabric_tools_image() {
  config_value '.spec.images.fabricTools // ""'
}

orderer_log_level() {
  config_value '.spec.logging.orderer // "info"'
}

peer_log_level() {
  config_value '.spec.logging.peer // "info"'
}

couchdb_credentials_mode() {
  config_value '.spec.databases.couchdbCredentialsMode // "existing"'
}

channel_operation_name() {
  config_value '.spec.naming.channelOperation // ("channel-" + .spec.channel.name)'
}

peer_channel_operation_name() {
  config_value '.spec.naming.peerChannelOperation // ("peer-channel-" + .spec.channel.name)'
}

image_pull_secret() {
  config_value '.spec.images.pullSecret // ""'
}

kubectl_image() {
  config_value '.spec.images.kubectl // ""'
}

chaincode_image() { config_value '.spec.images.chaincode // ""'; }
chaincode_name() { config_value '.spec.chaincode.name // ""'; }
chaincode_version() { config_value '.spec.chaincode.version // ""'; }
chaincode_sequence() { config_value '.spec.chaincode.sequence // 0'; }
chaincode_init_required() { config_value '.spec.chaincode.initRequired // false'; }
chaincode_tls_enabled() { config_value '.spec.chaincode.tls // true'; }
chaincode_operation_name() { config_value '.spec.naming.chaincodeOperation // ("chaincode-" + .spec.chaincode.name)'; }

chaincode_kubernetes_name() {
  local org_index1="$1" organization="$2" template
  template="$(config_value '.spec.naming.chaincodeKubernetesTemplate // ("cc-" + .spec.chaincode.name + "-{{organization}}")')"
  render_name_template "$template" "$org_index1" 0 0 "$organization"
}

chaincode_tls_secret_name() {
  local org_index1="$1" organization="$2" chaincode_service="$3" template
  template="$(config_value '.spec.chaincode.tlsSecretTemplate // "{{chaincodeService}}-tls"')"
  template="$(replace_token "$template" chaincodeService "$chaincode_service")"
  render_name_template "$template" "$org_index1" 0 0 "$organization"
}

chaincode_service_name() {
  local org_index1="$1" organization="$2" chaincode_deployment="$3" template
  template="$(config_value '.spec.chaincode.serviceNameTemplate // "{{chaincodeDeployment}}"')"
  template="$(replace_token "$template" chaincodeDeployment "$chaincode_deployment")"
  render_name_template "$template" "$org_index1" 0 0 "$organization"
}

identity_registration_secret() {
  config_value '.spec.identities.registrationSecret // "fabric-ca-enrollment-secrets"'
}

identity_registration_secret_mode() {
  config_value '.spec.identities.registrationSecretMode // "existing"'
}

identity_renewal_policy() {
  config_value '.spec.identities.renewalPolicy // "preserve"'
}

identity_job_name() {
  config_value '.spec.naming.identityJob // (.metadata.name + "-identity-enroller")'
}

output_directory_setting() {
  config_value '.spec.execution.outputDirectory // ("./build/" + .metadata.name)'
}

replace_token() {
  local value="$1"
  local token="$2"
  local replacement="$3"
  printf '%s' "${value//\{\{$token\}\}/$replacement}"
}

render_name_template() {
  local template="$1"
  local org_index1="${2:-0}"
  local peer_index0="${3:-0}"
  local orderer_index0="${4:-0}"
  local organization="${5:-}"
  local value="$template"

  value="$(replace_token "$value" 'orgIndex1' "$org_index1")"
  value="$(replace_token "$value" 'peerIndex0' "$peer_index0")"
  value="$(replace_token "$value" 'ordererIndex0' "$orderer_index0")"
  value="$(replace_token "$value" 'ordererIndex1' "$((orderer_index0 + 1))")"
  value="$(replace_token "$value" 'organization' "$organization")"
  printf '%s' "$value"
}

peer_organization_name() {
  local org_index1="$1"
  local template
  template="$(config_value '.spec.naming.peerOrganizationTemplate // "org{{orgIndex1}}"')"
  render_name_template "$template" "$org_index1"
}

peer_organization_msp_id() {
  local org_index1="$1"
  local organization="$2"
  local template
  template="$(config_value '.spec.naming.peerMspIdTemplate // "{{organization}}MSP"')"
  render_name_template "$template" "$org_index1" 0 0 "$organization"
}

orderer_kubernetes_name() {
  local orderer_index0="$1"
  local template
  template="$(config_value '.spec.naming.ordererKubernetesTemplate // "orderer{{ordererIndex0}}"')"
  render_name_template "$template" 0 0 "$orderer_index0"
}

orderer_fabric_name() {
  local orderer_index0="$1"
  local template
  template="$(config_value '.spec.naming.ordererFabricTemplate // "orderer{{ordererIndex1}}"')"
  render_name_template "$template" 0 0 "$orderer_index0"
}

peer_kubernetes_name() {
  local org_index1="$1"
  local peer_index0="$2"
  local organization="$3"
  local template
  template="$(config_value '.spec.naming.peerKubernetesTemplate // "peer{{peerIndex0}}-{{organization}}"')"
  render_name_template "$template" "$org_index1" "$peer_index0" 0 "$organization"
}

ca_kubernetes_name() {
  local organization="$1"
  local org_index1="${2:-0}"
  local template
  template="$(config_value '.spec.naming.caKubernetesTemplate // "ca-{{organization}}"')"
  render_name_template "$template" "$org_index1" 0 0 "$organization"
}

orderer_pvc_name() {
  local orderer_index0="$1"
  local kubernetes_name="$2"
  local template
  template="$(config_value '.spec.storage.claimTemplates.orderer // "{{organization}}"')"
  render_name_template "$template" 0 0 "$orderer_index0" "$kubernetes_name"
}

ca_pvc_name() {
  local org_index1="$1"
  local organization="$2"
  local ca_name="$3"
  local template
  template="$(config_value '.spec.storage.claimTemplates.ca // "{{organization}}"')"
  render_name_template "$template" "$org_index1" 0 0 "$ca_name"
}

peer_pvc_name() {
  local org_index1="$1"
  local peer_index0="$2"
  local organization="$3"
  local peer_name="$4"
  local template
  template="$(config_value '.spec.storage.claimTemplates.peer // "{{organization}}"')"
  render_name_template "$template" "$org_index1" "$peer_index0" 0 "$peer_name"
}

couchdb_pvc_name() {
  local org_index1="$1"
  local peer_index0="$2"
  local organization="$3"
  local peer_name="$4"
  local template
  template="$(config_value '.spec.storage.claimTemplates.couchdb // ""')"
  if [[ -z "$template" ]]; then
    template="couchdb-${peer_name}"
  fi
  render_name_template "$template" "$org_index1" "$peer_index0" 0 "$organization"
}

service_fqdn() {
  local service_name="$1"
  printf '%s.%s.svc.%s' "$service_name" "$(cluster_namespace)" "$(cluster_domain)"
}

list_ca_records() {
  local org_index1 org_name
  org_name="$(orderer_organization_name)"
  printf '%s\t%s\t%s\t0\n' "$(ca_kubernetes_name "$org_name")" "$org_name" "${org_name}-admin"
  for ((org_index1 = 1; org_index1 <= $(peer_organization_count); org_index1++)); do
    org_name="$(peer_organization_name "$org_index1")"
    printf '%s\t%s\t%s\t%s\n' "$(ca_kubernetes_name "$org_name" "$org_index1")" "$org_name" "${org_name}-admin" "$org_index1"
  done
}

is_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

is_rfc1123_label() {
  local value="$1"
  [[ ${#value} -le 63 ]] && [[ "$value" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]
}

is_domain_name() {
  local value="$1"
  local label
  local labels=()

  [[ -n "$value" && ${#value} -le 253 ]] || return 1
  IFS='.' read -r -a labels <<<"$value"
  [[ ${#labels[@]} -gt 0 ]] || return 1
  for label in "${labels[@]}"; do
    is_rfc1123_label "$label" || return 1
  done
}

validate_generated_names() {
  local orgs peers orderers org_index1 peer_index0 orderer_index0
  local org_name msp_id peer_name orderer_name fabric_name ca_name pvc_name
  local chaincode_deployment chaincode_service chaincode_tls_secret
  local -A seen_orgs=()
  local -A seen_msps=()
  local -A seen_services=()
  local -A seen_pvcs=()
  local -A seen_fabric_orderers=()

  orgs="$(peer_organization_count)"
  peers="$(peers_per_organization)"
  orderers="$(orderer_count)"

  org_name="$(orderer_organization_name)"
  msp_id="$(orderer_msp_id)"
  is_rfc1123_label "$org_name" || die "Generated orderer organization name is invalid: $org_name"
  [[ "$msp_id" =~ ^[A-Za-z0-9.-]+$ ]] || die "Generated orderer MSP ID is invalid: $msp_id"
  seen_orgs["$org_name"]=1
  seen_msps["$msp_id"]=1
  is_rfc1123_label "${org_name}-admin-msp" || die "Generated orderer admin MSP Secret name is too long or invalid"
  is_rfc1123_label "${org_name}-admin-tls" || die "Generated orderer admin TLS Secret name is too long or invalid"

  ca_name="$(ca_kubernetes_name "$org_name")"
  is_rfc1123_label "$ca_name" || die "Generated orderer CA name is not an RFC 1123 label: $ca_name"
  seen_services["$ca_name"]=1
  pvc_name="$(ca_pvc_name 0 "$(orderer_organization_name)" "$ca_name")"
  is_rfc1123_label "$pvc_name" || die "Generated orderer CA PVC name is invalid: $pvc_name"
  seen_pvcs["$pvc_name"]=1

  for ((orderer_index0 = 0; orderer_index0 < orderers; orderer_index0++)); do
    orderer_name="$(orderer_kubernetes_name "$orderer_index0")"
    fabric_name="$(orderer_fabric_name "$orderer_index0")"
    is_rfc1123_label "$orderer_name" || die "Generated orderer name is invalid: $orderer_name"
    is_rfc1123_label "${orderer_name}-msp" || die "Generated orderer MSP Secret name is too long or invalid: ${orderer_name}-msp"
    is_rfc1123_label "${orderer_name}-tls" || die "Generated orderer TLS Secret name is too long or invalid: ${orderer_name}-tls"
    is_rfc1123_label "$fabric_name" || die "Generated Fabric orderer name is invalid: $fabric_name"
    [[ -z "${seen_fabric_orderers[$fabric_name]:-}" ]] || die "Duplicate generated Fabric orderer name: $fabric_name"
    seen_fabric_orderers["$fabric_name"]=1
    [[ -z "${seen_services[$orderer_name]:-}" ]] || die "Duplicate generated service name: $orderer_name"
    seen_services["$orderer_name"]=1
    pvc_name="$(orderer_pvc_name "$orderer_index0" "$orderer_name")"
    is_rfc1123_label "$pvc_name" || die "Generated orderer PVC name is invalid: $pvc_name"
    [[ -z "${seen_pvcs[$pvc_name]:-}" ]] || die "Duplicate generated PVC name: $pvc_name"
    seen_pvcs["$pvc_name"]=1
  done

  for ((org_index1 = 1; org_index1 <= orgs; org_index1++)); do
    org_name="$(peer_organization_name "$org_index1")"
    msp_id="$(peer_organization_msp_id "$org_index1" "$org_name")"
    is_rfc1123_label "$org_name" || die "Generated peer organization name is invalid: $org_name"
    [[ "$msp_id" =~ ^[A-Za-z0-9.-]+$ ]] || die "Generated MSP ID is invalid: $msp_id"
    [[ -z "${seen_orgs[$org_name]:-}" ]] || die "Duplicate generated organization name: $org_name"
    [[ -z "${seen_msps[$msp_id]:-}" ]] || die "Duplicate generated MSP ID: $msp_id"
    seen_orgs["$org_name"]=1
    seen_msps["$msp_id"]=1
    is_rfc1123_label "${org_name}-admin-msp" || die "Generated peer admin MSP Secret name is too long or invalid: ${org_name}-admin-msp"
    is_rfc1123_label "${org_name}-admin-tls" || die "Generated peer admin TLS Secret name is too long or invalid: ${org_name}-admin-tls"

    chaincode_deployment="$(chaincode_kubernetes_name "$org_index1" "$org_name")"
    chaincode_service="$(chaincode_service_name "$org_index1" "$org_name" "$chaincode_deployment")"
    chaincode_tls_secret="$(chaincode_tls_secret_name "$org_index1" "$org_name" "$chaincode_deployment")"
    is_rfc1123_label "${chaincode_service}-msp" || die "Generated CCaaS MSP Secret name is too long or invalid: ${chaincode_service}-msp"
    is_rfc1123_label "$chaincode_tls_secret" || die "Generated CCaaS TLS Secret name is invalid: $chaincode_tls_secret"
    [[ -z "${seen_services[$chaincode_service]:-}" ]] || die "Duplicate generated service name: $chaincode_service"
    seen_services["$chaincode_service"]=1

    ca_name="$(ca_kubernetes_name "$org_name" "$org_index1")"
    is_rfc1123_label "$ca_name" || die "Generated CA name is invalid: $ca_name"
    [[ -z "${seen_services[$ca_name]:-}" ]] || die "Duplicate generated service name: $ca_name"
    seen_services["$ca_name"]=1
    pvc_name="$(ca_pvc_name "$org_index1" "$org_name" "$ca_name")"
    is_rfc1123_label "$pvc_name" || die "Generated CA PVC name is invalid: $pvc_name"
    [[ -z "${seen_pvcs[$pvc_name]:-}" ]] || die "Duplicate generated PVC name: $pvc_name"
    seen_pvcs["$pvc_name"]=1

    for ((peer_index0 = 0; peer_index0 < peers; peer_index0++)); do
      peer_name="$(peer_kubernetes_name "$org_index1" "$peer_index0" "$org_name")"
      is_rfc1123_label "$peer_name" || die "Generated peer name is invalid: $peer_name"
      is_rfc1123_label "${peer_name}-msp" || die "Generated peer MSP Secret name is too long or invalid: ${peer_name}-msp"
      is_rfc1123_label "${peer_name}-tls" || die "Generated peer TLS Secret name is too long or invalid: ${peer_name}-tls"
      is_rfc1123_label "${peer_name}-couchdb" || die "Generated CouchDB credential Secret name is too long or invalid: ${peer_name}-couchdb"
      [[ -z "${seen_services[$peer_name]:-}" ]] || die "Duplicate generated service name: $peer_name"
      seen_services["$peer_name"]=1

      pvc_name="$(peer_pvc_name "$org_index1" "$peer_index0" "$org_name" "$peer_name")"
      is_rfc1123_label "$pvc_name" || die "Generated peer PVC name is invalid: $pvc_name"
      [[ -z "${seen_pvcs[$pvc_name]:-}" ]] || die "Duplicate generated PVC name: $pvc_name"
      seen_pvcs["$pvc_name"]=1

      pvc_name="$(couchdb_pvc_name "$org_index1" "$peer_index0" "$org_name" "$peer_name")"
      is_rfc1123_label "$pvc_name" || die "Generated CouchDB PVC name is invalid: $pvc_name"
      [[ -z "${seen_pvcs[$pvc_name]:-}" ]] || die "Duplicate generated PVC name: $pvc_name"
      seen_pvcs["$pvc_name"]=1
    done
  done
}

validate_config() {
  local api_version kind name environment context namespace service_account
  local orderers orgs peers channel network_domain_value cluster_domain_value org_index1 org_name
  local external_enabled external_domain_value storage secrets enrollment operations_tls output_setting
  local ca_debug bootstrap_mode validity_days ca_image orderer_image peer_image couchdb_image_value tools_image pull_secret kubectl_image_value sensitive_keys
  local registration_secret registration_mode renewal_policy job_name
  local fabric_version_value orderer_log_level_value peer_log_level_value couchdb_mode channel_operation peer_channel_operation
  local chaincode_image_value chaincode_name_value chaincode_version_value chaincode_sequence_value chaincode_init_value chaincode_tls_value chaincode_operation chaincode_service

  require_command yq
  yq e '.' "$FABRIC_TOOL_CONFIG" >/dev/null || die "Configuration is not valid YAML: $FABRIC_TOOL_CONFIG"

  api_version="$(config_value '.apiVersion // ""')"
  kind="$(config_value '.kind // ""')"
  name="$(config_value '.metadata.name // ""')"
  environment="$(environment_name)"
  context="$(cluster_context)"
  namespace="$(cluster_namespace)"
  service_account="$(cluster_service_account)"
  orderers="$(orderer_count)"
  orgs="$(peer_organization_count)"
  peers="$(peers_per_organization)"
  channel="$(channel_name)"
  network_domain_value="$(fabric_network_domain)"
  fabric_version_value="$(fabric_version)"
  cluster_domain_value="$(cluster_domain)"
  external_enabled="$(external_dns_enabled)"
  external_domain_value="$(external_dns_domain)"
  storage="$(storage_mode)"
  secrets="$(secret_provider)"
  enrollment="$(enrollment_mode)"
  operations_tls="$(operations_tls_enabled)"
  ca_debug="$(fabric_ca_debug_enabled)"
  bootstrap_mode="$(ca_bootstrap_mode)"
  validity_days="$(generated_ca_validity_days)"
  ca_image="$(fabric_ca_image)"
  orderer_image="$(fabric_orderer_image)"
  peer_image="$(fabric_peer_image)"
  couchdb_image_value="$(couchdb_image)"
  tools_image="$(fabric_tools_image)"
  orderer_log_level_value="$(orderer_log_level)"
  peer_log_level_value="$(peer_log_level)"
  couchdb_mode="$(couchdb_credentials_mode)"
  channel_operation="$(channel_operation_name)"
  peer_channel_operation="$(peer_channel_operation_name)"
  pull_secret="$(image_pull_secret)"
  kubectl_image_value="$(kubectl_image)"
  chaincode_image_value="$(chaincode_image)"
  chaincode_name_value="$(chaincode_name)"
  chaincode_version_value="$(chaincode_version)"
  chaincode_sequence_value="$(chaincode_sequence)"
  chaincode_init_value="$(chaincode_init_required)"
  chaincode_tls_value="$(chaincode_tls_enabled)"
  chaincode_operation="$(chaincode_operation_name)"
  registration_secret="$(identity_registration_secret)"
  registration_mode="$(identity_registration_secret_mode)"
  renewal_policy="$(identity_renewal_policy)"
  job_name="$(identity_job_name)"
  output_setting="$(output_directory_setting)"

  [[ "$api_version" == 'fabric.network.tools/v1alpha1' ]] || die "apiVersion must be fabric.network.tools/v1alpha1"
  [[ "$kind" == 'FabricNetwork' ]] || die "kind must be FabricNetwork"
  is_rfc1123_label "$name" || die "metadata.name must be an RFC 1123 label (lowercase, max 63 characters)"
  [[ "$environment" =~ ^(development|staging|production)$ ]] || die "spec.environment must be development, staging, or production"
  [[ -n "$context" && "$context" != 'null' ]] || die "spec.cluster.context is required"
  is_rfc1123_label "$namespace" || die "spec.cluster.namespace must be an RFC 1123 label"
  is_rfc1123_label "$service_account" || die "spec.cluster.serviceAccount is required and must be an RFC 1123 label"

  is_positive_integer "$orderers" || die "spec.topology.orderers must be a positive integer"
  is_positive_integer "$orgs" || die "spec.topology.peerOrganizations must be a positive integer"
  is_positive_integer "$peers" || die "spec.topology.peersPerOrganization must be a positive integer"
  if ((orderers % 2 == 0)); then
    die "Raft orderer count must be odd; received $orderers"
  fi
  if [[ "$environment" != development && "$orderers" -lt 3 ]]; then
    die "$environment networks require at least three Raft orderers"
  fi

  [[ ${#channel} -le 249 && "$channel" =~ ^[a-z][a-z0-9.-]*$ ]] || die "spec.channel.name must start with a lowercase letter and contain only lowercase letters, digits, dots, or hyphens"
  is_domain_name "$network_domain_value" || die "spec.network.domain is not a valid DNS domain"
  [[ "$fabric_version_value" =~ ^2\.5\.[0-9]+$ ]] || die "v1alpha1 requires spec.fabric.version in the 2.5.x series"
  is_domain_name "$cluster_domain_value" || die "spec.dns.clusterDomain is not a valid DNS domain"
  [[ "$external_enabled" =~ ^(true|false)$ ]] || die "spec.dns.external.enabled must be true or false"
  if [[ "$external_enabled" == true ]]; then
    is_domain_name "$external_domain_value" || die "spec.dns.external.domain is required and must be valid when external DNS is enabled"
  fi

  [[ "$storage" =~ ^(existingClaims|dynamic)$ ]] || die "spec.storage.mode must be existingClaims or dynamic"
  [[ "$secrets" =~ ^(kubernetes|vault|external)$ ]] || die "spec.secrets.provider must be kubernetes, vault, or external"
  [[ "$enrollment" == 'fabric-ca' ]] || die "Only Fabric CA enrollment is supported in v1alpha1"
  [[ "$operations_tls" =~ ^(true|false)$ ]] || die "spec.security.operationsTLS must be true or false"
  [[ "$ca_debug" =~ ^(true|false)$ ]] || die "spec.security.fabricCaDebug must be true or false"
  [[ "$bootstrap_mode" =~ ^(existing|generate)$ ]] || die "spec.secrets.caBootstrapMode must be existing or generate"
  is_positive_integer "$validity_days" || die "spec.secrets.generatedCaValidityDays must be a positive integer"
  ((validity_days <= 3650)) || die "spec.secrets.generatedCaValidityDays cannot exceed 3650"
  [[ "$ca_image" =~ ^[^[:space:]]+@sha256:[a-f0-9]{64}$ ]] || die "spec.images.fabricCA must be pinned by a sha256 digest"
  [[ "$orderer_image" =~ ^[^[:space:]]+@sha256:[a-f0-9]{64}$ ]] || die "spec.images.fabricOrderer must be pinned by a sha256 digest"
  [[ "$peer_image" =~ ^[^[:space:]]+@sha256:[a-f0-9]{64}$ ]] || die "spec.images.fabricPeer must be pinned by a sha256 digest"
  [[ "$couchdb_image_value" =~ ^[^[:space:]]+@sha256:[a-f0-9]{64}$ ]] || die "spec.images.couchDB must be pinned by a sha256 digest"
  [[ "$tools_image" =~ ^[^[:space:]]+@sha256:[a-f0-9]{64}$ ]] || die "spec.images.fabricTools must be pinned by a sha256 digest"
  [[ "$kubectl_image_value" =~ ^[^[:space:]]+@sha256:[a-f0-9]{64}$ ]] || die "spec.images.kubectl must be pinned by a sha256 digest"
  [[ "$chaincode_image_value" =~ ^[^[:space:]]+@sha256:[a-f0-9]{64}$ ]] || die "spec.images.chaincode must be pinned by a sha256 digest"
  [[ "$chaincode_name_value" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.+-]*$ ]] || die "spec.chaincode.name is required and contains unsupported characters"
  [[ "$chaincode_version_value" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.+-]*$ ]] || die "spec.chaincode.version is required and contains unsupported characters"
  is_positive_integer "$chaincode_sequence_value" || die "spec.chaincode.sequence must be a positive integer"
  [[ "$chaincode_init_value" == false ]] || die "v1alpha1 supports only spec.chaincode.initRequired: false"
  [[ "$chaincode_tls_value" == true ]] || die "v1alpha1 requires mutual TLS for external chaincode"
  [[ "$orderer_log_level_value" =~ ^(debug|info|warn|warning|error)$ ]] || die "spec.logging.orderer must be debug, info, warn, warning, or error"
  [[ "$peer_log_level_value" =~ ^(debug|info|warn|warning|error)$ ]] || die "spec.logging.peer must be debug, info, warn, warning, or error"
  [[ "$couchdb_mode" =~ ^(existing|generate)$ ]] || die "spec.databases.couchdbCredentialsMode must be existing or generate"
  if [[ -n "$pull_secret" ]]; then
    is_rfc1123_label "$pull_secret" || die "spec.images.pullSecret must be an RFC 1123 label"
  fi
  is_rfc1123_label "$registration_secret" || die "spec.identities.registrationSecret must be an RFC 1123 label"
  [[ "$registration_mode" =~ ^(existing|generate)$ ]] || die "spec.identities.registrationSecretMode must be existing or generate"
  [[ "$renewal_policy" == preserve ]] || die "Only spec.identities.renewalPolicy: preserve is supported in v1alpha1"
  is_rfc1123_label "$job_name" || die "Generated identity Job name is invalid; set spec.naming.identityJob to an RFC 1123 label"
  is_rfc1123_label "${job_name}-config" || die "Identity Job name is too long for its generated ConfigMap"
  is_rfc1123_label "$channel_operation" || die "Generated channel operation name is invalid; set spec.naming.channelOperation to a shorter RFC 1123 label"
  is_rfc1123_label "${channel_operation}-0000000000" || die "Channel operation name is too long for its profile digest suffix"
  is_rfc1123_label "${channel_operation}-receipt" || die "Channel operation name is too long for its receipt ConfigMap"
  is_rfc1123_label "$peer_channel_operation" || die "Generated peer channel operation name is invalid; set spec.naming.peerChannelOperation to a shorter RFC 1123 label"
  is_rfc1123_label "${peer_channel_operation}-receipt" || die "Peer channel operation name is too long for its receipt ConfigMap"
  is_rfc1123_label "$chaincode_operation" || die "Generated chaincode operation name is invalid; shorten spec.naming.chaincodeOperation"
  is_rfc1123_label "${chaincode_operation}-receipt" || die "Chaincode operation name is too long for its receipt ConfigMap"
  for ((org_index1 = 1; org_index1 <= orgs; org_index1++)); do
    org_name="$(peer_organization_name "$org_index1")"
    is_rfc1123_label "${peer_channel_operation}-${org_name}-0000000000" || die "Peer channel operation name is too long for generated Job names; shorten spec.naming.peerChannelOperation or organization names"
    is_rfc1123_label "${chaincode_operation}-${org_name}-0000000000" || die "Chaincode operation name is too long for generated Job names"
    chaincode_service="$(chaincode_kubernetes_name "$org_index1" "$org_name")"
    is_rfc1123_label "$chaincode_service" || die "Generated chaincode service name is invalid: $chaincode_service"
    is_rfc1123_label "$(chaincode_service_name "$org_index1" "$org_name" "$chaincode_service")" || die "Generated chaincode stable Service name is invalid for $org_name"
    is_rfc1123_label "$(chaincode_tls_secret_name "$org_index1" "$org_name" "$chaincode_service")" || die "Generated chaincode TLS Secret name is invalid for $org_name"
    is_rfc1123_label "${chaincode_service}-package" || die "Generated chaincode package ConfigMap name is invalid: ${chaincode_service}-package"
  done
  if [[ "$bootstrap_mode" == generate ]]; then
    [[ "$environment" == development ]] || die "CA material generation is allowed only for development"
    [[ "$context" == kind-* ]] || die "CA material generation is allowed only on a kind context"
    [[ "$secrets" == kubernetes ]] || die "Generated CA material requires spec.secrets.provider: kubernetes"
  fi
  if [[ "$registration_mode" == generate ]]; then
    [[ "$environment" == development ]] || die "Identity registration secret generation is allowed only for development"
    [[ "$context" == kind-* ]] || die "Identity registration secret generation is allowed only on a kind context"
    [[ "$secrets" == kubernetes ]] || die "Generated identity registration credentials require spec.secrets.provider: kubernetes"
  fi
  if [[ "$couchdb_mode" == generate ]]; then
    [[ "$environment" == development ]] || die "CouchDB credential generation is allowed only for development"
    [[ "$context" == kind-* ]] || die "CouchDB credential generation is allowed only on a kind context"
    [[ "$secrets" == kubernetes ]] || die "Generated CouchDB credentials require spec.secrets.provider: kubernetes"
  fi
  if [[ "$environment" == production ]]; then
    [[ "$operations_tls" == true ]] || die "Production requires spec.security.operationsTLS: true"
    [[ "$ca_debug" == false ]] || die "Production requires spec.security.fabricCaDebug: false"
    [[ "$bootstrap_mode" == existing ]] || die "Production requires externally provisioned CA material"
    [[ "$registration_mode" == existing ]] || die "Production requires externally provisioned identity registration credentials"
    [[ "$couchdb_mode" == existing ]] || die "Production requires externally provisioned CouchDB credentials"
    [[ "$storage" == existingClaims ]] || die "Production v1alpha1 requires pre-provisioned existingClaims"
  fi

  sensitive_keys="$(yq e '.. | select(tag == "!!map") | to_entries[] | select(.key == "password" or .key == "token" or .key == "privateKey" or .key == "secretValue") | .key' "$FABRIC_TOOL_CONFIG")"
  [[ -z "$sensitive_keys" ]] || die "Do not place secret values in the network file; sensitive key found: $(printf '%s' "$sensitive_keys" | head -n 1)"

  [[ -n "$output_setting" && "$output_setting" != '/' && "$output_setting" != '~' ]] || die "spec.execution.outputDirectory is unsafe"
  [[ "$output_setting" != /* ]] || die "spec.execution.outputDirectory must be relative to the directory where fabricctl is run"
  [[ "$output_setting" != '..' && "$output_setting" != ../* && "$output_setting" != */../* && "$output_setting" != */.. ]] || die "spec.execution.outputDirectory must not escape through .."

  validate_generated_names
  log_ok "Configuration is valid: $FABRIC_TOOL_CONFIG"
}
