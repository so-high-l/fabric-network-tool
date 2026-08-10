#!/usr/bin/env bash

chaincode_artifact_directory() { printf '%s/chaincodes/%s' "$FABRIC_TOOL_OUTPUT" "$(chaincode_name)"; }
chaincode_plan_file() { printf '%s/plan.yaml' "$(chaincode_artifact_directory)"; }
chaincode_runner_file() { printf '%s/%s-run.sh' "$(chaincode_artifact_directory)" "$1"; }
chaincode_commit_runner_file() { printf '%s/commit-run.sh' "$(chaincode_artifact_directory)"; }
chaincode_org_render_file() { printf '%s/rendered/chaincodes/%s-%s-lifecycle.yaml' "$FABRIC_TOOL_OUTPUT" "$(chaincode_name)" "$1"; }
chaincode_runtime_render_file() { printf '%s/rendered/chaincodes/%s-runtime.yaml' "$FABRIC_TOOL_OUTPUT" "$(chaincode_name)"; }
chaincode_commit_render_file() { printf '%s/rendered/chaincodes/%s-commit.yaml' "$FABRIC_TOOL_OUTPUT" "$(chaincode_name)"; }
chaincode_receipt_render_file() { printf '%s/rendered/chaincodes/%s-receipt.yaml' "$FABRIC_TOOL_OUTPUT" "$(chaincode_name)"; }
chaincode_label() { printf '%s_%s' "$(chaincode_name)" "$(chaincode_version)"; }
chaincode_receipt_name() { printf '%s-receipt' "$(chaincode_operation_name)"; }
chaincode_package_configmap() { printf '%s-package' "$(chaincode_kubernetes_name "$1" "$2")"; }
chaincode_plan_sha() { : "${FABRIC_CHAINCODE_PLAN_SHA:?FABRIC_CHAINCODE_PLAN_SHA is required}"; printf '%s' "$FABRIC_CHAINCODE_PLAN_SHA"; }

chaincode_execution_sha() {
  local role="$1" runner="$2" contract='chaincode-lifecycle-job-v3'
  [[ "$role" != commit ]] || contract='chaincode-commit-job-v7'
  printf '%s\n%s\n%s\n%s\n%s\n' "$(chaincode_plan_sha)" "$role" "$(fabric_tools_image)" "$(sha256_file "$runner")" "$contract" | sha256_stream
}

chaincode_org_job_name() { printf '%s-%s-%s' "$(chaincode_operation_name)" "$1" "${2:0:10}"; }
chaincode_commit_job_name() { printf '%s-commit-%s' "$(chaincode_operation_name)" "${1:0:10}"; }

render_chaincode_plan_to() {
  local destination="$1" org_index1 org_name org_msp cc_name service_name peer_index0 peer_name
  {
    printf 'apiVersion: fabric.network.tools/v1alpha1\nkind: FabricChaincodePlan\nmetadata:\n  name: %s\nspec:\n' "$(chaincode_operation_name)"
    printf '  channel: %s\n  name: %s\n  version: "%s"\n  sequence: %s\n  initRequired: false\n' "$(channel_name)" "$(chaincode_name)" "$(chaincode_version)" "$(chaincode_sequence)"
    printf '  label: %s\n  image: %s\n  organizations:\n' "$(chaincode_label)" "$(chaincode_image)"
    for ((org_index1=1; org_index1<=$(peer_organization_count); org_index1++)); do
      org_name="$(peer_organization_name "$org_index1")"; org_msp="$(peer_organization_msp_id "$org_index1" "$org_name")"; cc_name="$(chaincode_kubernetes_name "$org_index1" "$org_name")"; service_name="$(chaincode_service_name "$org_index1" "$org_name" "$cc_name")"
      printf '    - name: %s\n      mspId: %s\n      deployment: %s\n      service: %s\n      address: %s:7052\n      tlsSecret: %s\n      peers:\n' "$org_name" "$org_msp" "$cc_name" "$service_name" "$(service_fqdn "$service_name")" "$(chaincode_tls_secret_name "$org_index1" "$org_name" "$cc_name")"
      for ((peer_index0=0; peer_index0<$(peers_per_organization); peer_index0++)); do
        peer_name="$(peer_kubernetes_name "$org_index1" "$peer_index0" "$org_name")"
        printf '        - {name: %s, address: %s:7051, tlsSecret: %s-tls}\n' "$peer_name" "$(service_fqdn "$peer_name")" "$peer_name"
      done
    done
  } >"$destination"
  yq e '.' "$destination" >/dev/null || die 'Generated chaincode plan is invalid YAML'
}

