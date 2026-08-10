#!/usr/bin/env bash

render_inventory() {
  local destination="$1"
  local temp_file
  local orgs peers orderers org_index1 peer_index0 orderer_index0
  local org_name org_msp ca_name peer_name orderer_name fabric_name
  local peer_pvc couchdb_pvc ca_pvc orderer_pvc external_enabled external_domain_value

  orgs="$(peer_organization_count)"
  peers="$(peers_per_organization)"
  orderers="$(orderer_count)"
  external_enabled="$(external_dns_enabled)"
  external_domain_value="$(external_dns_domain)"
  temp_file="$(mktemp "${TMPDIR:-/tmp}/fabric-inventory.XXXXXX")"

  {
    printf 'apiVersion: fabric.network.tools/v1alpha1\n'
    printf 'kind: FabricNetworkInventory\n'
    printf 'metadata:\n'
    printf '  name: %s\n' "$(network_name)"
    printf '  configSha256: %s\n' "$FABRIC_TOOL_CONFIG_SHA"
    printf 'spec:\n'
    printf '  environment: %s\n' "$(environment_name)"
    printf '  cluster:\n'
    printf '    context: %s\n' "$(cluster_context)"
    printf '    namespace: %s\n' "$(cluster_namespace)"
    printf '  dns:\n'
    printf '    networkDomain: %s\n' "$(fabric_network_domain)"
    printf '    clusterDomain: %s\n' "$(cluster_domain)"
    printf '    externalEnabled: %s\n' "$external_enabled"
    if [[ "$external_enabled" == true ]]; then
      printf '    externalDomain: %s\n' "$external_domain_value"
    fi
    printf '  channel:\n'
    printf '    name: %s\n' "$(channel_name)"
    printf '  fabric:\n'
    printf '    version: %s\n' "$(fabric_version)"
    printf '  images:\n'
    printf '    fabricCA: %s\n' "$(fabric_ca_image)"
    printf '    fabricOrderer: %s\n' "$(fabric_orderer_image)"
    printf '    fabricPeer: %s\n' "$(fabric_peer_image)"
    printf '    couchDB: %s\n' "$(couchdb_image)"
    printf '    fabricTools: %s\n' "$(fabric_tools_image)"
    printf '    kubectl: %s\n' "$(kubectl_image)"
    if [[ -n "$(image_pull_secret)" ]]; then
      printf '    pullSecret: %s\n' "$(image_pull_secret)"
    fi
    printf '  secrets:\n'
    printf '    provider: %s\n' "$(secret_provider)"
    printf '    caBootstrapMode: %s\n' "$(ca_bootstrap_mode)"
    printf '  identities:\n'
    printf '    registrationSecret: %s\n' "$(identity_registration_secret)"
    printf '    registrationSecretMode: %s\n' "$(identity_registration_secret_mode)"
    printf '    renewalPolicy: %s\n' "$(identity_renewal_policy)"
    printf '  security:\n'
    printf '    operationsTLS: %s\n' "$(operations_tls_enabled)"
    printf '    fabricCaDebug: %s\n' "$(fabric_ca_debug_enabled)"
    printf '  logging:\n'
    printf '    orderer: %s\n' "$(orderer_log_level)"
    printf '    peer: %s\n' "$(peer_log_level)"
    printf '  databases:\n'
    printf '    couchdbCredentialsMode: %s\n' "$(couchdb_credentials_mode)"
    printf '  ordererOrganization:\n'
    printf '    name: %s\n' "$(orderer_organization_name)"
    printf '    mspId: %s\n' "$(orderer_msp_id)"
    ca_name="$(ca_kubernetes_name "$(orderer_organization_name)")"
    ca_pvc="$(ca_pvc_name 0 "$(orderer_organization_name)" "$ca_name")"
    printf '    ca:\n'
    printf '      name: %s\n' "$ca_name"
    printf '      serviceFqdn: %s\n' "$(service_fqdn "$ca_name")"
    printf '      pvc: %s\n' "$ca_pvc"
    printf '    orderers:\n'
    for ((orderer_index0 = 0; orderer_index0 < orderers; orderer_index0++)); do
      orderer_name="$(orderer_kubernetes_name "$orderer_index0")"
      fabric_name="$(orderer_fabric_name "$orderer_index0")"
      orderer_pvc="$(orderer_pvc_name "$orderer_index0" "$orderer_name")"
      printf '      - kubernetesName: %s\n' "$orderer_name"
      printf '        fabricName: %s\n' "$fabric_name"
      printf '        serviceFqdn: %s\n' "$(service_fqdn "$orderer_name")"
      if [[ "$external_enabled" == true ]]; then
        printf '        externalDns: %s.%s\n' "$orderer_name" "$external_domain_value"
      fi
      printf '        pvc: %s\n' "$orderer_pvc"
    done
    printf '  peerOrganizations:\n'
    for ((org_index1 = 1; org_index1 <= orgs; org_index1++)); do
      org_name="$(peer_organization_name "$org_index1")"
      org_msp="$(peer_organization_msp_id "$org_index1" "$org_name")"
      ca_name="$(ca_kubernetes_name "$org_name" "$org_index1")"
      ca_pvc="$(ca_pvc_name "$org_index1" "$org_name" "$ca_name")"
      printf '    - name: %s\n' "$org_name"
      printf '      mspId: %s\n' "$org_msp"
      printf '      ca:\n'
      printf '        name: %s\n' "$ca_name"
      printf '        serviceFqdn: %s\n' "$(service_fqdn "$ca_name")"
      printf '        pvc: %s\n' "$ca_pvc"
      printf '      peers:\n'
      for ((peer_index0 = 0; peer_index0 < peers; peer_index0++)); do
        peer_name="$(peer_kubernetes_name "$org_index1" "$peer_index0" "$org_name")"
        peer_pvc="$(peer_pvc_name "$org_index1" "$peer_index0" "$org_name" "$peer_name")"
        couchdb_pvc="$(couchdb_pvc_name "$org_index1" "$peer_index0" "$org_name" "$peer_name")"
        printf '        - name: %s\n' "$peer_name"
        printf '          serviceFqdn: %s\n' "$(service_fqdn "$peer_name")"
        if [[ "$external_enabled" == true ]]; then
          printf '          externalDns: %s.%s\n' "$peer_name" "$external_domain_value"
        fi
        printf '          peerPvc: %s\n' "$peer_pvc"
        printf '          couchdbPvc: %s\n' "$couchdb_pvc"
        printf '          couchdbCredentialSecret: %s-couchdb\n' "$peer_name"
      done
    done
  } >"$temp_file"

  yq e '.' "$temp_file" >/dev/null
  write_if_changed "$temp_file" "$destination"
}

print_inventory_summary() {
  local orgs peers orderers total_peers total_cas total_pvcs
  orgs="$(peer_organization_count)"
  peers="$(peers_per_organization)"
  orderers="$(orderer_count)"
  total_peers=$((orgs * peers))
  total_cas=$((orgs + 1))
  total_pvcs=$((total_cas + orderers + (total_peers * 2)))

  printf '  Network:              %s (%s)\n' "$(network_name)" "$(environment_name)"
  printf '  Kubernetes target:    %s / %s\n' "$(cluster_context)" "$(cluster_namespace)"
  printf '  Orderers:             %s (Raft)\n' "$orderers"
  printf '  Peer organizations:   %s\n' "$orgs"
  printf '  Peers per org:        %s\n' "$peers"
  printf '  Total peers/CouchDBs: %s / %s\n' "$total_peers" "$total_peers"
  printf '  Fabric CAs:           %s\n' "$total_cas"
  printf '  Expected PVCs:        %s (%s)\n' "$total_pvcs" "$(storage_mode)"
  printf '  Channel:              %s\n' "$(channel_name)"
  printf '  Internal DNS suffix:  %s.svc.%s\n' "$(cluster_namespace)" "$(cluster_domain)"
}
