#!/usr/bin/env bash

channel_artifact_directory() {
  printf '%s/channels/%s' "$FABRIC_TOOL_OUTPUT" "$(channel_name)"
}

channel_profile_file() {
  printf '%s/configtx.yaml' "$(channel_artifact_directory)"
}

channel_run_script_file() {
  printf '%s/run.sh' "$(channel_artifact_directory)"
}

channel_profile_sha_file() {
  printf '%s/profile.sha256' "$(channel_artifact_directory)"
}

channel_render_file() {
  printf '%s/rendered/channels/%s.yaml' "$FABRIC_TOOL_OUTPUT" "$(channel_name)"
}

channel_receipt_render_file() {
  printf '%s/rendered/channels/%s-receipt.yaml' "$FABRIC_TOOL_OUTPUT" "$(channel_name)"
}

channel_profile_sha() {
  : "${FABRIC_CHANNEL_PROFILE_SHA:?FABRIC_CHANNEL_PROFILE_SHA is required}"
  printf '%s' "$FABRIC_CHANNEL_PROFILE_SHA"
}

channel_execution_sha() {
  : "${FABRIC_CHANNEL_EXECUTION_SHA:?FABRIC_CHANNEL_EXECUTION_SHA is required}"
  printf '%s' "$FABRIC_CHANNEL_EXECUTION_SHA"
}

channel_job_name() {
  printf '%s-%s' "$(channel_operation_name)" "${FABRIC_CHANNEL_EXECUTION_SHA:0:10}"
}

channel_receipt_name() {
  printf '%s-receipt' "$(channel_operation_name)"
}

channel_consenter_csv() {
  local orderer_index0 orderer_name value=''
  for ((orderer_index0 = 0; orderer_index0 < $(orderer_count); orderer_index0++)); do
    orderer_name="$(orderer_kubernetes_name "$orderer_index0")"
    if [[ -n "$value" ]]; then value+=','; fi
    value+="$orderer_name"
  done
  printf '%s' "$value"
}