render_chaincode_org_runner_to() {
  local destination="$1" org_index1="$2" org_name="$3" org_msp cc_name service_name peer_index0 peer_name
  org_msp="$(peer_organization_msp_id "$org_index1" "$org_name")"; cc_name="$(chaincode_kubernetes_name "$org_index1" "$org_name")"; service_name="$(chaincode_service_name "$org_index1" "$org_name" "$cc_name")"
  {
    printf '#!/bin/sh\nset -eu\numask 077\n'
    printf 'CHANNEL=%s\nCC_NAME=%s\nCC_VERSION=%s\nCC_SEQUENCE=%s\nCC_LABEL=%s\nORG=%s\nMSP_ID=%s\nCC_ADDRESS=%s:7052\n' \
      "$(channel_name)" "$(chaincode_name)" "$(chaincode_version)" "$(chaincode_sequence)" "$(chaincode_label)" "$org_name" "$org_msp" "$(service_fqdn "$service_name")"
    printf 'ORDERER=%s:7050\nORDERER_CA=/tls/orderer/ca.crt\n' "$(service_fqdn "$(orderer_kubernetes_name 0)")"
    cat <<'RUNNER'
export CORE_PEER_LOCALMSPID="$MSP_ID"
export CORE_PEER_MSPCONFIGPATH=/admin/msp
export CORE_PEER_TLS_ENABLED=true
mkdir -p /work/package
cd /work/package
jq -n --arg address "$CC_ADDRESS" --rawfile client_key /cc-tls/client.key --rawfile client_cert /cc-tls/client.crt --rawfile root_cert /cc-tls/ca.crt \
  '{address:$address,dial_timeout:"10s",tls_required:true,client_auth_required:true,client_key:$client_key,client_cert:$client_cert,root_cert:$root_cert}' > connection.json
jq -n --arg package_label "$CC_LABEL" '{path:"",type:"ccaas",label:$package_label}' > metadata.json
tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner --format=gnu -cf - connection.json | gzip -n > code.tar.gz
tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner --format=gnu -cf - code.tar.gz metadata.json | gzip -n > chaincode.tgz
PACKAGE_ID="$(peer lifecycle chaincode calculatepackageid chaincode.tgz)"
case "$PACKAGE_ID" in "$CC_LABEL":????????????????????????????????????????????????????????????????) ;; *) echo "Unexpected package ID" >&2; exit 1;; esac
RUNNER
    for ((peer_index0=0; peer_index0<$(peers_per_organization); peer_index0++)); do
      peer_name="$(peer_kubernetes_name "$org_index1" "$peer_index0" "$org_name")"
      printf 'export CORE_PEER_ADDRESS=%s:7051\nexport CORE_PEER_TLS_ROOTCERT_FILE=/tls/peers/%s/ca.crt\n' "$(service_fqdn "$peer_name")" "$peer_name"
      printf 'peer lifecycle chaincode queryinstalled --output json > /work/%s-installed.json\n' "$peer_name"
      printf 'if jq -e --arg id "$PACKAGE_ID" '\''[.installed_chaincodes[]? | select(.package_id == $id)] | length == 1'\'' /work/%s-installed.json >/dev/null; then\n' "$peer_name"
      printf '  printf '\''PACKAGE_PRESENT org=%%s peer=%s package_id=%%s\n'\'' "$ORG" "$PACKAGE_ID"\n' "$peer_name"
      printf 'else\n  peer lifecycle chaincode install chaincode.tgz\n  peer lifecycle chaincode queryinstalled --output json > /work/%s-installed-after.json\n' "$peer_name"
      printf '  jq -e --arg id "$PACKAGE_ID" '\''[.installed_chaincodes[]? | select(.package_id == $id)] | length == 1'\'' /work/%s-installed-after.json >/dev/null\n' "$peer_name"
      printf '  printf '\''PACKAGE_INSTALLED org=%%s peer=%s package_id=%%s\n'\'' "$ORG" "$PACKAGE_ID"\nfi\n' "$peer_name"
    done
    cat <<'RUNNER'
export CORE_PEER_ADDRESS="FIRST_PEER_ENDPOINT"
export CORE_PEER_TLS_ROOTCERT_FILE="FIRST_PEER_CA"
approved=false
if peer lifecycle chaincode queryapproved --channelID "$CHANNEL" --name "$CC_NAME" --sequence "$CC_SEQUENCE" --output json > /work/approved.json 2>/work/approved.err; then
  if ! jq -e --arg version "$CC_VERSION" --argjson sequence "$CC_SEQUENCE" '.version == $version and .sequence == $sequence' /work/approved.json >/dev/null; then cat /work/approved.json >&2; echo 'Existing approval differs from desired public definition' >&2; exit 1; fi
  if grep -F "$PACKAGE_ID" /work/approved.json >/dev/null; then approved=true; else printf 'PACKAGE_ASSOCIATION_UPDATE org=%s sequence=%s package_id=%s\n' "$ORG" "$CC_SEQUENCE" "$PACKAGE_ID"; fi
fi
if [ "$approved" != true ]; then
  peer lifecycle chaincode approveformyorg -o "$ORDERER" --tls --cafile "$ORDERER_CA" --channelID "$CHANNEL" --name "$CC_NAME" --version "$CC_VERSION" --package-id "$PACKAGE_ID" --sequence "$CC_SEQUENCE"
