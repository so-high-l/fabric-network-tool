#!/usr/bin/env bash

peer_channel_artifact_directory() {
  printf '%s/channels/%s/peers' "$FABRIC_TOOL_OUTPUT" "$(channel_name)"
}

peer_channel_plan_file() {
  printf '%s/plan.yaml' "$(peer_channel_artifact_directory)"
}

peer_channel_runner_file() {
  printf '%s/%s-run.sh' "$(peer_channel_artifact_directory)" "$1"
}

peer_channel_render_file() {
  printf '%s/rendered/channels/%s-%s.yaml' "$FABRIC_TOOL_OUTPUT" "$(channel_name)" "$1"
}

peer_channel_receipt_render_file() {
  printf '%s/rendered/channels/%s-peers-receipt.yaml' "$FABRIC_TOOL_OUTPUT" "$(channel_name)"
}

peer_channel_plan_sha() {
  : "${FABRIC_PEER_CHANNEL_PLAN_SHA:?FABRIC_PEER_CHANNEL_PLAN_SHA is required}"
  printf '%s' "$FABRIC_PEER_CHANNEL_PLAN_SHA"
}

peer_channel_receipt_name() {
  printf '%s-receipt' "$(peer_channel_operation_name)"
}

peer_channel_execution_sha() {
  local org_name="$1" runner_file="$2"
  printf '%s\n%s\n%s\n%s\n%s\n' \
    "$(peer_channel_plan_sha)" "$org_name" "$(fabric_tools_image)" "$(sha256_file "$runner_file")" 'peer-channel-job-v4' |
    sha256_stream
}

peer_channel_job_name() {
  local org_name="$1" execution_sha="$2"
  printf '%s-%s-%s' "$(peer_channel_operation_name)" "$org_name" "${execution_sha:0:10}"
}

peer_channel_anchor_name() {
  local org_index1="$1" org_name="$2"
  peer_kubernetes_name "$org_index1" 0 "$org_name"
}

peer_channel_peers_csv() {
  local org_index1 org_name peer_index0 peer_name value=''
  for ((org_index1 = 1; org_index1 <= $(peer_organization_count); org_index1++)); do
    org_name="$(peer_organization_name "$org_index1")"
    for ((peer_index0 = 0; peer_index0 < $(peers_per_organization); peer_index0++)); do
      peer_name="$(peer_kubernetes_name "$org_index1" "$peer_index0" "$org_name")"
      [[ -z "$value" ]] || value+=','
      value+="$peer_name"
    done
  done
  printf '%s' "$value"
}

peer_channel_anchors_csv() {
  local org_index1 org_name anchor_name value=''
  for ((org_index1 = 1; org_index1 <= $(peer_organization_count); org_index1++)); do
    org_name="$(peer_organization_name "$org_index1")"
    anchor_name="$(peer_channel_anchor_name "$org_index1" "$org_name")"
    [[ -z "$value" ]] || value+=','
    value+="${org_name}=$(service_fqdn "$anchor_name"):7051"
  done
  printf '%s' "$value"
}

render_peer_channel_plan_to() {
  local destination="$1" orderer_name org_index1 org_name org_msp anchor_name peer_index0 peer_name
  orderer_name="$(orderer_kubernetes_name 0)"
  {
    printf 'apiVersion: fabric.network.tools/v1alpha1\n'
    printf 'kind: FabricPeerChannelPlan\n'
    printf 'metadata:\n  name: %s\n' "$(peer_channel_operation_name)"
    printf 'spec:\n'
    printf '  namespace: %s\n' "$(cluster_namespace)"
    printf '  channel: %s\n' "$(channel_name)"
    printf '  channelProfileSha256: "%s"\n' "$(channel_profile_sha)"
    printf '  orderer:\n    endpoint: %s:7050\n    tlsSecret: %s-tls\n' "$(service_fqdn "$orderer_name")" "$orderer_name"
    printf '  organizations:\n'
    for ((org_index1 = 1; org_index1 <= $(peer_organization_count); org_index1++)); do
      org_name="$(peer_organization_name "$org_index1")"
      org_msp="$(peer_organization_msp_id "$org_index1" "$org_name")"
      anchor_name="$(peer_channel_anchor_name "$org_index1" "$org_name")"
      printf '    - name: %s\n' "$org_name"
      printf '      mspId: %s\n' "$org_msp"
      printf '      adminMspSecret: %s-admin-msp\n' "$org_name"
      printf '      anchorPeer: {name: %s, host: %s, port: 7051}\n' "$anchor_name" "$(service_fqdn "$anchor_name")"
      printf '      peers:\n'
      for ((peer_index0 = 0; peer_index0 < $(peers_per_organization); peer_index0++)); do
        peer_name="$(peer_kubernetes_name "$org_index1" "$peer_index0" "$org_name")"
        printf '        - {name: %s, address: %s:7051, tlsSecret: %s-tls}\n' "$peer_name" "$(service_fqdn "$peer_name")" "$peer_name"
      done
    done
  } >"$destination"
  yq e '.' "$destination" >/dev/null || die 'Generated peer channel plan is invalid YAML'
}