render_channel_profile_to() {
  local destination="$1" org_index1 org_name org_msp orderer_index0 orderer_name
  {
    printf 'Organizations:\n'
    printf '  - &OrdererOrg\n'
    printf '    Name: %s\n' "$(orderer_msp_id)"
    printf '    ID: %s\n' "$(orderer_msp_id)"
    printf '    MSPDir: /crypto/ordererOrganizations/%s/msp\n' "$(orderer_organization_name)"
    printf '    Policies:\n'
    printf '      Readers: {Type: Signature, Rule: "OR('\''%s.member'\'')"}\n' "$(orderer_msp_id)"
    printf '      Writers: {Type: Signature, Rule: "OR('\''%s.member'\'')"}\n' "$(orderer_msp_id)"
    printf '      Admins: {Type: Signature, Rule: "OR('\''%s.admin'\'')"}\n' "$(orderer_msp_id)"
    printf '    OrdererEndpoints:\n'
    for ((orderer_index0 = 0; orderer_index0 < $(orderer_count); orderer_index0++)); do
      orderer_name="$(orderer_kubernetes_name "$orderer_index0")"
      printf '      - %s:7050\n' "$(service_fqdn "$orderer_name")"
    done

    for ((org_index1 = 1; org_index1 <= $(peer_organization_count); org_index1++)); do
      org_name="$(peer_organization_name "$org_index1")"
      org_msp="$(peer_organization_msp_id "$org_index1" "$org_name")"
      printf '  - &ApplicationOrg%s\n' "$org_index1"
      printf '    Name: %s\n' "$org_msp"
      printf '    ID: %s\n' "$org_msp"
      printf '    MSPDir: /crypto/peerOrganizations/%s/msp\n' "$org_name"
      printf '    Policies:\n'
      printf '      Readers: {Type: Signature, Rule: "OR('\''%s.member'\'')"}\n' "$org_msp"
      printf '      Writers: {Type: Signature, Rule: "OR('\''%s.member'\'')"}\n' "$org_msp"
      printf '      Admins: {Type: Signature, Rule: "OR('\''%s.admin'\'')"}\n' "$org_msp"
      printf '      Endorsement: {Type: Signature, Rule: "OR('\''%s.peer'\'')"}\n' "$org_msp"
    done

    printf '\nCapabilities:\n'
    printf '  Channel: &ChannelCapabilities {V2_0: true}\n'
    printf '  Orderer: &OrdererCapabilities {V2_0: true}\n'
    printf '  Application: &ApplicationCapabilities {V2_5: true}\n'
    printf '\nApplication: &ApplicationDefaults\n'
    printf '  Organizations: []\n'
    printf '  Policies:\n'
    printf '    LifecycleEndorsement: {Type: ImplicitMeta, Rule: "MAJORITY Endorsement"}\n'
    printf '    Endorsement: {Type: ImplicitMeta, Rule: "MAJORITY Endorsement"}\n'
    printf '    Readers: {Type: ImplicitMeta, Rule: "ANY Readers"}\n'
    printf '    Writers: {Type: ImplicitMeta, Rule: "ANY Writers"}\n'
    printf '    Admins: {Type: ImplicitMeta, Rule: "MAJORITY Admins"}\n'
    printf '  Capabilities: {<<: *ApplicationCapabilities}\n'
    printf '\nChannel: &ChannelDefaults\n'
    printf '  Policies:\n'
    printf '    Readers: {Type: ImplicitMeta, Rule: "ANY Readers"}\n'
    printf '    Writers: {Type: ImplicitMeta, Rule: "ANY Writers"}\n'
    printf '    Admins: {Type: ImplicitMeta, Rule: "MAJORITY Admins"}\n'
    printf '  Capabilities: {<<: *ChannelCapabilities}\n'
    printf '\nOrderer: &OrdererDefaults\n'
    printf '  OrdererType: etcdraft\n'
    printf '  BatchTimeout: 2s\n'
    printf '  BatchSize: {MaxMessageCount: 10, AbsoluteMaxBytes: 103809024, PreferredMaxBytes: 1048576}\n'
    printf '  EtcdRaft:\n'
    printf '    Consenters:\n'
    for ((orderer_index0 = 0; orderer_index0 < $(orderer_count); orderer_index0++)); do
      orderer_name="$(orderer_kubernetes_name "$orderer_index0")"
      printf '      - Host: %s\n' "$(service_fqdn "$orderer_name")"
      printf '        Port: 7050\n'
      printf '        ClientTLSCert: /crypto/ordererOrganizations/%s/orderers/%s/tls/server.crt\n' "$(orderer_organization_name)" "$orderer_name"
      printf '        ServerTLSCert: /crypto/ordererOrganizations/%s/orderers/%s/tls/server.crt\n' "$(orderer_organization_name)" "$orderer_name"
    done
    printf '    Options: {TickInterval: 500ms, ElectionTick: 10, HeartbeatTick: 1, MaxInflightBlocks: 5, SnapshotIntervalSize: 16777216}\n'
    printf '  Organizations: []\n'
    printf '  Policies:\n'
    printf '    Readers: {Type: ImplicitMeta, Rule: "ANY Readers"}\n'
    printf '    Writers: {Type: ImplicitMeta, Rule: "ANY Writers"}\n'
    printf '    Admins: {Type: ImplicitMeta, Rule: "MAJORITY Admins"}\n'
    printf '    BlockValidation: {Type: ImplicitMeta, Rule: "ANY Writers"}\n'
    printf '  Capabilities: {<<: *OrdererCapabilities}\n'
    printf '\nProfiles:\n'
    printf '  %s:\n' "$(channel_name)"
    printf '    <<: *ChannelDefaults\n'
    printf '    Orderer:\n'
    printf '      <<: *OrdererDefaults\n'
    printf '      Organizations: [*OrdererOrg]\n'
    printf '    Application:\n'
    printf '      <<: *ApplicationDefaults\n'
    printf '      Organizations:\n'
    for ((org_index1 = 1; org_index1 <= $(peer_organization_count); org_index1++)); do
      printf '        - *ApplicationOrg%s\n' "$org_index1"
    done
  } >"$destination"
  yq e '.' "$destination" >/dev/null || die 'Generated channel profile is invalid YAML'
}