fi
peer lifecycle chaincode queryapproved --channelID "$CHANNEL" --name "$CC_NAME" --sequence "$CC_SEQUENCE" --output json > /work/approved-final.json
jq -e --arg version "$CC_VERSION" --argjson sequence "$CC_SEQUENCE" '.version == $version and .sequence == $sequence' /work/approved-final.json >/dev/null
grep -F "$PACKAGE_ID" /work/approved-final.json >/dev/null
printf 'APPROVAL_READY org=%s msp=%s sequence=%s package_id=%s\n' "$ORG" "$MSP_ID" "$CC_SEQUENCE" "$PACKAGE_ID"
printf 'PACKAGE_READY org=%s package_id=%s\n' "$ORG" "$PACKAGE_ID"
RUNNER
  } >"$destination"
  peer_name="$(peer_kubernetes_name "$org_index1" 0 "$org_name")"
  sed -i.bak "s|FIRST_PEER_ENDPOINT|$(service_fqdn "$peer_name"):7051|; s|FIRST_PEER_CA|/tls/peers/$peer_name/ca.crt|" "$destination" && rm -f "$destination.bak"
  chmod 0755 "$destination"; sh -n "$destination" || die "Generated lifecycle runner is invalid: $org_name"
}

render_chaincode_org_manifest_to() {
  local destination="$1" org_index1="$2" org_name="$3" runner="$4" execution_sha="$5" job_name org_msp cc_name orderer_name peer_index0 peer_name pull_secret
  job_name="$(chaincode_org_job_name "$org_name" "$execution_sha")"; org_msp="$(peer_organization_msp_id "$org_index1" "$org_name")"; cc_name="$(chaincode_kubernetes_name "$org_index1" "$org_name")"; orderer_name="$(orderer_kubernetes_name 0)"; pull_secret="$(image_pull_secret)"
  {
    printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: %s\n  namespace: %s\n  labels: {app.kubernetes.io/managed-by: fabricctl, fabric.network.tools/chaincode: %s, fabric.network.tools/organization: %s}\ndata:\n  run.sh: |-\n' "$job_name" "$(cluster_namespace)" "$(chaincode_name)" "$org_name"
    sed 's/^/    /' "$runner"; render_msp_config_data config.yaml
    printf '%s\n' '---'; printf 'apiVersion: batch/v1\nkind: Job\nmetadata:\n  name: %s\n  namespace: %s\n  labels: {app.kubernetes.io/managed-by: fabricctl, fabric.network.tools/chaincode-job: %s, fabric.network.tools/organization: %s}\nspec:\n  backoffLimit: 1\n  activeDeadlineSeconds: 900\n  template:\n    metadata:\n      labels: {fabric.network.tools/chaincode-job: %s}\n    spec:\n      restartPolicy: Never\n      serviceAccountName: %s\n      automountServiceAccountToken: false\n      securityContext: {runAsNonRoot: true, runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000, seccompProfile: {type: RuntimeDefault}}\n' "$job_name" "$(cluster_namespace)" "$job_name" "$org_name" "$job_name" "$(cluster_service_account)"
    [[ -z "$pull_secret" ]] || printf '      imagePullSecrets: [{name: %s}]\n' "$pull_secret"
    printf '      containers:\n        - name: lifecycle\n          image: %s\n          imagePullPolicy: IfNotPresent\n          command: [/bin/sh, /operation/run.sh]\n          env: [{name: FABRIC_CFG_PATH, value: /operation}, {name: HOME, value: /work}, {name: FABRIC_LOGGING_SPEC, value: info}]\n          securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}\n          resources: {requests: {cpu: 50m, memory: 64Mi}, limits: {cpu: 250m, memory: 256Mi}}\n          volumeMounts: [{name: operation, mountPath: /operation, readOnly: true}, {name: admin-msp, mountPath: /admin/msp, readOnly: true}, {name: tls, mountPath: /tls, readOnly: true}, {name: cc-tls, mountPath: /cc-tls, readOnly: true}, {name: work, mountPath: /work}]\n      volumes:\n' "$(fabric_tools_image)"
    printf '        - name: operation\n          projected:\n            defaultMode: 0550\n            sources:\n              - configMap: {name: %s, items: [{key: run.sh, path: run.sh}]}\n              - configMap: {name: %s-builders-config, items: [{key: core.yaml, path: core.yaml}]}\n' "$job_name" "$(peer_kubernetes_name "$org_index1" 0 "$org_name")"
    printf '        - name: admin-msp\n          projected:\n            defaultMode: 0440\n            sources:\n              - configMap: {name: %s, items: [{key: config.yaml, path: config.yaml}]}\n              - secret:\n                  name: %s-admin-msp\n                  items: [{key: admincerts, path: admincerts/admin.crt}, {key: cacerts, path: cacerts/ca.crt}, {key: keystore, path: keystore/key.pem}, {key: signcerts, path: signcerts/cert.pem}, {key: tlscacerts, path: tlscacerts/tlsca.crt}]\n' "$job_name" "$org_name"
    printf '        - name: tls\n          projected:\n            defaultMode: 0440\n            sources:\n              - secret: {name: %s-tls, items: [{key: cacrt, path: orderer/ca.crt}]}\n' "$orderer_name"
    for ((peer_index0=0; peer_index0<$(peers_per_organization); peer_index0++)); do peer_name="$(peer_kubernetes_name "$org_index1" "$peer_index0" "$org_name")"; printf '              - secret: {name: %s-tls, items: [{key: cacrt, path: peers/%s/ca.crt}]}\n' "$peer_name" "$peer_name"; done
    printf '        - {name: cc-tls, secret: {secretName: %s, items: [{key: ca.crt, path: ca.crt}, {key: client.crt, path: client.crt}, {key: client.key, path: client.key}]}}\n        - {name: work, emptyDir: {}}\n' "$(chaincode_tls_secret_name "$org_index1" "$org_name" "$cc_name")"
  } >"$destination"
  yq e '.' "$destination" >/dev/null || die "Generated lifecycle manifest is invalid: $org_name"
}