render_peer_channel_runner_to() {
  local destination="$1" org_index1="$2" org_name="$3"
  local org_msp orderer_name anchor_name peer_index0 peer_name
  org_msp="$(peer_organization_msp_id "$org_index1" "$org_name")"
  orderer_name="$(orderer_kubernetes_name 0)"
  anchor_name="$(peer_channel_anchor_name "$org_index1" "$org_name")"
  {
    printf '#!/bin/sh\nset -eu\numask 077\n'
    printf 'CHANNEL_NAME=%s\n' "$(channel_name)"
    printf 'ORG_NAME=%s\n' "$org_name"
    printf 'MSP_ID=%s\n' "$org_msp"
    printf 'ORDERER_ENDPOINT=%s:7050\n' "$(service_fqdn "$orderer_name")"
    printf 'ORDERER_CA=/tls/orderer/ca.crt\n'
    printf 'ANCHOR_NAME=%s\n' "$anchor_name"
    printf 'ANCHOR_HOST=%s\n' "$(service_fqdn "$anchor_name")"
    printf 'ANCHOR_PORT=7051\n'
    printf 'export CORE_PEER_LOCALMSPID="$MSP_ID"\n'
    printf 'export CORE_PEER_MSPCONFIGPATH=/admin/msp\n'
    printf 'export CORE_PEER_TLS_ENABLED=true\n'
    printf 'export CORE_PEER_ADDRESS=%s:7051\n' "$(service_fqdn "$anchor_name")"
    printf 'export CORE_PEER_TLS_ROOTCERT_FILE=/tls/peers/%s/ca.crt\n' "$anchor_name"
    printf '\npeer channel fetch 0 /work/channel.block -o "$ORDERER_ENDPOINT" -c "$CHANNEL_NAME" --tls --cafile "$ORDERER_CA"\n'
    printf 'printf '\''CHANNEL_BLOCK_READY channel=%%s org=%%s\n'\'' "$CHANNEL_NAME" "$ORG_NAME"\n'
    for ((peer_index0 = 0; peer_index0 < $(peers_per_organization); peer_index0++)); do
      peer_name="$(peer_kubernetes_name "$org_index1" "$peer_index0" "$org_name")"
      printf '\nexport CORE_PEER_ADDRESS=%s:7051\n' "$(service_fqdn "$peer_name")"
      printf 'export CORE_PEER_TLS_ROOTCERT_FILE=/tls/peers/%s/ca.crt\n' "$peer_name"
      printf 'if peer channel list > /work/%s-channels.txt 2>&1 && sed -e '\''s/^[[:space:]]*//;s/[[:space:]]*$//'\'' /work/%s-channels.txt | grep -Fx "$CHANNEL_NAME" >/dev/null; then\n' "$peer_name" "$peer_name"
      printf '  printf '\''PEER_PRESENT channel=%%s org=%%s peer=%s\n'\'' "$CHANNEL_NAME" "$ORG_NAME"\n' "$peer_name"
      printf 'else\n'
      printf '  peer channel join -b /work/channel.block\n'
      printf '  printf '\''PEER_JOINED channel=%%s org=%%s peer=%s\n'\'' "$CHANNEL_NAME" "$ORG_NAME"\n' "$peer_name"
      printf 'fi\n'
      printf 'peer channel getinfo -c "$CHANNEL_NAME" > /work/%s-info.txt 2>&1\n' "$peer_name"
      printf '%s\n' "height=\"\$(sed -n 's/.*\"height\":[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p' /work/${peer_name}-info.txt | head -n 1)\""
      printf '[ -n "$height" ] || { cat /work/%s-info.txt >&2; printf '\''Unable to read ledger height for %s\n'\'' >&2; exit 1; }\n' "$peer_name" "$peer_name"
      printf 'printf '\''PEER_READY channel=%%s org=%%s peer=%s height=%%s\n'\'' "$CHANNEL_NAME" "$ORG_NAME" "$height"\n' "$peer_name"
    done
    printf '\nexport CORE_PEER_ADDRESS="$ANCHOR_HOST:$ANCHOR_PORT"\n'
    printf 'export CORE_PEER_TLS_ROOTCERT_FILE=/tls/peers/%s/ca.crt\n' "$anchor_name"
    printf '\nfetch_config() {\n'
    printf '  output="$1"\n'
    printf '  peer channel fetch config /work/config-block.pb -o "$ORDERER_ENDPOINT" -c "$CHANNEL_NAME" --tls --cafile "$ORDERER_CA" >/work/fetch-config.txt 2>&1\n'
    printf '  configtxlator proto_decode --input /work/config-block.pb --type common.Block --output /work/config-block.json\n'
    printf '  jq '\''.data.data[0].payload.data.config'\'' /work/config-block.json > "$output"\n'
    printf '}\n'
    printf '\nanchor_is_exact() {\n'
    printf '  config="$1"\n'
    printf '  jq -e --arg msp "$MSP_ID" --arg host "$ANCHOR_HOST" --argjson port "$ANCHOR_PORT" '\''\n'
    printf '    (.channel_group.groups.Application.groups[$msp].values.AnchorPeers.value.anchor_peers // []) as $anchors\n'
    printf '    | ($anchors | length) == 1\n'
    printf '      and $anchors[0].host == $host\n'
    printf '      and $anchors[0].port == $port'\'' "$config" >/dev/null\n'
    printf '}\n'
    printf '\nfetch_config /work/original-config.json\n'
    printf 'jq -e --arg msp "$MSP_ID" '\''.channel_group.groups.Application.groups[$msp]'\'' /work/original-config.json >/dev/null || { printf '\''MSP %%s is absent from channel %%s\n'\'' "$MSP_ID" "$CHANNEL_NAME" >&2; exit 1; }\n'
    printf 'if anchor_is_exact /work/original-config.json; then\n'
    printf '  printf '\''ANCHOR_PRESENT channel=%%s org=%%s msp=%%s host=%%s port=%%s\n'\'' "$CHANNEL_NAME" "$ORG_NAME" "$MSP_ID" "$ANCHOR_HOST" "$ANCHOR_PORT"\n'
    printf 'else\n'
    printf '  jq --arg msp "$MSP_ID" --arg host "$ANCHOR_HOST" --argjson port "$ANCHOR_PORT" '\''\n'
    printf '    .channel_group.groups.Application.groups[$msp].values.AnchorPeers =\n'
    printf '      ((.channel_group.groups.Application.groups[$msp].values.AnchorPeers // {"mod_policy":"Admins","value":{},"version":"0"})\n'
    printf '       | .mod_policy = "Admins"\n'
    printf '       | .value.anchor_peers = [{"host":$host,"port":$port}])'\'' /work/original-config.json > /work/modified-config.json\n'
    printf '  configtxlator proto_encode --input /work/original-config.json --type common.Config --output /work/original-config.pb\n'
    printf '  configtxlator proto_encode --input /work/modified-config.json --type common.Config --output /work/modified-config.pb\n'
    printf '  configtxlator compute_update --channel_id "$CHANNEL_NAME" --original /work/original-config.pb --updated /work/modified-config.pb --output /work/config-update.pb\n'
    printf '  configtxlator proto_decode --input /work/config-update.pb --type common.ConfigUpdate --output /work/config-update.json\n'
    printf '  jq -n --arg channel "$CHANNEL_NAME" --slurpfile update /work/config-update.json '\''\n'
    printf '    {"payload":{"header":{"channel_header":{"channel_id":$channel,"type":2}},"data":{"config_update":$update[0]}}}'\'' > /work/config-update-envelope.json\n'
    printf '  configtxlator proto_encode --input /work/config-update-envelope.json --type common.Envelope --output /work/anchor-update.pb\n'
    printf '  peer channel update -f /work/anchor-update.pb -o "$ORDERER_ENDPOINT" -c "$CHANNEL_NAME" --tls --cafile "$ORDERER_CA"\n'
    printf '  printf '\''ANCHOR_UPDATED channel=%%s org=%%s msp=%%s host=%%s port=%%s\n'\'' "$CHANNEL_NAME" "$ORG_NAME" "$MSP_ID" "$ANCHOR_HOST" "$ANCHOR_PORT"\n'
    printf 'fi\n'
    printf '\nattempt=0\nanchor_ready=false\n'
    printf 'while [ "$attempt" -lt 30 ]; do\n'
    printf '  if fetch_config /work/verified-config.json && anchor_is_exact /work/verified-config.json; then anchor_ready=true; break; fi\n'
    printf '  attempt=$((attempt + 1))\n  sleep 2\ndone\n'
    printf '[ "$anchor_ready" = true ] || { printf '\''Anchor peer did not converge for %%s\n'\'' "$ORG_NAME" >&2; exit 1; }\n'
    printf 'printf '\''ANCHOR_READY channel=%%s org=%%s msp=%%s host=%%s port=%%s\n'\'' "$CHANNEL_NAME" "$ORG_NAME" "$MSP_ID" "$ANCHOR_HOST" "$ANCHOR_PORT"\n'
  } >"$destination"
  chmod 0755 "$destination"
  sh -n "$destination" || die "Generated peer channel runner has invalid shell syntax: $org_name"
}