render_channel_run_script_to() {
  local destination="$1" orderer_index0 orderer_name
  {
    printf '#!/bin/sh\n'
    printf 'set -eu\n'
    printf 'umask 077\n'
    printf 'CHANNEL_NAME=%s\n' "$(channel_name)"
    printf 'PROFILE_NAME=%s\n' "$(channel_name)"
    printf 'PROFILE_SHA256=%s\n' "$(channel_profile_sha)"
    printf 'CONFIG_BLOCK=/work/%s.block\n' "$(channel_name)"
    printf 'ADMIN_CA=/admin-tls/ca.crt\n'
    printf 'ADMIN_CERT=/admin-tls/client.crt\n'
    printf 'ADMIN_KEY=/admin-tls/client.key\n'
    printf '\nconfigtxgen -configPath /channel -profile "$PROFILE_NAME" -channelID "$CHANNEL_NAME" -outputBlock "$CONFIG_BLOCK"\n'
    printf 'BLOCK_SHA256="$(sha256sum "$CONFIG_BLOCK" | awk '\''{print $1}'\'')"\n'
    printf 'printf '\''CHANNEL_BLOCK name=%%s profileSha256=%%s blockSha256=%%s\\n'\'' "$CHANNEL_NAME" "$PROFILE_SHA256" "$BLOCK_SHA256"\n'
    printf '\nchannel_list() {\n'
    printf '  endpoint="$1"\n'
    printf '  output="$2"\n'
    printf '  osnadmin channel list --channelID "$CHANNEL_NAME" -o "$endpoint" --ca-file "$ADMIN_CA" --client-cert "$ADMIN_CERT" --client-key "$ADMIN_KEY" >"$output" 2>&1\n'
    printf '}\n'
    printf '\nchannel_present() {\n'
    printf '  endpoint="$1"\n'
    printf '  output="$2"\n'
    printf '  channel_list "$endpoint" "$output" || return 1\n'
    printf '  grep -Eq '\''"name"[[:space:]]*:[[:space:]]*"'\''"$CHANNEL_NAME"'\''"'\'' "$output"\n'
    printf '}\n'
    printf '\n'
    for ((orderer_index0 = 0; orderer_index0 < $(orderer_count); orderer_index0++)); do
      orderer_name="$(orderer_kubernetes_name "$orderer_index0")"
      printf 'if channel_present %s:7055 /work/%s-before.json; then\n' "$(service_fqdn "$orderer_name")" "$orderer_name"
      printf '  printf '\''CHANNEL_PRESENT name=%%s orderer=%s\\n'\'' "$CHANNEL_NAME"\n' "$orderer_name"
      printf 'else\n'
      printf '  osnadmin channel join --channelID "$CHANNEL_NAME" --config-block "$CONFIG_BLOCK" -o %s:7055 --ca-file "$ADMIN_CA" --client-cert "$ADMIN_CERT" --client-key "$ADMIN_KEY"\n' "$(service_fqdn "$orderer_name")"
      printf '  printf '\''CHANNEL_JOINED name=%%s orderer=%s\\n'\'' "$CHANNEL_NAME"\n' "$orderer_name"
      printf 'fi\n'
    done
    printf '\nattempt=0\n'
    printf 'while [ "$attempt" -lt 90 ]; do\n'
    printf '  all_ready=true\n'
    for ((orderer_index0 = 0; orderer_index0 < $(orderer_count); orderer_index0++)); do
      orderer_name="$(orderer_kubernetes_name "$orderer_index0")"
      printf '  if ! channel_list %s:7055 /work/%s-status.json || ! grep -Eq '\''"name"[[:space:]]*:[[:space:]]*"%s"'\'' /work/%s-status.json || ! grep -Eq '\''"consensusRelation"[[:space:]]*:[[:space:]]*"consenter"'\'' /work/%s-status.json || ! grep -Eq '\''"status"[[:space:]]*:[[:space:]]*"active"'\'' /work/%s-status.json; then all_ready=false; fi\n' \
        "$(service_fqdn "$orderer_name")" "$orderer_name" "$(channel_name)" "$orderer_name" "$orderer_name" "$orderer_name"
    done
    printf '  [ "$all_ready" = true ] && break\n'
    printf '  attempt=$((attempt + 1))\n'
    printf '  sleep 2\n'
    printf 'done\n'
    printf '[ "$all_ready" = true ] || { printf '\''Channel did not become active on every consenter\\n'\'' >&2; exit 1; }\n'
    for ((orderer_index0 = 0; orderer_index0 < $(orderer_count); orderer_index0++)); do
      orderer_name="$(orderer_kubernetes_name "$orderer_index0")"
      printf 'printf '\''CHANNEL_READY name=%%s orderer=%s relation=consenter status=active\\n'\'' "$CHANNEL_NAME"\n' "$orderer_name"
    done
  } >"$destination"
  chmod 0755 "$destination"
  sh -n "$destination" || die 'Generated channel runner has invalid shell syntax'
}

render_msp_config_data() {
  local key="$1"
  printf '  %s: |-\n' "$key"
  printf '    NodeOUs:\n'
  printf '      Enable: true\n'
  printf '      ClientOUIdentifier: {Certificate: cacerts/ca.crt, OrganizationalUnitIdentifier: client}\n'
  printf '      PeerOUIdentifier: {Certificate: cacerts/ca.crt, OrganizationalUnitIdentifier: peer}\n'
  printf '      AdminOUIdentifier: {Certificate: cacerts/ca.crt, OrganizationalUnitIdentifier: admin}\n'
  printf '      OrdererOUIdentifier: {Certificate: cacerts/ca.crt, OrganizationalUnitIdentifier: orderer}\n'
}