render_chaincode_runtime_to() {
  local destination="$1" org_index1 org_name cc_name service_name org_msp pull_secret
  pull_secret="$(image_pull_secret)"; : >"$destination"
  for ((org_index1=1; org_index1<=$(peer_organization_count); org_index1++)); do
    org_name="$(peer_organization_name "$org_index1")"; org_msp="$(peer_organization_msp_id "$org_index1" "$org_name")"; cc_name="$(chaincode_kubernetes_name "$org_index1" "$org_name")"; service_name="$(chaincode_service_name "$org_index1" "$org_name" "$cc_name")"
    [[ ! -s "$destination" ]] || printf '%s\n' '---' >>"$destination"
    cat >>"$destination" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $cc_name
  namespace: $(cluster_namespace)
  labels: {app.kubernetes.io/name: $cc_name, app.kubernetes.io/managed-by: fabricctl, app.kubernetes.io/component: ccaas, fabric.network.tools/organization: $org_name}
spec:
  replicas: 1
  strategy: {type: RollingUpdate, rollingUpdate: {maxSurge: 0, maxUnavailable: 1}}
  selector:
    matchLabels: {app.kubernetes.io/name: $cc_name, app.kubernetes.io/component: ccaas}
  template:
    metadata:
      labels: {app.kubernetes.io/name: $cc_name, app.kubernetes.io/component: ccaas, fabric.network.tools/organization: $org_name}
      annotations: {fabric.network.tools/plan-sha256: "$(chaincode_plan_sha)"}
    spec:
      serviceAccountName: $(cluster_service_account)
      automountServiceAccountToken: false
      securityContext: {runAsNonRoot: true, runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000, seccompProfile: {type: RuntimeDefault}}
EOF
    [[ -z "$pull_secret" ]] || printf '      imagePullSecrets: [{name: %s}]\n' "$pull_secret" >>"$destination"
    cat >>"$destination" <<EOF
      containers:
        - name: chaincode
          image: $(chaincode_image)
          imagePullPolicy: IfNotPresent
          securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
          env:
            - name: CHAINCODE_ID
              valueFrom: {configMapKeyRef: {name: ${cc_name}-package, key: packageId}}
            - {name: CHAINCODE_SERVER_ADDRESS, value: "0.0.0.0:9999"}
            - {name: CHAINCODE_TLS_DISABLED, value: "false"}
            - {name: CHAINCODE_TLS_KEY, value: /crypto/client.key}
            - {name: CHAINCODE_TLS_CERT, value: /crypto/client.crt}
            - {name: CHAINCODE_CLIENT_CA_CERT, value: /crypto/ca.crt}
          ports: [{name: grpc, containerPort: 9999}]
          startupProbe: {tcpSocket: {port: grpc}, failureThreshold: 30, periodSeconds: 2}
          readinessProbe: {tcpSocket: {port: grpc}, periodSeconds: 5, failureThreshold: 3}
          livenessProbe: {tcpSocket: {port: grpc}, periodSeconds: 10, failureThreshold: 3}
          resources: {requests: {cpu: 50m, memory: 64Mi}, limits: {cpu: 250m, memory: 256Mi}}
          volumeMounts: [{name: certificates, mountPath: /crypto, readOnly: true}]
      volumes:
        - {name: certificates, secret: {secretName: $(chaincode_tls_secret_name "$org_index1" "$org_name" "$cc_name"), items: [{key: ca.crt, path: ca.crt}, {key: client.crt, path: client.crt}, {key: client.key, path: client.key}]}}
---
apiVersion: v1
kind: Service
metadata:
  name: $service_name
  namespace: $(cluster_namespace)
  labels: {app.kubernetes.io/name: $service_name, app.kubernetes.io/managed-by: fabricctl, app.kubernetes.io/component: ccaas}
spec:
  type: ClusterIP
  selector: {app.kubernetes.io/name: $cc_name, app.kubernetes.io/component: ccaas}
  ports: [{name: grpc, port: 7052, targetPort: grpc}]
EOF
  done
  yq e '.' "$destination" >/dev/null || die 'Generated chaincode runtime manifest is invalid'
}