render_peer_channel_manifest_to() {
  local destination="$1" org_index1="$2" org_name="$3" runner_file="$4" execution_sha="$5"
  local job_name org_msp pull_secret orderer_name peer_index0 peer_name
  job_name="$(peer_channel_job_name "$org_name" "$execution_sha")"
  org_msp="$(peer_organization_msp_id "$org_index1" "$org_name")"
  pull_secret="$(image_pull_secret)"
  orderer_name="$(orderer_kubernetes_name 0)"
  {
    printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n'
    printf '  name: %s\n  namespace: %s\n' "$job_name" "$(cluster_namespace)"
    printf '  labels: {app.kubernetes.io/managed-by: fabricctl, fabric.network.tools/peer-channel: %s, fabric.network.tools/organization: %s}\n' "$(channel_name)" "$org_name"
    printf '  annotations: {fabric.network.tools/plan-sha256: "%s", fabric.network.tools/channel-profile-sha256: "%s"}\n' "$(peer_channel_plan_sha)" "$(channel_profile_sha)"
    printf 'data:\n'
    printf '  run.sh: |-\n'; sed 's/^/    /' "$runner_file"
    render_msp_config_data 'config.yaml'
    printf '%s\n' '---'
    printf 'apiVersion: batch/v1\nkind: Job\nmetadata:\n'
    printf '  name: %s\n  namespace: %s\n' "$job_name" "$(cluster_namespace)"
    printf '  labels: {app.kubernetes.io/managed-by: fabricctl, fabric.network.tools/peer-channel: %s, fabric.network.tools/organization: %s}\n' "$(channel_name)" "$org_name"
    printf '  annotations: {fabric.network.tools/plan-sha256: "%s", fabric.network.tools/channel-profile-sha256: "%s"}\n' "$(peer_channel_plan_sha)" "$(channel_profile_sha)"
    printf 'spec:\n  backoffLimit: 1\n  activeDeadlineSeconds: 600\n  template:\n    metadata:\n'
    printf '      labels: {app.kubernetes.io/managed-by: fabricctl, fabric.network.tools/peer-channel: %s, fabric.network.tools/peer-channel-job: %s, fabric.network.tools/organization: %s}\n' "$(channel_name)" "$job_name" "$org_name"
    printf '    spec:\n      restartPolicy: Never\n'
    printf '      serviceAccountName: %s\n' "$(cluster_service_account)"
    printf '      automountServiceAccountToken: false\n'
    printf '      securityContext: {runAsNonRoot: true, runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000, seccompProfile: {type: RuntimeDefault}}\n'
    if [[ -n "$pull_secret" ]]; then printf '      imagePullSecrets: [{name: %s}]\n' "$pull_secret"; fi
    printf '      containers:\n        - name: peer-channel-admin\n'
    printf '          image: %s\n          imagePullPolicy: IfNotPresent\n' "$(fabric_tools_image)"
    printf '          command: [/bin/sh, /operation/run.sh]\n'
    printf '          env: [{name: FABRIC_CFG_PATH, value: /operation}, {name: HOME, value: /work}, {name: FABRIC_LOGGING_SPEC, value: info}]\n'
    printf '          securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}\n'
    printf '          resources: {requests: {cpu: 100m, memory: 128Mi}, limits: {cpu: 500m, memory: 512Mi}}\n'
    printf '          volumeMounts:\n'
    printf '            - {name: operation, mountPath: /operation, readOnly: true}\n'
    printf '            - {name: admin-msp, mountPath: /admin/msp, readOnly: true}\n'
    printf '            - {name: tls, mountPath: /tls, readOnly: true}\n'
    printf '            - {name: work, mountPath: /work}\n'
    printf '      volumes:\n'
    printf '        - name: operation\n          projected:\n            defaultMode: 0550\n            sources:\n'
    printf '              - configMap: {name: %s, items: [{key: run.sh, path: run.sh}]}\n' "$job_name"
    printf '              - configMap: {name: %s-builders-config, items: [{key: core.yaml, path: core.yaml}]}\n' "$(peer_channel_anchor_name "$org_index1" "$org_name")"
    printf '        - name: admin-msp\n          projected:\n            defaultMode: 0440\n            sources:\n'
    printf '              - configMap: {name: %s, items: [{key: config.yaml, path: config.yaml}]}\n' "$job_name"
    printf '              - secret:\n                  name: %s-admin-msp\n                  items:\n' "$org_name"
    printf '                    - {key: admincerts, path: admincerts/admin.crt}\n'
    printf '                    - {key: cacerts, path: cacerts/ca.crt}\n'
    printf '                    - {key: keystore, path: keystore/key.pem}\n'
    printf '                    - {key: signcerts, path: signcerts/cert.pem}\n'
    printf '                    - {key: tlscacerts, path: tlscacerts/tlsca.crt}\n'
    printf '        - name: tls\n          projected:\n            defaultMode: 0440\n            sources:\n'
    printf '              - secret: {name: %s-tls, items: [{key: cacrt, path: orderer/ca.crt}]}\n' "$orderer_name"
    for ((peer_index0 = 0; peer_index0 < $(peers_per_organization); peer_index0++)); do
      peer_name="$(peer_kubernetes_name "$org_index1" "$peer_index0" "$org_name")"
      printf '              - secret: {name: %s-tls, items: [{key: cacrt, path: peers/%s/ca.crt}]}\n' "$peer_name" "$peer_name"
    done
    printf '        - name: work\n          emptyDir: {}\n'
  } >"$destination"
  yq e '.' "$destination" >/dev/null || die "Generated peer channel Job manifest is invalid YAML: $org_name"
  [[ "$org_msp" != null ]] || die "Invalid MSP ID for $org_name"
}