render_channel_manifest_to() {
  local destination="$1" profile_file="$2" runner_file="$3"
  local job_name pull_secret org_index1 org_name orderer_index0 orderer_name
  job_name="$(channel_job_name)"
  pull_secret="$(image_pull_secret)"
  {
    printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n'
    printf '  name: %s\n  namespace: %s\n' "$job_name" "$(cluster_namespace)"
    printf '  labels: {app.kubernetes.io/managed-by: fabricctl, fabric.network.tools/channel: %s}\n' "$(channel_name)"
    printf '  annotations: {fabric.network.tools/profile-sha256: "%s"}\n' "$(channel_profile_sha)"
    printf 'data:\n'
    printf '  configtx.yaml: |-\n'; sed 's/^/    /' "$profile_file"
    printf '  run.sh: |-\n'; sed 's/^/    /' "$runner_file"
    render_msp_config_data "$(orderer_organization_name)-msp-config.yaml"
    for ((org_index1 = 1; org_index1 <= $(peer_organization_count); org_index1++)); do
      org_name="$(peer_organization_name "$org_index1")"
      render_msp_config_data "${org_name}-msp-config.yaml"
    done
    printf '%s\n' '---'
    printf 'apiVersion: batch/v1\nkind: Job\nmetadata:\n'
    printf '  name: %s\n  namespace: %s\n' "$job_name" "$(cluster_namespace)"
    printf '  labels: {app.kubernetes.io/managed-by: fabricctl, fabric.network.tools/channel: %s}\n' "$(channel_name)"
    printf '  annotations: {fabric.network.tools/profile-sha256: "%s"}\n' "$(channel_profile_sha)"
    printf 'spec:\n  backoffLimit: 1\n  activeDeadlineSeconds: 600\n  template:\n    metadata:\n'
    printf '      labels: {app.kubernetes.io/managed-by: fabricctl, fabric.network.tools/channel: %s, fabric.network.tools/channel-job: %s}\n' "$(channel_name)" "$job_name"
    printf '    spec:\n      restartPolicy: Never\n'
    printf '      serviceAccountName: %s\n' "$(cluster_service_account)"
    printf '      automountServiceAccountToken: false\n'
    printf '      securityContext: {runAsNonRoot: true, runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000, seccompProfile: {type: RuntimeDefault}}\n'
    if [[ -n "$pull_secret" ]]; then printf '      imagePullSecrets: [{name: %s}]\n' "$pull_secret"; fi
    printf '      containers:\n'
    printf '        - name: channel-admin\n'
    printf '          image: %s\n' "$(fabric_tools_image)"
    printf '          imagePullPolicy: IfNotPresent\n'
    printf '          command: [/bin/sh, /channel/run.sh]\n'
    printf '          env: [{name: FABRIC_CFG_PATH, value: /channel}, {name: HOME, value: /work}, {name: FABRIC_LOGGING_SPEC, value: info}]\n'
    printf '          securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}\n'
    printf '          resources: {requests: {cpu: 100m, memory: 128Mi}, limits: {cpu: 500m, memory: 512Mi}}\n'
    printf '          volumeMounts:\n'
    printf '            - {name: channel-files, mountPath: /channel, readOnly: true}\n'
    printf '            - {name: crypto, mountPath: /crypto, readOnly: true}\n'
    printf '            - {name: admin-tls, mountPath: /admin-tls, readOnly: true}\n'
    printf '            - {name: work, mountPath: /work}\n'
    printf '      volumes:\n'
    printf '        - name: channel-files\n          configMap:\n            name: %s\n            defaultMode: 0550\n' "$job_name"
    printf '        - name: admin-tls\n          secret:\n            secretName: %s-admin-tls\n            defaultMode: 0440\n            items:\n' "$(orderer_organization_name)"
    printf '              - {key: cacrt, path: ca.crt}\n              - {key: clientcrt, path: client.crt}\n              - {key: clientkey, path: client.key}\n'
    printf '        - name: crypto\n          projected:\n            defaultMode: 0440\n            sources:\n'
    printf '              - configMap:\n                  name: %s\n                  items:\n' "$job_name"
    printf '                    - {key: %s-msp-config.yaml, path: ordererOrganizations/%s/msp/config.yaml}\n' "$(orderer_organization_name)" "$(orderer_organization_name)"
    for ((org_index1 = 1; org_index1 <= $(peer_organization_count); org_index1++)); do
      org_name="$(peer_organization_name "$org_index1")"
      printf '                    - {key: %s-msp-config.yaml, path: peerOrganizations/%s/msp/config.yaml}\n' "$org_name" "$org_name"
    done
    printf '              - secret:\n                  name: %s-admin-msp\n                  items:\n' "$(orderer_organization_name)"
    printf '                    - {key: cacerts, path: ordererOrganizations/%s/msp/cacerts/ca.crt}\n' "$(orderer_organization_name)"
    printf '                    - {key: admincerts, path: ordererOrganizations/%s/msp/admincerts/admin.crt}\n' "$(orderer_organization_name)"
    printf '                    - {key: tlscacerts, path: ordererOrganizations/%s/msp/tlscacerts/tlsca.crt}\n' "$(orderer_organization_name)"
    for ((org_index1 = 1; org_index1 <= $(peer_organization_count); org_index1++)); do
      org_name="$(peer_organization_name "$org_index1")"
      printf '              - secret:\n                  name: %s-admin-msp\n                  items:\n' "$org_name"
      printf '                    - {key: cacerts, path: peerOrganizations/%s/msp/cacerts/ca.crt}\n' "$org_name"
      printf '                    - {key: admincerts, path: peerOrganizations/%s/msp/admincerts/admin.crt}\n' "$org_name"
      printf '                    - {key: tlscacerts, path: peerOrganizations/%s/msp/tlscacerts/tlsca.crt}\n' "$org_name"
    done
    for ((orderer_index0 = 0; orderer_index0 < $(orderer_count); orderer_index0++)); do
      orderer_name="$(orderer_kubernetes_name "$orderer_index0")"
      printf '              - secret:\n                  name: %s-tls\n                  items:\n' "$orderer_name"
      printf '                    - {key: servercrt, path: ordererOrganizations/%s/orderers/%s/tls/server.crt}\n' "$(orderer_organization_name)" "$orderer_name"
    done
    printf '        - name: work\n          emptyDir: {}\n'
  } >"$destination"
  yq e '.' "$destination" >/dev/null || die 'Generated channel Job manifest is invalid YAML'
}