render_chaincode_commit_runner_to() {
  local destination="$1" org_index1 org_name org_msp peer_name
  {
    printf '#!/bin/sh\nset -eu\numask 077\nCHANNEL=%s\nCC_NAME=%s\nCC_VERSION=%s\nCC_SEQUENCE=%s\nORDERER=%s:7050\nORDERER_CA=/tls/orderer/ca.crt\n' "$(channel_name)" "$(chaincode_name)" "$(chaincode_version)" "$(chaincode_sequence)" "$(service_fqdn "$(orderer_kubernetes_name 0)")"
    org_name="$(peer_organization_name 1)"; org_msp="$(peer_organization_msp_id 1 "$org_name")"; peer_name="$(peer_kubernetes_name 1 0 "$org_name")"
    printf 'export CORE_PEER_LOCALMSPID=%s\nexport CORE_PEER_MSPCONFIGPATH=/admin/msp\nexport CORE_PEER_TLS_ENABLED=true\nexport CORE_PEER_ADDRESS=%s:7051\nexport CORE_PEER_TLS_ROOTCERT_FILE=/tls/peers/%s/ca.crt\n' "$org_msp" "$(service_fqdn "$peer_name")" "$peer_name"
    printf 'PEER_ARGS=""\n'
    for ((org_index1=1; org_index1<=$(peer_organization_count); org_index1++)); do
      org_name="$(peer_organization_name "$org_index1")"; org_msp="$(peer_organization_msp_id "$org_index1" "$org_name")"; peer_name="$(peer_kubernetes_name "$org_index1" 0 "$org_name")"
      printf 'PEER_ARGS="$PEER_ARGS --peerAddresses %s:7051 --tlsRootCertFiles /tls/peers/%s/ca.crt"\n' "$(service_fqdn "$peer_name")" "$peer_name"
    done
    cat <<'RUNNER'
committed=false
if peer lifecycle chaincode querycommitted --channelID "$CHANNEL" --name "$CC_NAME" --output json > /work/committed.json 2>/work/committed.err; then
  if jq -e --arg version "$CC_VERSION" --argjson sequence "$CC_SEQUENCE" '.version == $version and .sequence == $sequence' /work/committed.json >/dev/null; then committed=true; printf 'CHAINCODE_DEFINITION_PRESENT channel=%s name=%s sequence=%s\n' "$CHANNEL" "$CC_NAME" "$CC_SEQUENCE"; else cat /work/committed.json >&2; echo 'Committed definition differs from desired sequence' >&2; exit 1; fi
fi
if [ "$committed" != true ]; then
  if ! peer lifecycle chaincode checkcommitreadiness --channelID "$CHANNEL" --name "$CC_NAME" --version "$CC_VERSION" --sequence "$CC_SEQUENCE" --output json > /work/readiness.json 2>/work/readiness.err; then
    cat /work/readiness.err >&2
    exit 1
  fi
  printf 'COMMIT_READINESS '
  jq -c '{approvals:.approvals}' /work/readiness.json
RUNNER
    for ((org_index1=1; org_index1<=$(peer_organization_count); org_index1++)); do org_name="$(peer_organization_name "$org_index1")"; org_msp="$(peer_organization_msp_id "$org_index1" "$org_name")"; printf 'jq -e '\''.approvals["%s"] == true'\'' /work/readiness.json >/dev/null\n' "$org_msp"; done
    cat <<'RUNNER'
  # PEER_ARGS is generated exclusively from validated DNS names and paths.
  # shellcheck disable=SC2086
  peer lifecycle chaincode commit -o "$ORDERER" --tls --cafile "$ORDERER_CA" --channelID "$CHANNEL" --name "$CC_NAME" --version "$CC_VERSION" --sequence "$CC_SEQUENCE" $PEER_ARGS
fi
peer lifecycle chaincode querycommitted --channelID "$CHANNEL" --name "$CC_NAME" --output json > /work/committed-final.json
jq -e --arg version "$CC_VERSION" --argjson sequence "$CC_SEQUENCE" '.version == $version and .sequence == $sequence' /work/committed-final.json >/dev/null
ready=false
attempt=0
while [ "$attempt" -lt 60 ]; do
  if ! peer chaincode query -C "$CHANNEL" -n "$CC_NAME" -c '{"Args":["__fabricctl_healthcheck__"]}' >/work/health.out 2>&1 && grep -F 'Invalid function name: __fabricctl_healthcheck__' /work/health.out >/dev/null; then ready=true; break; fi
  attempt=$((attempt + 1)); sleep 2
done
[ "$ready" = true ] || { cat /work/health.out >&2; echo 'Chaincode server did not execute the health probe' >&2; exit 1; }
printf 'CHAINCODE_COMMITTED channel=%s name=%s version=%s sequence=%s\n' "$CHANNEL" "$CC_NAME" "$CC_VERSION" "$CC_SEQUENCE"
printf 'CHAINCODE_EXECUTION_READY channel=%s name=%s\n' "$CHANNEL" "$CC_NAME"
RUNNER
  } >"$destination"
  chmod 0755 "$destination"; sh -n "$destination" || die 'Generated chaincode commit runner is invalid'
}