peer_channel_current_jobs_csv() {
  local org_index1 org_name runner_file execution_sha job_name value=''
  for ((org_index1 = 1; org_index1 <= $(peer_organization_count); org_index1++)); do
    org_name="$(peer_organization_name "$org_index1")"
    runner_file="$(peer_channel_runner_file "$org_name")"
    execution_sha="$(peer_channel_execution_sha "$org_name" "$runner_file")"
    job_name="$(peer_channel_job_name "$org_name" "$execution_sha")"
    [[ -z "$value" ]] || value+=','
    value+="${org_name}=${job_name}"
  done
  printf '%s' "$value"
}

render_peer_channel_receipt_to() {
  local destination="$1"
  {
    printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n'
    printf '  name: %s\n  namespace: %s\n' "$(peer_channel_receipt_name)" "$(cluster_namespace)"
    printf '  labels: {app.kubernetes.io/managed-by: fabricctl, fabric.network.tools/peer-channel: %s}\n' "$(channel_name)"
    printf 'data:\n'
    printf '  channel: %s\n' "$(channel_name)"
    printf '  channelProfileSha256: "%s"\n' "$(channel_profile_sha)"
    printf '  planSha256: "%s"\n' "$(peer_channel_plan_sha)"
    printf '  peers: %s\n' "$(peer_channel_peers_csv)"
    printf '  anchors: %s\n' "$(peer_channel_anchors_csv)"
    printf '  jobs: %s\n' "$(peer_channel_current_jobs_csv)"
  } >"$destination"
  yq e '.' "$destination" >/dev/null || die 'Generated peer channel receipt is invalid YAML'
}