render_channel_receipt_to() {
  local destination="$1"
  {
    printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n'
    printf '  name: %s\n  namespace: %s\n' "$(channel_receipt_name)" "$(cluster_namespace)"
    printf '  labels: {app.kubernetes.io/managed-by: fabricctl, fabric.network.tools/channel: %s}\n' "$(channel_name)"
    printf 'data:\n'
    printf '  channel: %s\n' "$(channel_name)"
    printf '  profileSha256: "%s"\n' "$(channel_profile_sha)"
    printf '  jobName: %s\n' "$(channel_job_name)"
    printf '  consenters: %s\n' "$(channel_consenter_csv)"
  } >"$destination"
  yq e '.' "$destination" >/dev/null || die 'Generated channel receipt is invalid YAML'
}

validate_channel_artifacts() {
  local manifest="$1" receipt="$2" configmap_count job_count forbidden wrong_namespace job_name unsafe_image
  job_name="$(channel_job_name)"
  configmap_count="$(yq ea '[select(.kind == "ConfigMap")] | length' "$manifest")"
  job_count="$(yq ea '[select(.kind == "Job")] | length' "$manifest")"
  [[ "$configmap_count" == 1 && "$job_count" == 1 ]] || die 'Channel manifest must contain exactly one ConfigMap and one Job'
  [[ "$(yq e -r 'select(.kind == "Job") | .metadata.name' "$manifest")" == "$job_name" ]] || die 'Channel Job name is not deterministic'
  [[ "$(yq e -r '.metadata.name' "$receipt")" == "$(channel_receipt_name)" ]] || die 'Channel receipt name is invalid'
  forbidden="$(yq e 'select(.kind == "Namespace" or .kind == "StorageClass" or .kind == "PersistentVolume" or .kind == "ClusterRole" or .kind == "ClusterRoleBinding" or .kind == "CustomResourceDefinition" or .kind == "Role" or .kind == "RoleBinding" or .kind == "ServiceAccount" or .kind == "Secret") | .kind + "/" + .metadata.name' "$manifest" "$receipt")"
  [[ -z "$forbidden" ]] || die "Channel artifacts contain forbidden resources: $forbidden"
  wrong_namespace="$(yq e 'select(.kind != null and .metadata.namespace != "'"$(cluster_namespace)"'") | .kind + "/" + .metadata.name' "$manifest" "$receipt")"
  [[ -z "$wrong_namespace" ]] || die "Channel artifact rendered outside namespace $(cluster_namespace): $wrong_namespace"
  [[ "$(yq e -r 'select(.kind == "Job") | .spec.template.spec.automountServiceAccountToken' "$manifest")" == false ]] || die 'Channel Job must not mount a ServiceAccount token'
  [[ "$(yq e -r 'select(.kind == "Job") | (.spec.template.spec.initContainers // []) | length' "$manifest")" == 0 ]] || die 'Channel Job must not use init containers'
  [[ "$(yq e -r 'select(.kind == "Job") | .spec.template.spec.containers | length' "$manifest")" == 1 ]] || die 'Channel Job must contain exactly one container'
  [[ "$(yq e -r 'select(.kind == "Job") | .spec.template.spec.containers[0].image' "$manifest")" == "$(fabric_tools_image)" ]] || die 'Channel Job rendered the wrong Fabric tools image'
  unsafe_image="$(yq e '.. | select(tag == "!!map" and has("image")) | .image | select(contains("@sha256:") | not)' "$manifest")"
  [[ -z "$unsafe_image" ]] || die "Channel Job contains an unpinned image: $unsafe_image"
  [[ "$(yq e -r 'select(.kind == "Job") | .spec.template.spec.securityContext.runAsNonRoot' "$manifest")" == true ]] || die 'Channel Job is missing runAsNonRoot'
  [[ "$(yq e -r 'select(.kind == "Job") | .spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem' "$manifest")" == true ]] || die 'Channel Job root filesystem must be read-only'
  [[ "$(yq e -r 'select(.kind == "Job") | .spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation' "$manifest")" == false ]] || die 'Channel Job allows privilege escalation'
  [[ "$(yq e -r 'select(.kind == "Job") | .spec.template.spec.containers[0].resources.requests.cpu' "$manifest")" != null ]] || die 'Channel Job resources are incomplete'
  [[ "$(yq e -r 'select(.kind == "Job") | .spec.template.spec.volumes[] | select(.name == "admin-tls") | .secret.secretName' "$manifest")" == "$(orderer_organization_name)-admin-tls" ]] || die 'Channel Job does not use the orderer admin TLS Secret'
  [[ "$(yq e -r 'select(.kind == "ConfigMap") | .metadata.annotations."fabric.network.tools/profile-sha256"' "$manifest")" == "$(channel_profile_sha)" ]] || die 'Channel ConfigMap profile digest is wrong'
  [[ "$(yq e -r '.data.profileSha256' "$receipt")" == "$(channel_profile_sha)" ]] || die 'Channel receipt profile digest is wrong'
  if rg -q 'kubectl|pods/exec|hostPath:|:latest|REPLACE_WITH' "$manifest"; then die 'Channel Job rendered an unsafe command, mount, image, or placeholder'; fi
  for command_name in configtxgen 'osnadmin channel list' 'osnadmin channel join' CHANNEL_READY; do
    rg -F "$command_name" "$manifest" >/dev/null || die "Channel Job is missing command contract: $command_name"
  done
}