render_chaincode_commit_manifest_to() {
  local destination="$1" runner="$2" execution_sha="$3" job_name org1 org_index1 org_name peer_name pull_secret
  job_name="$(chaincode_commit_job_name "$execution_sha")"; org1="$(peer_organization_name 1)"; pull_secret="$(image_pull_secret)"
  {
    printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: %s\n  namespace: %s\n  labels: {app.kubernetes.io/managed-by: fabricctl, fabric.network.tools/chaincode: %s}\ndata:\n  run.sh: |-\n' "$job_name" "$(cluster_namespace)" "$(chaincode_name)"; sed 's/^/    /' "$runner"; render_msp_config_data config.yaml
    printf '%s\n' '---'; printf 'apiVersion: batch/v1\nkind: Job\nmetadata:\n  name: %s\n  namespace: %s\n  labels: {app.kubernetes.io/managed-by: fabricctl, fabric.network.tools/chaincode-commit-job: %s}\nspec:\n  backoffLimit: 1\n  activeDeadlineSeconds: 900\n  template:\n    metadata:\n      labels: {fabric.network.tools/chaincode-commit-job: %s}\n    spec:\n      restartPolicy: Never\n      serviceAccountName: %s\n      automountServiceAccountToken: false\n      securityContext: {runAsNonRoot: true, runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000, seccompProfile: {type: RuntimeDefault}}\n' "$job_name" "$(cluster_namespace)" "$job_name" "$job_name" "$(cluster_service_account)"
    [[ -z "$pull_secret" ]] || printf '      imagePullSecrets: [{name: %s}]\n' "$pull_secret"
    printf '      containers:\n        - name: commit\n          image: %s\n          imagePullPolicy: IfNotPresent\n          command: [/bin/sh, /operation/run.sh]\n          env: [{name: FABRIC_CFG_PATH, value: /operation}, {name: HOME, value: /work}, {name: FABRIC_LOGGING_SPEC, value: info}]\n          securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}\n          resources: {requests: {cpu: 25m, memory: 32Mi}, limits: {cpu: 250m, memory: 256Mi}}\n          volumeMounts: [{name: operation, mountPath: /operation, readOnly: true}, {name: admin-msp, mountPath: /admin/msp, readOnly: true}, {name: tls, mountPath: /tls, readOnly: true}, {name: work, mountPath: /work}]\n      volumes:\n' "$(fabric_tools_image)"
    printf '        - name: operation\n          projected:\n            defaultMode: 0550\n            sources:\n              - configMap: {name: %s, items: [{key: run.sh, path: run.sh}]}\n              - configMap: {name: %s-builders-config, items: [{key: core.yaml, path: core.yaml}]}\n' "$job_name" "$(peer_kubernetes_name 1 0 "$org1")"
    printf '        - name: admin-msp\n          projected:\n            defaultMode: 0440\n            sources:\n              - configMap: {name: %s, items: [{key: config.yaml, path: config.yaml}]}\n              - secret: {name: %s-admin-msp, items: [{key: admincerts, path: admincerts/admin.crt}, {key: cacerts, path: cacerts/ca.crt}, {key: keystore, path: keystore/key.pem}, {key: signcerts, path: signcerts/cert.pem}, {key: tlscacerts, path: tlscacerts/tlsca.crt}]}\n' "$job_name" "$org1"
    printf '        - name: tls\n          projected:\n            defaultMode: 0440\n            sources:\n              - secret: {name: %s-tls, items: [{key: cacrt, path: orderer/ca.crt}]}\n' "$(orderer_kubernetes_name 0)"
    for ((org_index1=1; org_index1<=$(peer_organization_count); org_index1++)); do org_name="$(peer_organization_name "$org_index1")"; peer_name="$(peer_kubernetes_name "$org_index1" 0 "$org_name")"; printf '              - secret: {name: %s-tls, items: [{key: cacrt, path: peers/%s/ca.crt}]}\n' "$peer_name" "$peer_name"; done
    printf '        - {name: work, emptyDir: {}}\n'
  } >"$destination"
  yq e '.' "$destination" >/dev/null || die 'Generated chaincode commit manifest is invalid'
}

render_chaincode_receipt_to() {
  local destination="$1" org_index1 org_name runner sha jobs='' commit_sha
  for ((org_index1=1; org_index1<=$(peer_organization_count); org_index1++)); do org_name="$(peer_organization_name "$org_index1")"; runner="$(chaincode_runner_file "$org_name")"; sha="$(chaincode_execution_sha "$org_name" "$runner")"; [[ -z "$jobs" ]] || jobs+=','; jobs+="$org_name=$(chaincode_org_job_name "$org_name" "$sha")"; done
  commit_sha="$(chaincode_execution_sha commit "$(chaincode_commit_runner_file)")"
  cat >"$destination" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: $(chaincode_receipt_name)
  namespace: $(cluster_namespace)
  labels: {app.kubernetes.io/managed-by: fabricctl, fabric.network.tools/chaincode: $(chaincode_name)}
data:
  channel: $(channel_name)
  name: $(chaincode_name)
  version: "$(chaincode_version)"
  sequence: "$(chaincode_sequence)"
  planSha256: "$(chaincode_plan_sha)"
  image: $(chaincode_image)
  lifecycleJobs: $jobs
  commitJob: $(chaincode_commit_job_name "$commit_sha")
EOF
}