validate_peer_channel_artifacts() {
  local org_index1 org_name manifest job_name runner_file execution_sha forbidden wrong_namespace unsafe_image receipt
  receipt="$(peer_channel_receipt_render_file)"
  [[ "$(yq e -r '.metadata.name' "$receipt")" == "$(peer_channel_receipt_name)" ]] || die 'Peer channel receipt name is invalid'
  [[ "$(yq e -r '.data.planSha256' "$receipt")" == "$(peer_channel_plan_sha)" ]] || die 'Peer channel receipt plan digest is wrong'
  for ((org_index1 = 1; org_index1 <= $(peer_organization_count); org_index1++)); do
    org_name="$(peer_organization_name "$org_index1")"
    manifest="$(peer_channel_render_file "$org_name")"
    runner_file="$(peer_channel_runner_file "$org_name")"
    execution_sha="$(peer_channel_execution_sha "$org_name" "$runner_file")"
    job_name="$(peer_channel_job_name "$org_name" "$execution_sha")"
    [[ "$(yq ea '[select(.kind == "ConfigMap")] | length' "$manifest")" == 1 ]] || die "$org_name peer channel manifest must contain one ConfigMap"
    [[ "$(yq ea '[select(.kind == "Job")] | length' "$manifest")" == 1 ]] || die "$org_name peer channel manifest must contain one Job"
    [[ "$(yq e -r 'select(.kind == "Job") | .metadata.name' "$manifest")" == "$job_name" ]] || die "$org_name peer channel Job name is not deterministic"
    [[ "$(yq e -r 'select(.kind == "Job") | .spec.template.spec.automountServiceAccountToken' "$manifest")" == false ]] || die "$job_name must not mount a ServiceAccount token"
    [[ "$(yq e -r 'select(.kind == "Job") | (.spec.template.spec.initContainers // []) | length' "$manifest")" == 0 ]] || die "$job_name must not use init containers"
    [[ "$(yq e -r 'select(.kind == "Job") | .spec.template.spec.containers | length' "$manifest")" == 1 ]] || die "$job_name must have one container"
    [[ "$(yq e -r 'select(.kind == "Job") | .spec.template.spec.containers[0].image' "$manifest")" == "$(fabric_tools_image)" ]] || die "$job_name rendered the wrong Fabric tools image"
    [[ "$(yq e -r 'select(.kind == "Job") | .spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem' "$manifest")" == true ]] || die "$job_name root filesystem must be read-only"
    [[ "$(yq e -r 'select(.kind == "Job") | .spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation' "$manifest")" == false ]] || die "$job_name allows privilege escalation"
    [[ "$(yq e -r 'select(.kind == "Job") | .spec.template.spec.containers[0].resources.requests.cpu' "$manifest")" != null ]] || die "$job_name resources are incomplete"
    forbidden="$(yq e 'select(.kind == "Namespace" or .kind == "StorageClass" or .kind == "PersistentVolume" or .kind == "ClusterRole" or .kind == "ClusterRoleBinding" or .kind == "CustomResourceDefinition" or .kind == "Role" or .kind == "RoleBinding" or .kind == "ServiceAccount" or .kind == "Secret") | .kind + "/" + .metadata.name' "$manifest")"
    [[ -z "$forbidden" ]] || die "$org_name peer channel manifest contains forbidden resources: $forbidden"
    wrong_namespace="$(yq e 'select(.kind != null and .metadata.namespace != "'"$(cluster_namespace)"'") | .kind + "/" + .metadata.name' "$manifest")"
    [[ -z "$wrong_namespace" ]] || die "$org_name peer channel artifact rendered outside namespace $(cluster_namespace): $wrong_namespace"
    unsafe_image="$(yq e '.. | select(tag == "!!map" and has("image")) | .image | select(contains("@sha256:") | not)' "$manifest")"
    [[ -z "$unsafe_image" ]] || die "$job_name contains an unpinned image: $unsafe_image"
    if rg -q 'kubectl|pods/exec|hostPath:|:latest|REPLACE_WITH' "$manifest"; then die "$job_name rendered an unsafe command, mount, image, or placeholder"; fi
    for command_name in 'peer channel fetch' 'peer channel list' 'peer channel join' 'peer channel getinfo' 'configtxlator compute_update' 'peer channel update' PEER_READY ANCHOR_READY; do
      rg -F "$command_name" "$manifest" >/dev/null || die "$job_name is missing command contract: $command_name"
    done
    [[ "$(yq e -r 'select(.kind == "Job") | .spec.template.spec.volumes[] | select(.name == "operation") | .projected.sources[] | select(.configMap.name == "'"$(peer_channel_anchor_name "$org_index1" "$org_name")"'-builders-config") | .configMap.items[0].key' "$manifest")" == core.yaml ]] || die "$job_name does not project the validated peer core.yaml"
  done
  forbidden="$(yq e 'select(.kind == "Namespace" or .kind == "Secret" or .kind == "Role" or .kind == "RoleBinding") | .kind + "/" + .metadata.name' "$receipt")"
  [[ -z "$forbidden" ]] || die "Peer channel receipt contains forbidden resources: $forbidden"
}