render_and_validate_channel_artifacts() {
  local profile_temp runner_temp manifest_temp receipt_temp sha_temp
  profile_temp="$(mktemp "${TMPDIR:-/tmp}/fabric-channel-profile.XXXXXX")"
  render_channel_profile_to "$profile_temp"
  FABRIC_CHANNEL_PROFILE_SHA="$(sha256_file "$profile_temp")"
  export FABRIC_CHANNEL_PROFILE_SHA
  runner_temp="$(mktemp "${TMPDIR:-/tmp}/fabric-channel-runner.XXXXXX")"
  render_channel_run_script_to "$runner_temp"
  FABRIC_CHANNEL_EXECUTION_SHA="$(printf '%s\n%s\n%s\n' "$(channel_profile_sha)" "$(fabric_tools_image)" "$(sha256_file "$runner_temp")" | sha256_stream)"
  export FABRIC_CHANNEL_EXECUTION_SHA
  manifest_temp="$(mktemp "${TMPDIR:-/tmp}/fabric-channel-manifest.XXXXXX")"
  receipt_temp="$(mktemp "${TMPDIR:-/tmp}/fabric-channel-receipt.XXXXXX")"
  render_channel_manifest_to "$manifest_temp" "$profile_temp" "$runner_temp"
  render_channel_receipt_to "$receipt_temp"
  validate_channel_artifacts "$manifest_temp" "$receipt_temp"
  sha_temp="$(mktemp "${TMPDIR:-/tmp}/fabric-channel-sha.XXXXXX")"
  printf '%s\n' "$(channel_profile_sha)" >"$sha_temp"
  write_if_changed "$profile_temp" "$(channel_profile_file)"
  write_if_changed "$runner_temp" "$(channel_run_script_file)"
  write_if_changed "$sha_temp" "$(channel_profile_sha_file)"
  write_if_changed "$manifest_temp" "$(channel_render_file)"
  write_if_changed "$receipt_temp" "$(channel_receipt_render_file)"
  log_ok "Rendered deterministic channel profile: $(channel_name) ($(channel_profile_sha))"
}