render_and_validate_chaincode_artifacts() {
  local temp org_index1 org_name runner sha
  temp="$(mktemp)"; render_chaincode_plan_to "$temp"
  FABRIC_CHAINCODE_PLAN_SHA="$(sha256_file "$temp")"; export FABRIC_CHAINCODE_PLAN_SHA
  write_if_changed "$temp" "$(chaincode_plan_file)"
  for ((org_index1=1; org_index1<=$(peer_organization_count); org_index1++)); do org_name="$(peer_organization_name "$org_index1")"; temp="$(mktemp)"; render_chaincode_org_runner_to "$temp" "$org_index1" "$org_name"; runner="$(chaincode_runner_file "$org_name")"; write_if_changed "$temp" "$runner"; sha="$(chaincode_execution_sha "$org_name" "$runner")"; temp="$(mktemp)"; render_chaincode_org_manifest_to "$temp" "$org_index1" "$org_name" "$runner" "$sha"; write_if_changed "$temp" "$(chaincode_org_render_file "$org_name")"; done
  temp="$(mktemp)"; render_chaincode_runtime_to "$temp"; write_if_changed "$temp" "$(chaincode_runtime_render_file)"
  temp="$(mktemp)"; render_chaincode_commit_runner_to "$temp"; write_if_changed "$temp" "$(chaincode_commit_runner_file)"; sha="$(chaincode_execution_sha commit "$(chaincode_commit_runner_file)")"; temp="$(mktemp)"; render_chaincode_commit_manifest_to "$temp" "$(chaincode_commit_runner_file)" "$sha"; write_if_changed "$temp" "$(chaincode_commit_render_file)"
  temp="$(mktemp)"; render_chaincode_receipt_to "$temp"; write_if_changed "$temp" "$(chaincode_receipt_render_file)"
  local rendered forbidden unsafe
  for rendered in "$(chaincode_org_render_file "$(peer_organization_name 1)")" "$(chaincode_runtime_render_file)" "$(chaincode_commit_render_file)" "$(chaincode_receipt_render_file)"; do
    forbidden="$(yq e 'select(.kind == "Namespace" or .kind == "Secret" or .kind == "ClusterRole" or .kind == "ClusterRoleBinding" or .kind == "Role" or .kind == "RoleBinding") | .kind' "$rendered")"; [[ -z "$forbidden" ]] || die "Chaincode render contains forbidden resource: $forbidden"
    unsafe="$(yq e '.. | select(tag == "!!map" and has("image")) | .image | select(contains("@sha256:") | not)' "$rendered")"; [[ -z "$unsafe" ]] || die "Chaincode render contains unpinned image: $unsafe"
    rg -q 'hostPath:|pods/exec|:latest|REPLACE_WITH' "$rendered" && die "Chaincode render contains an unsafe contract: $rendered"
  done
  log_ok "Rendered deterministic CCaaS lifecycle plan: $(chaincode_name) ($(chaincode_plan_sha))"
}

prepare_chaincode_plan_sha() {
  local temp="$FABRIC_TOOL_TEMP/chaincode-plan.yaml"
  render_chaincode_plan_to "$temp"
  FABRIC_CHAINCODE_PLAN_SHA="$(sha256_file "$temp")"
  export FABRIC_CHAINCODE_PLAN_SHA
}

publish_chaincode_package_id() {
  local org_index1="$1" org_name="$2" job_name="$3" package_id cm temp
  package_id="$(kubectl "${KUBECTL_ARGS[@]}" logs "job/$job_name" | sed -n 's/^PACKAGE_READY org='"$org_name"' package_id=//p' | tail -n 1)"
  [[ "$package_id" =~ ^$(chaincode_label):[a-f0-9]{64}$ ]] || die "Could not obtain a valid package ID from $job_name"
  cm="$(chaincode_package_configmap "$org_index1" "$org_name")"; temp="$FABRIC_TOOL_TEMP/$cm.yaml"
  cat >"$temp" <<EOF
apiVersion: v1
kind: ConfigMap
metadata: {name: $cm, namespace: $(cluster_namespace), labels: {app.kubernetes.io/managed-by: fabricctl, fabric.network.tools/chaincode: $(chaincode_name)}}
data: {packageId: "$package_id", planSha256: "$(chaincode_plan_sha)"}
EOF
  kubectl "${KUBECTL_ARGS[@]}" apply --server-side --field-manager=fabricctl --force-conflicts -f "$temp" >/dev/null
}