render_and_validate_peer_channel_artifacts() {
  local plan_temp org_index1 org_name runner_temp runner_file manifest_temp execution_sha receipt_temp
  plan_temp="$(mktemp "${TMPDIR:-/tmp}/fabric-peer-channel-plan.XXXXXX")"
  render_peer_channel_plan_to "$plan_temp"
  FABRIC_PEER_CHANNEL_PLAN_SHA="$(sha256_file "$plan_temp")"
  export FABRIC_PEER_CHANNEL_PLAN_SHA
  write_if_changed "$plan_temp" "$(peer_channel_plan_file)"
  for ((org_index1 = 1; org_index1 <= $(peer_organization_count); org_index1++)); do
    org_name="$(peer_organization_name "$org_index1")"
    runner_temp="$(mktemp "${TMPDIR:-/tmp}/fabric-peer-channel-runner.XXXXXX")"
    render_peer_channel_runner_to "$runner_temp" "$org_index1" "$org_name"
    runner_file="$(peer_channel_runner_file "$org_name")"
    write_if_changed "$runner_temp" "$runner_file"
    execution_sha="$(peer_channel_execution_sha "$org_name" "$runner_file")"
    manifest_temp="$(mktemp "${TMPDIR:-/tmp}/fabric-peer-channel-manifest.XXXXXX")"
    render_peer_channel_manifest_to "$manifest_temp" "$org_index1" "$org_name" "$runner_file" "$execution_sha"
    write_if_changed "$manifest_temp" "$(peer_channel_render_file "$org_name")"
  done
  receipt_temp="$(mktemp "${TMPDIR:-/tmp}/fabric-peer-channel-receipt.XXXXXX")"
  render_peer_channel_receipt_to "$receipt_temp"
  write_if_changed "$receipt_temp" "$(peer_channel_receipt_render_file)"
  validate_peer_channel_artifacts
  log_ok "Rendered deterministic peer channel plan: $(channel_name) ($(peer_channel_plan_sha))"
}

prepare_peer_channel_plan_sha() {
  local plan_temp="$FABRIC_TOOL_TEMP/peer-channel-plan.yaml"
  render_peer_channel_plan_to "$plan_temp"
  FABRIC_PEER_CHANNEL_PLAN_SHA="$(sha256_file "$plan_temp")"
  export FABRIC_PEER_CHANNEL_PLAN_SHA
}