prepare_channel_profile_sha() {
  local profile_temp="$FABRIC_TOOL_TEMP/configtx.yaml" runner_temp="$FABRIC_TOOL_TEMP/run.sh"
  render_channel_profile_to "$profile_temp"
  FABRIC_CHANNEL_PROFILE_SHA="$(sha256_file "$profile_temp")"
  export FABRIC_CHANNEL_PROFILE_SHA
  render_channel_run_script_to "$runner_temp"
  FABRIC_CHANNEL_EXECUTION_SHA="$(printf '%s\n%s\n%s\n' "$(channel_profile_sha)" "$(fabric_tools_image)" "$(sha256_file "$runner_temp")" | sha256_stream)"
  export FABRIC_CHANNEL_EXECUTION_SHA
}

admit_channel_artifacts() {
  kubectl "${KUBECTL_ARGS[@]}" apply --server-side --dry-run=server --field-manager=fabricctl-admission --force-conflicts -f "$(channel_render_file)" >/dev/null
  kubectl "${KUBECTL_ARGS[@]}" apply --server-side --dry-run=server --field-manager=fabricctl-admission --force-conflicts -f "$(channel_receipt_render_file)" >/dev/null
  log_ok "Server-side admission passed for channel Job and receipt: $(channel_name)"
}

channel_receipt_exists() {
  kubectl "${KUBECTL_ARGS[@]}" get configmap "$(channel_receipt_name)" >/dev/null 2>&1
}

verify_channel_receipt() {
  local receipt actual
  receipt="$(channel_receipt_name)"
  kubectl "${KUBECTL_ARGS[@]}" get configmap "$receipt" >/dev/null 2>&1 || die "Missing channel receipt ConfigMap: $receipt"
  actual="$(kubectl "${KUBECTL_ARGS[@]}" get configmap "$receipt" -o jsonpath='{.data.channel}')"
  [[ "$actual" == "$(channel_name)" ]] || die "Channel receipt records a different channel: $actual"
  actual="$(kubectl "${KUBECTL_ARGS[@]}" get configmap "$receipt" -o jsonpath='{.data.profileSha256}')"
  [[ "$actual" == "$(channel_profile_sha)" ]] || die "Existing channel profile is immutable in v1alpha1; receipt digest is $actual, desired is $(channel_profile_sha)"
  actual="$(kubectl "${KUBECTL_ARGS[@]}" get configmap "$receipt" -o jsonpath='{.data.jobName}')"
  is_rfc1123_label "$actual" || die "Channel receipt references an invalid Job name: $actual"
  [[ "$actual" == "$(channel_operation_name)-"* ]] || die "Channel receipt references a Job outside this channel operation: $actual"
  actual="$(kubectl "${KUBECTL_ARGS[@]}" get configmap "$receipt" -o jsonpath='{.data.consenters}')"
  [[ "$actual" == "$(channel_consenter_csv)" ]] || die "Channel receipt consenter set differs from the desired topology: $actual"
  log_ok "Verified immutable channel receipt: $receipt"
}

channel_evidence_job_name() {
  if channel_receipt_exists; then
    kubectl "${KUBECTL_ARGS[@]}" get configmap "$(channel_receipt_name)" -o jsonpath='{.data.jobName}'
  else
    channel_job_name
  fi
}