run_chaincode_job() {
  local manifest="$1" job_name="$2" container="$3" failed succeeded condition attempt=0
  failed="$(kubectl "${KUBECTL_ARGS[@]}" get job "$job_name" -o jsonpath='{.status.failed}' 2>/dev/null || true)"; succeeded="$(kubectl "${KUBECTL_ARGS[@]}" get job "$job_name" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)"
  if [[ -n "$failed" && "$failed" != 0 && "$succeeded" != 1 ]]; then kubectl "${KUBECTL_ARGS[@]}" delete job "$job_name" --wait=true >/dev/null; fi
  if ! kubectl "${KUBECTL_ARGS[@]}" get job "$job_name" >/dev/null 2>&1; then kubectl "${KUBECTL_ARGS[@]}" apply --server-side --field-manager=fabricctl --force-conflicts -f "$manifest" >/dev/null; fi
  while ((attempt < 450)); do
    succeeded="$(kubectl "${KUBECTL_ARGS[@]}" get job "$job_name" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)"
    [[ "$succeeded" == 1 ]] && return 0
    condition="$(kubectl "${KUBECTL_ARGS[@]}" get job "$job_name" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)"
    if [[ "$condition" == True ]]; then kubectl "${KUBECTL_ARGS[@]}" logs "job/$job_name" -c "$container" --tail=200 >&2 || true; die "Chaincode Job failed: $job_name"; fi
    attempt=$((attempt + 1)); sleep 2
  done
  kubectl "${KUBECTL_ARGS[@]}" logs "job/$job_name" -c "$container" --tail=200 >&2 || true
  die "Timed out waiting for chaincode Job: $job_name"
}

deploy_chaincode() {
  local org_index1 org_name runner sha job_name commit_sha commit_job
  for ((org_index1=1; org_index1<=$(peer_organization_count); org_index1++)); do org_name="$(peer_organization_name "$org_index1")"; runner="$(chaincode_runner_file "$org_name")"; sha="$(chaincode_execution_sha "$org_name" "$runner")"; job_name="$(chaincode_org_job_name "$org_name" "$sha")"; run_chaincode_job "$(chaincode_org_render_file "$org_name")" "$job_name" lifecycle; publish_chaincode_package_id "$org_index1" "$org_name" "$job_name"; log_ok "Installed and approved $(chaincode_name) for $org_name"; done
  kubectl "${KUBECTL_ARGS[@]}" apply --server-side --field-manager=fabricctl --force-conflicts -f "$(chaincode_runtime_render_file)" >/dev/null
  for ((org_index1=1; org_index1<=$(peer_organization_count); org_index1++)); do org_name="$(peer_organization_name "$org_index1")"; kubectl "${KUBECTL_ARGS[@]}" rollout status "deployment/$(chaincode_kubernetes_name "$org_index1" "$org_name")" --timeout=10m >/dev/null || die "CCaaS Deployment did not become ready: $org_name"; done
  commit_sha="$(chaincode_execution_sha commit "$(chaincode_commit_runner_file)")"; commit_job="$(chaincode_commit_job_name "$commit_sha")"; run_chaincode_job "$(chaincode_commit_render_file)" "$commit_job" commit
  kubectl "${KUBECTL_ARGS[@]}" apply --server-side --field-manager=fabricctl --force-conflicts -f "$(chaincode_receipt_render_file)" >/dev/null
}

verify_chaincode_deployment() {
  local actual org_index1 org_name cc_name jobs job_name logs commit_job
  actual="$(kubectl "${KUBECTL_ARGS[@]}" get configmap "$(chaincode_receipt_name)" -o jsonpath='{.data.planSha256}' 2>/dev/null || true)"; [[ "$actual" == "$(chaincode_plan_sha)" ]] || die "Missing or mismatched chaincode receipt"
  jobs="$(kubectl "${KUBECTL_ARGS[@]}" get configmap "$(chaincode_receipt_name)" -o jsonpath='{.data.lifecycleJobs}')"
  for ((org_index1=1; org_index1<=$(peer_organization_count); org_index1++)); do org_name="$(peer_organization_name "$org_index1")"; cc_name="$(chaincode_kubernetes_name "$org_index1" "$org_name")"; [[ "$(kubectl "${KUBECTL_ARGS[@]}" get deployment "$cc_name" -o jsonpath='{.status.readyReplicas}')" == 1 ]] || die "$cc_name is not ready"; [[ "$(kubectl "${KUBECTL_ARGS[@]}" get deployment "$cc_name" -o jsonpath='{.spec.template.spec.containers[0].image}')" == "$(chaincode_image)" ]] || die "$cc_name image differs"; job_name="$(printf '%s' "$jobs" | tr ',' '\n' | sed -n 's/^'"$org_name"'=//p')"; logs="$(kubectl "${KUBECTL_ARGS[@]}" logs "job/$job_name")"; printf '%s\n' "$logs" | rg -F "APPROVAL_READY org=$org_name" >/dev/null || die "$job_name lacks approval evidence"; done
  commit_job="$(kubectl "${KUBECTL_ARGS[@]}" get configmap "$(chaincode_receipt_name)" -o jsonpath='{.data.commitJob}')"; logs="$(kubectl "${KUBECTL_ARGS[@]}" logs "job/$commit_job")"; printf '%s\n' "$logs" | rg -F "CHAINCODE_EXECUTION_READY channel=$(channel_name) name=$(chaincode_name)" >/dev/null || die "$commit_job lacks execution evidence"
  log_ok "CCaaS $(chaincode_name) is installed, approved, committed, and executing on $(channel_name)"
}