admit_peer_channel_artifacts() {
  local org_index1 org_name
  for ((org_index1 = 1; org_index1 <= $(peer_organization_count); org_index1++)); do
    org_name="$(peer_organization_name "$org_index1")"
    kubectl "${KUBECTL_ARGS[@]}" apply --server-side --dry-run=server --field-manager=fabricctl-admission --force-conflicts -f "$(peer_channel_render_file "$org_name")" >/dev/null
  done
  kubectl "${KUBECTL_ARGS[@]}" apply --server-side --dry-run=server --field-manager=fabricctl-admission --force-conflicts -f "$(peer_channel_receipt_render_file)" >/dev/null
  log_ok "Server-side admission passed for all peer channel Jobs and receipt: $(channel_name)"
}

peer_channel_receipt_exists() {
  kubectl "${KUBECTL_ARGS[@]}" get configmap "$(peer_channel_receipt_name)" >/dev/null 2>&1
}

verify_peer_channel_receipt() {
  local receipt actual jobs org_index1 org_name job_name
  receipt="$(peer_channel_receipt_name)"
  kubectl "${KUBECTL_ARGS[@]}" get configmap "$receipt" >/dev/null 2>&1 || die "Missing peer channel receipt ConfigMap: $receipt"
  actual="$(kubectl "${KUBECTL_ARGS[@]}" get configmap "$receipt" -o jsonpath='{.data.channel}')"
  [[ "$actual" == "$(channel_name)" ]] || die "Peer channel receipt records a different channel: $actual"
  actual="$(kubectl "${KUBECTL_ARGS[@]}" get configmap "$receipt" -o jsonpath='{.data.channelProfileSha256}')"
  [[ "$actual" == "$(channel_profile_sha)" ]] || die "Peer channel receipt references a different immutable channel profile: $actual"
  actual="$(kubectl "${KUBECTL_ARGS[@]}" get configmap "$receipt" -o jsonpath='{.data.planSha256}')"
  [[ "$actual" == "$(peer_channel_plan_sha)" ]] || die "Existing peer membership/anchor plan is immutable in v1alpha1; receipt digest is $actual, desired is $(peer_channel_plan_sha)"
  actual="$(kubectl "${KUBECTL_ARGS[@]}" get configmap "$receipt" -o jsonpath='{.data.peers}')"
  [[ "$actual" == "$(peer_channel_peers_csv)" ]] || die "Peer channel receipt peer set differs from the desired topology: $actual"
  actual="$(kubectl "${KUBECTL_ARGS[@]}" get configmap "$receipt" -o jsonpath='{.data.anchors}')"
  [[ "$actual" == "$(peer_channel_anchors_csv)" ]] || die "Peer channel receipt anchor set differs from the desired topology: $actual"
  jobs="$(kubectl "${KUBECTL_ARGS[@]}" get configmap "$receipt" -o jsonpath='{.data.jobs}')"
  for ((org_index1 = 1; org_index1 <= $(peer_organization_count); org_index1++)); do
    org_name="$(peer_organization_name "$org_index1")"
    job_name="$(printf '%s' "$jobs" | tr ',' '\n' | sed -n 's/^'"$org_name"'=//p')"
    is_rfc1123_label "$job_name" || die "Peer channel receipt has no valid evidence Job for $org_name"
    [[ "$job_name" == "$(peer_channel_operation_name)-${org_name}-"* ]] || die "Peer channel receipt references a Job outside $org_name: $job_name"
  done
  log_ok "Verified immutable peer channel receipt: $receipt"
}

peer_channel_evidence_job_name() {
  local org_name="$1" jobs
  if peer_channel_receipt_exists; then
    jobs="$(kubectl "${KUBECTL_ARGS[@]}" get configmap "$(peer_channel_receipt_name)" -o jsonpath='{.data.jobs}')"
    printf '%s' "$jobs" | tr ',' '\n' | sed -n 's/^'"$org_name"'=//p'
  else
    local runner_file execution_sha
    runner_file="$(peer_channel_runner_file "$org_name")"
    execution_sha="$(peer_channel_execution_sha "$org_name" "$runner_file")"
    peer_channel_job_name "$org_name" "$execution_sha"
  fi
}