verify_channel_job_evidence() {
  local job_name logs orderer_index0 orderer_name succeeded image image_id pod_name
  job_name="$(channel_evidence_job_name)"
  succeeded="$(kubectl "${KUBECTL_ARGS[@]}" get job "$job_name" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)"
  [[ "$succeeded" == 1 ]] || die "Channel Job is not complete: $job_name"
  [[ "$(kubectl "${KUBECTL_ARGS[@]}" get job "$job_name" -o jsonpath='{.spec.template.spec.automountServiceAccountToken}')" == false ]] || die "$job_name mounts a ServiceAccount token"
  image="$(kubectl "${KUBECTL_ARGS[@]}" get job "$job_name" -o jsonpath='{.spec.template.spec.containers[0].image}')"
  [[ "$image" =~ ^[^[:space:]]+@sha256:[a-f0-9]{64}$ ]] || die "$job_name uses an unpinned Fabric tools image: $image"
  pod_name="$(kubectl "${KUBECTL_ARGS[@]}" get pod -l "fabric.network.tools/channel-job=$job_name" -o jsonpath='{.items[0].metadata.name}')"
  image_id="$(kubectl "${KUBECTL_ARGS[@]}" get pod "$pod_name" -o jsonpath='{.status.containerStatuses[0].imageID}')"
  [[ "$image_id" == *@"${image##*@}" ]] || die "$job_name runtime image digest does not match the configured digest: $image_id"
  logs="$(kubectl "${KUBECTL_ARGS[@]}" logs "job/$job_name")"
  printf '%s\n' "$logs" | rg -F "CHANNEL_BLOCK name=$(channel_name) profileSha256=$(channel_profile_sha)" >/dev/null || die "$job_name lacks channel block evidence"
  for ((orderer_index0 = 0; orderer_index0 < $(orderer_count); orderer_index0++)); do
    orderer_name="$(orderer_kubernetes_name "$orderer_index0")"
    printf '%s\n' "$logs" | rg -F "CHANNEL_READY name=$(channel_name) orderer=$orderer_name relation=consenter status=active" >/dev/null || die "$job_name lacks active-consenter evidence for $orderer_name"
  done
  log_ok "Verified channel Job evidence for all consenters: $job_name"
}

verify_raft_log_evidence() {
  local orderer_index0 orderer_name pod_name orderer_log combined_log="$FABRIC_TOOL_TEMP/raft-orderers.log"
  : >"$combined_log"
  for ((orderer_index0 = 0; orderer_index0 < $(orderer_count); orderer_index0++)); do
    orderer_name="$(orderer_kubernetes_name "$orderer_index0")"
    pod_name="$(kubectl "${KUBECTL_ARGS[@]}" get pod -l "app=$orderer_name" -o jsonpath='{.items[0].metadata.name}')"
    orderer_log="$FABRIC_TOOL_TEMP/${orderer_name}.log"
    kubectl "${KUBECTL_ARGS[@]}" logs "$pod_name" -c fabric-orderer >"$orderer_log"
    rg -F "$(channel_name)" "$orderer_log" >/dev/null || die "$orderer_name logs contain no evidence for channel $(channel_name)"
    rg 'Starting Raft node|created and started new channel|Created and started new channel' "$orderer_log" >/dev/null || die "$orderer_name logs contain no Raft startup evidence"
    printf '\n' >>"$combined_log"; sed 's/^/'"$orderer_name"': /' "$orderer_log" >>"$combined_log"
  done
  rg 'became leader|Raft leader changed:.*->[[:space:]]*[1-9]' "$combined_log" >/dev/null || die "No Raft leader election evidence found for channel $(channel_name)"
  log_ok "Verified Raft startup on every consenter and leader-election evidence for $(channel_name)"
}

deploy_channel_job() {
  local job_name failed succeeded
  if channel_receipt_exists; then
    verify_channel_receipt
    log_ok "Channel receipt already exists; preserving channel $(channel_name)"
    return 0
  fi
  job_name="$(channel_job_name)"
  failed="$(kubectl "${KUBECTL_ARGS[@]}" get job "$job_name" -o jsonpath='{.status.failed}' 2>/dev/null || true)"
  succeeded="$(kubectl "${KUBECTL_ARGS[@]}" get job "$job_name" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)"
  if [[ -n "$failed" && "$failed" != 0 && "$succeeded" != 1 ]]; then
    log_warn "Removing failed, digest-matched channel Job before retry: $job_name"
    kubectl "${KUBECTL_ARGS[@]}" delete job "$job_name" --wait=true >/dev/null
  fi
  if ! kubectl "${KUBECTL_ARGS[@]}" get job "$job_name" >/dev/null 2>&1; then
    kubectl "${KUBECTL_ARGS[@]}" apply --server-side --field-manager=fabricctl --force-conflicts -f "$(channel_render_file)" >/dev/null
    log_ok "Created channel configuration and Job: $job_name"
  else
    log_info "Resuming existing digest-matched channel Job: $job_name"
  fi
  kubectl "${KUBECTL_ARGS[@]}" wait --for=condition=complete "job/$job_name" --timeout=10m >/dev/null || {
    kubectl "${KUBECTL_ARGS[@]}" logs "job/$job_name" --tail=200 >&2 || true
    die "Channel Job did not complete: $job_name"
  }
  verify_channel_job_evidence
  kubectl "${KUBECTL_ARGS[@]}" apply --server-side --field-manager=fabricctl -f "$(channel_receipt_render_file)" >/dev/null
  verify_channel_receipt
  log_ok "Channel joined to all orderers and receipt recorded: $(channel_name)"
}