verify_peer_channel_job_evidence() {
  local org_index1="$1" org_name="$2" job_name succeeded image pod_name image_id logs peer_index0 peer_name anchor_name org_msp
  job_name="$(peer_channel_evidence_job_name "$org_name")"
  succeeded="$(kubectl "${KUBECTL_ARGS[@]}" get job "$job_name" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)"
  [[ "$succeeded" == 1 ]] || die "Peer channel Job is not complete: $job_name"
  [[ "$(kubectl "${KUBECTL_ARGS[@]}" get job "$job_name" -o jsonpath='{.spec.template.spec.automountServiceAccountToken}')" == false ]] || die "$job_name mounts a ServiceAccount token"
  image="$(kubectl "${KUBECTL_ARGS[@]}" get job "$job_name" -o jsonpath='{.spec.template.spec.containers[0].image}')"
  [[ "$image" =~ ^[^[:space:]]+@sha256:[a-f0-9]{64}$ ]] || die "$job_name uses an unpinned Fabric tools image: $image"
  pod_name="$(kubectl "${KUBECTL_ARGS[@]}" get pod -l "fabric.network.tools/peer-channel-job=$job_name" -o jsonpath='{.items[0].metadata.name}')"
  image_id="$(kubectl "${KUBECTL_ARGS[@]}" get pod "$pod_name" -o jsonpath='{.status.containerStatuses[0].imageID}')"
  [[ "$image_id" == *@"${image##*@}" ]] || die "$job_name runtime image digest does not match its configured digest: $image_id"
  logs="$(kubectl "${KUBECTL_ARGS[@]}" logs "job/$job_name")"
  for ((peer_index0 = 0; peer_index0 < $(peers_per_organization); peer_index0++)); do
    peer_name="$(peer_kubernetes_name "$org_index1" "$peer_index0" "$org_name")"
    printf '%s\n' "$logs" | rg "^PEER_READY channel=$(channel_name) org=$org_name peer=$peer_name height=[1-9][0-9]*$" >/dev/null || die "$job_name lacks channel/height evidence for $peer_name"
  done
  anchor_name="$(peer_channel_anchor_name "$org_index1" "$org_name")"
  org_msp="$(peer_organization_msp_id "$org_index1" "$org_name")"
  printf '%s\n' "$logs" | rg -F "ANCHOR_READY channel=$(channel_name) org=$org_name msp=$org_msp host=$(service_fqdn "$anchor_name") port=7051" >/dev/null || die "$job_name lacks anchor configuration evidence for $org_name"
  log_ok "Verified peer joins and anchor evidence for $org_name: $job_name"
}

deploy_peer_channel_jobs() {
  local org_index1 org_name runner_file execution_sha job_name failed succeeded
  if peer_channel_receipt_exists; then
    verify_peer_channel_receipt
    log_ok "Peer channel receipt already exists; preserving memberships and anchors for $(channel_name)"
    return 0
  fi
  for ((org_index1 = 1; org_index1 <= $(peer_organization_count); org_index1++)); do
    org_name="$(peer_organization_name "$org_index1")"
    runner_file="$(peer_channel_runner_file "$org_name")"
    execution_sha="$(peer_channel_execution_sha "$org_name" "$runner_file")"
    job_name="$(peer_channel_job_name "$org_name" "$execution_sha")"
    failed="$(kubectl "${KUBECTL_ARGS[@]}" get job "$job_name" -o jsonpath='{.status.failed}' 2>/dev/null || true)"
    succeeded="$(kubectl "${KUBECTL_ARGS[@]}" get job "$job_name" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)"
    if [[ -n "$failed" && "$failed" != 0 && "$succeeded" != 1 ]]; then
      log_warn "Removing failed, digest-matched peer channel Job before retry: $job_name"
      kubectl "${KUBECTL_ARGS[@]}" delete job "$job_name" --wait=true >/dev/null
    fi
    if ! kubectl "${KUBECTL_ARGS[@]}" get job "$job_name" >/dev/null 2>&1; then
      kubectl "${KUBECTL_ARGS[@]}" apply --server-side --field-manager=fabricctl --force-conflicts -f "$(peer_channel_render_file "$org_name")" >/dev/null
      log_ok "Created peer channel Job for $org_name: $job_name"
    else
      log_info "Resuming existing digest-matched peer channel Job: $job_name"
    fi
    kubectl "${KUBECTL_ARGS[@]}" wait --for=condition=complete "job/$job_name" --timeout=10m >/dev/null || {
      kubectl "${KUBECTL_ARGS[@]}" logs "job/$job_name" --tail=200 >&2 || true
      die "Peer channel Job did not complete: $job_name"
    }
    verify_peer_channel_job_evidence "$org_index1" "$org_name"
  done
  kubectl "${KUBECTL_ARGS[@]}" apply --server-side --field-manager=fabricctl -f "$(peer_channel_receipt_render_file)" >/dev/null
  verify_peer_channel_receipt
  log_ok "Every peer joined $(channel_name), all anchors are configured, and the receipt is recorded"
}

verify_all_peer_channel_jobs() {
  local org_index1 org_name
  verify_peer_channel_receipt
  for ((org_index1 = 1; org_index1 <= $(peer_organization_count); org_index1++)); do
    org_name="$(peer_organization_name "$org_index1")"
    verify_peer_channel_job_evidence "$org_index1" "$org_name"
  done
}
