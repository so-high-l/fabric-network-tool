#!/usr/bin/env bash
set -euo pipefail

TOOL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXAMPLE="$TOOL_ROOT/examples/carbon-kind.yaml"
PRODUCTION_EXAMPLE="$TOOL_ROOT/examples/network.example.yaml"
MINIMAL_EXAMPLE="$TOOL_ROOT/examples/minimal-kind.yaml"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fabricctl-tests.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

digest_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

for script in \
  "$TOOL_ROOT/fabricctl.sh" \
  "$TOOL_ROOT"/lib/*.sh \
  "$TOOL_ROOT"/runtime/*.sh \
  "$TOOL_ROOT"/tests/fixtures/reset-bin/* \
  "$TOOL_ROOT"/steps/*.sh
do
  bash -n "$script"
done

for chart in fabric-ca-server fabric-orderernode fabric-peernode; do
  [[ -f "$TOOL_ROOT/charts/$chart/Chart.yaml" ]]
done
if rg -q 'FABRIC_TOOL_ROOT/\.\./bevel/' "$TOOL_ROOT/lib"; then
  echo 'The published tool must not depend on a sibling Bevel checkout' >&2
  exit 1
fi

if rg -q -- '--from-literal=.*password|password=.*openssl rand' "$TOOL_ROOT/lib/peers.sh"; then
  echo 'CouchDB generation must not expose passwords in process arguments' >&2
  exit 1
fi

rg -F 'enroll_hosts="$5"' "$TOOL_ROOT/runtime/enroll-identities.sh" >/dev/null
rg -F -- '--csr.hosts "$enroll_hosts"' "$TOOL_ROOT/runtime/enroll-identities.sh" >/dev/null
if rg -q '^[[:space:]]+hosts="\$5"' "$TOOL_ROOT/runtime/enroll-identities.sh"; then
  echo 'Enrollment helper must not overwrite the caller loop SAN variable' >&2
  exit 1
fi

"$TOOL_ROOT/fabricctl.sh" validate --file "$EXAMPLE" >/dev/null
"$TOOL_ROOT/fabricctl.sh" validate --file "$MINIMAL_EXAMPLE" >/dev/null
"$TOOL_ROOT/fabricctl.sh" validate --file "$PRODUCTION_EXAMPLE" >/dev/null

platform_manifest="$TEMP_DIR/local-kind-platform.yaml"
"$TOOL_ROOT/local-kind/render-platform.sh" --file "$EXAMPLE" >"$platform_manifest" 2>/dev/null
[[ "$(yq ea '[select(.kind == "PersistentVolume")] | length' "$platform_manifest")" == 16 ]]
[[ "$(yq ea '[select(.kind == "PersistentVolumeClaim")] | length' "$platform_manifest")" == 16 ]]
[[ "$(yq ea '[select(.kind == "ServiceAccount") | .automountServiceAccountToken] | unique | .[]' "$platform_manifest")" == false ]]
[[ -z "$(yq ea 'select(.kind == "Secret" or .kind == "ClusterRole" or .kind == "ClusterRoleBinding") | .kind' "$platform_manifest")" ]]
[[ "$(yq ea '[select(.kind == "Role") | .rules[] | select(.apiGroups[] == "discovery.k8s.io") | .resources[] | select(. == "endpointslices")] | length' "$platform_manifest")" == 1 ]]
[[ "$(yq ea '[select(.kind == "Role") | .rules[] | select(.apiGroups[] == "") | .resources[] | select(. == "endpoints")] | length' "$platform_manifest")" == 0 ]]
minimal_platform_manifest="$TEMP_DIR/minimal-kind-platform.yaml"
"$TOOL_ROOT/local-kind/render-platform.sh" --file "$MINIMAL_EXAMPLE" >"$minimal_platform_manifest" 2>/dev/null
[[ "$(yq ea '[select(.kind == "PersistentVolume")] | length' "$minimal_platform_manifest")" == 7 ]]
[[ "$(yq ea '[select(.kind == "PersistentVolumeClaim")] | length' "$minimal_platform_manifest")" == 7 ]]
[[ "$(yq ea -N -r 'select(.kind == "PersistentVolume") | .spec.hostPath.path' "$minimal_platform_manifest" | rg -c '^/var/local/fabric-network-tool/')" == 7 ]]
rg -F "yq ea -N -r 'select(.kind == \"PersistentVolume\")" "$TOOL_ROOT/local-kind/setup.sh" >/dev/null
rg -F 'TARGET_REFERENCE="${CONFIGURED_REPOSITORY}@${EXPECTED_DIGEST}"' "$TOOL_ROOT/local-kind/load-image.sh" >/dev/null
if rg -Fq 'TARGET_REFERENCE="${CONFIGURED_REFERENCE}@${EXPECTED_DIGEST}"' "$TOOL_ROOT/local-kind/load-image.sh"; then
  echo 'Local kind image loader must use the repository@digest alias expected by kubelet' >&2
  exit 1
fi
if "$TOOL_ROOT/local-kind/render-platform.sh" --file "$PRODUCTION_EXAMPLE" >/dev/null 2>&1; then
  echo 'Expected local kind platform rendering to reject production input' >&2
  exit 1
fi

pods_fixture='{"items":[{"metadata":{"name":"clean"},"status":{"containerStatuses":[{"restartCount":0}]}},{"metadata":{"name":"restarted"},"status":{"containerStatuses":[{"restartCount":1}]}}]}'
restart_result="$(printf '%s' "$pods_fixture" | yq -p=json -r '.items[] | select(([.status.initContainerStatuses[]?.restartCount, .status.containerStatuses[]?.restartCount] | map(select(. != null and . > 0)) | length) > 0) | .metadata.name')"
[[ "$restart_result" == restarted ]]

help_output="$("$TOOL_ROOT/fabricctl.sh" --help)"
grep -q 'reset       Remove this network' <<<"$help_output"
grep -q -- '--purge-data' <<<"$help_output"

reset_error="$TEMP_DIR/reset-without-confirmation.err"
if "$TOOL_ROOT/fabricctl.sh" reset --file "$EXAMPLE" > /dev/null 2>"$reset_error"; then
  echo 'Expected reset without exact target confirmations to fail' >&2
  exit 1
fi
grep -q 'reset requires --confirm carbon-kind' "$reset_error"

production_name="$(yq e -r '.metadata.name' "$PRODUCTION_EXAMPLE")"
production_context="$(yq e -r '.spec.cluster.context' "$PRODUCTION_EXAMPLE")"
production_namespace="$(yq e -r '.spec.cluster.namespace' "$PRODUCTION_EXAMPLE")"
production_purge="${production_name}:${production_context}:${production_namespace}:PURGE"
reset_error="$TEMP_DIR/production-purge.err"
if "$TOOL_ROOT/fabricctl.sh" reset --file "$PRODUCTION_EXAMPLE" \
  --confirm "$production_name" \
  --confirm-context "$production_context" \
  --confirm-namespace "$production_namespace" \
  --purge-data --confirm-purge "$production_purge" \
  > /dev/null 2>"$reset_error"
then
  echo 'Expected production data purge to fail before contacting Kubernetes' >&2
  exit 1
fi
grep -q 'Refusing --purge-data outside a development environment' "$reset_error"

(
  cd "$TEMP_DIR"
  reset_log="$TEMP_DIR/reset-commands.log"
  mkdir -p reset-bundle/.state
  : >reset-bundle/.state/01.done
  : >reset-bundle/.state/10.done
  : >reset-bundle/.state/keep.txt
  FABRICCTL_RESET_TEST_LOG="$reset_log" \
    PATH="$TOOL_ROOT/tests/fixtures/reset-bin:$PATH" \
    "$TOOL_ROOT/fabricctl.sh" reset --file "$EXAMPLE" \
      --output reset-bundle \
      --confirm carbon-kind \
      --confirm-context kind-carbon-preprod-sim \
      --confirm-namespace carbon-stg >/dev/null

  [[ ! -e reset-bundle/.state/01.done ]]
  [[ ! -e reset-bundle/.state/10.done ]]
  [[ -e reset-bundle/.state/keep.txt ]]
  grep -q 'helm uninstall peer0-org1 ' "$reset_log"
  grep -q 'helm uninstall orderer0 ' "$reset_log"
  grep -q 'helm uninstall ca-ordererorg ' "$reset_log"
  grep -q 'delete deployment cc-supplychain-v1-org1 ' "$reset_log"
  grep -q 'delete service cc-supplychain-org1 ' "$reset_log"
  grep -q 'delete service cc-supplychain-v1-org1 ' "$reset_log"
  grep -q 'delete job chaincode-supplychain-org1-deadbeef00 ' "$reset_log"
  grep -q 'delete configmap peer-channel-channel1-org1-deadbeef00 ' "$reset_log"
  grep -q 'delete job channel-channel1-deadbeef00 ' "$reset_log"
  if grep -Eq '^kubectl .* -n carbon-stg delete (secret|persistentvolumeclaim|pvc|unrelated)' "$reset_log"; then
    echo 'Normal reset attempted to delete protected data or unrelated resources' >&2
    exit 1
  fi

  purge_log="$TEMP_DIR/purge-commands.log"
  FABRICCTL_RESET_TEST_LOG="$purge_log" \
    PATH="$TOOL_ROOT/tests/fixtures/reset-bin:$PATH" \
    "$TOOL_ROOT/fabricctl.sh" reset --file "$EXAMPLE" \
      --output reset-bundle \
      --confirm carbon-kind \
      --confirm-context kind-carbon-preprod-sim \
      --confirm-namespace carbon-stg \
      --purge-data \
      --confirm-purge carbon-kind:kind-carbon-preprod-sim:carbon-stg:PURGE >/dev/null
  grep -q 'delete secret org1-admin-msp ' "$purge_log"
  grep -q 'delete secret peer0-org1-tls ' "$purge_log"
  grep -q 'delete secret cc-supplychain-org1-msp ' "$purge_log"
  grep -q 'delete secret cc-supplychain-org1-tls ' "$purge_log"
  grep -q 'delete secret fabric-ca-enrollment-secrets ' "$purge_log"
  grep -q 'delete secret peer0-org1-couchdb ' "$purge_log"
  grep -q 'delete secret ca-org1-bootstrap ' "$purge_log"
  grep -q 'delete persistentvolumeclaim orderer0 ' "$purge_log"
  grep -q 'delete persistentvolumeclaim peer-org1 ' "$purge_log"
  grep -q 'delete persistentvolumeclaim couchdb-org1 ' "$purge_log"
  if grep -Eq '^kubectl .* -n carbon-stg delete secret regcred ' "$purge_log"; then
    echo 'Full purge attempted to delete the externally supplied image-pull Secret' >&2
    exit 1
  fi
)

plan_output="$("$TOOL_ROOT/fabricctl.sh" plan --file "$EXAMPLE")"
grep -q 'Step 09 - Join peers and set anchors' <<<"$plan_output"
grep -q 'Step 10 - Deploy and commit CCaaS chaincode' <<<"$plan_output"
grep -q 'Step 06 - Deploy Raft orderers \[ready\]' <<<"$plan_output"
grep -q 'Total peers/CouchDBs: 4 / 4' <<<"$plan_output"
grep -q 'No cluster changes were made.' <<<"$plan_output"

invalid_config="$TEMP_DIR/invalid-even-raft.yaml"
cp "$PRODUCTION_EXAMPLE" "$invalid_config"
yq e -i '.spec.topology.orderers = 2' "$invalid_config"
if "$TOOL_ROOT/fabricctl.sh" validate --file "$invalid_config" >/dev/null 2>&1; then
  echo 'Expected even production Raft configuration to fail validation' >&2
  exit 1
fi

duplicate_pvc_config="$TEMP_DIR/duplicate-peer-pvcs.yaml"
cp "$EXAMPLE" "$duplicate_pvc_config"
yq e -i '.spec.topology.peersPerOrganization = 2' "$duplicate_pvc_config"
if "$TOOL_ROOT/fabricctl.sh" validate --file "$duplicate_pvc_config" >/dev/null 2>&1; then
  echo 'Expected colliding generated peer PVC names to fail validation' >&2
  exit 1
fi

sensitive_config="$TEMP_DIR/inline-secret.yaml"
cp "$EXAMPLE" "$sensitive_config"
yq e -i '.spec.secrets.password = "must-not-be-here"' "$sensitive_config"
if "$TOOL_ROOT/fabricctl.sh" validate --file "$sensitive_config" >/dev/null 2>&1; then
  echo 'Expected inline secret value to fail validation' >&2
  exit 1
fi

unsafe_renewal_config="$TEMP_DIR/unsafe-renewal.yaml"
cp "$EXAMPLE" "$unsafe_renewal_config"
yq e -i '.spec.identities.renewalPolicy = "renew-all"' "$unsafe_renewal_config"
if "$TOOL_ROOT/fabricctl.sh" validate --file "$unsafe_renewal_config" >/dev/null 2>&1; then
  echo 'Expected unsupported automatic identity renewal to fail validation' >&2
  exit 1
fi

production_generation_config="$TEMP_DIR/production-registration-generation.yaml"
cp "$PRODUCTION_EXAMPLE" "$production_generation_config"
yq e -i '.spec.identities.registrationSecretMode = "generate"' "$production_generation_config"
if "$TOOL_ROOT/fabricctl.sh" validate --file "$production_generation_config" >/dev/null 2>&1; then
  echo 'Expected production registration credential generation to fail validation' >&2
  exit 1
fi

unpinned_publisher_config="$TEMP_DIR/unpinned-publisher.yaml"
cp "$EXAMPLE" "$unpinned_publisher_config"
yq e -i '.spec.images.kubectl = "registry.k8s.io/kubectl:v1.35.0"' "$unpinned_publisher_config"
if "$TOOL_ROOT/fabricctl.sh" validate --file "$unpinned_publisher_config" >/dev/null 2>&1; then
  echo 'Expected an unpinned kubectl publisher image to fail validation' >&2
  exit 1
fi

unpinned_orderer_config="$TEMP_DIR/unpinned-orderer.yaml"
cp "$EXAMPLE" "$unpinned_orderer_config"
yq e -i '.spec.images.fabricOrderer = "hyperledger/fabric-orderer:2.5.4"' "$unpinned_orderer_config"
if "$TOOL_ROOT/fabricctl.sh" validate --file "$unpinned_orderer_config" >/dev/null 2>&1; then
  echo 'Expected an unpinned Fabric orderer image to fail validation' >&2
  exit 1
fi

unpinned_peer_config="$TEMP_DIR/unpinned-peer.yaml"
cp "$EXAMPLE" "$unpinned_peer_config"
yq e -i '.spec.images.fabricPeer = "hyperledger/fabric-peer:2.5.4"' "$unpinned_peer_config"
if "$TOOL_ROOT/fabricctl.sh" validate --file "$unpinned_peer_config" >/dev/null 2>&1; then
  echo 'Expected an unpinned Fabric peer image to fail validation' >&2
  exit 1
fi

unpinned_couchdb_config="$TEMP_DIR/unpinned-couchdb.yaml"
cp "$EXAMPLE" "$unpinned_couchdb_config"
yq e -i '.spec.images.couchDB = "couchdb:3.3.2"' "$unpinned_couchdb_config"
if "$TOOL_ROOT/fabricctl.sh" validate --file "$unpinned_couchdb_config" >/dev/null 2>&1; then
  echo 'Expected an unpinned CouchDB image to fail validation' >&2
  exit 1
fi

unpinned_tools_config="$TEMP_DIR/unpinned-tools.yaml"
cp "$EXAMPLE" "$unpinned_tools_config"
yq e -i '.spec.images.fabricTools = "hyperledger/fabric-tools:2.5.4"' "$unpinned_tools_config"
if "$TOOL_ROOT/fabricctl.sh" validate --file "$unpinned_tools_config" >/dev/null 2>&1; then
  echo 'Expected an unpinned Fabric tools image to fail validation' >&2
  exit 1
fi

production_couchdb_generation_config="$TEMP_DIR/production-couchdb-generation.yaml"
cp "$PRODUCTION_EXAMPLE" "$production_couchdb_generation_config"
yq e -i '.spec.databases.couchdbCredentialsMode = "generate"' "$production_couchdb_generation_config"
if "$TOOL_ROOT/fabricctl.sh" validate --file "$production_couchdb_generation_config" >/dev/null 2>&1; then
  echo 'Expected production CouchDB credential generation to fail validation' >&2
  exit 1
fi

unsupported_fabric_config="$TEMP_DIR/unsupported-fabric.yaml"
cp "$EXAMPLE" "$unsupported_fabric_config"
yq e -i '.spec.fabric.version = "3.0.0"' "$unsupported_fabric_config"
if "$TOOL_ROOT/fabricctl.sh" validate --file "$unsupported_fabric_config" >/dev/null 2>&1; then
  echo 'Expected an unsupported Fabric version to fail validation' >&2
  exit 1
fi

(
  cd "$TEMP_DIR"
  "$TOOL_ROOT/fabricctl.sh" render --file "$EXAMPLE" --to 4 --output bundle >/dev/null
  [[ -f bundle/inventory.yaml ]]
  [[ -f bundle/secrets/requirements.yaml ]]
  [[ "$(find bundle/values/cas -type f -name '*.yaml' | wc -l | tr -d ' ')" == 5 ]]
  [[ "$(find bundle/rendered/cas -type f -name '*.yaml' | wc -l | tr -d ' ')" == 5 ]]
  [[ "$(yq e -r '.spec.items | length' bundle/secrets/requirements.yaml)" == 10 ]]

  "$TOOL_ROOT/fabricctl.sh" render --file "$EXAMPLE" --from 5 --to 5 --output identity-bundle >/dev/null
  [[ -f identity-bundle/identities/identity-plan.yaml ]]
  [[ -f identity-bundle/identities/enrollment-plan.tsv ]]
  [[ -f identity-bundle/identities/enroll-identities.sh ]]
  [[ -f identity-bundle/rendered/identities/enroller-job.yaml ]]
  [[ "$(yq e -r '.spec.identities | length' identity-bundle/identities/identity-plan.yaml)" == 16 ]]
  [[ "$(wc -l <identity-bundle/identities/enrollment-plan.tsv | tr -d ' ')" == 16 ]]
  [[ "$(yq e -r '.spec.template.spec.initContainers | length' identity-bundle/rendered/identities/enroller-job.yaml)" == 1 ]]
  [[ "$(yq e -r '.spec.template.spec.containers | length' identity-bundle/rendered/identities/enroller-job.yaml)" == 32 ]]
  rg -F -- '--from-file=ca.crt=/work/packages/cc-supplychain-org1-tls/ca.crt' identity-bundle/rendered/identities/enroller-job.yaml >/dev/null
  rg -F -- '--from-file=client.crt=/work/packages/cc-supplychain-org1-tls/client.crt' identity-bundle/rendered/identities/enroller-job.yaml >/dev/null
  [[ "$(yq e -r '.spec.template.spec.serviceAccountName' identity-bundle/rendered/identities/enroller-job.yaml)" == carbon-user ]]
  [[ "$(yq e -r '.spec.template.spec.automountServiceAccountToken' identity-bundle/rendered/identities/enroller-job.yaml)" == false ]]
  [[ "$(yq e -r '[.spec.template.spec.initContainers[]?, .spec.template.spec.containers[]?] | .[] | .securityContext.readOnlyRootFilesystem' identity-bundle/rendered/identities/enroller-job.yaml | sort -u)" == true ]]
  [[ "$(yq e '[.spec.template.spec.initContainers[] | .volumeMounts[]?.name | select(. == "api-access")] | length' identity-bundle/rendered/identities/enroller-job.yaml)" == 0 ]]
  [[ "$(yq e '[.spec.template.spec.containers[] | select(([.volumeMounts[]?.name | select(. == "api-access")] | length) == 0) | .name] | length' identity-bundle/rendered/identities/enroller-job.yaml)" == 0 ]]
  if rg -q 'kubectl cp|pods/exec|hostPath:' identity-bundle; then
    echo 'Identity bundle must not use host extraction or pods/exec' >&2
    exit 1
  fi
  identity_digest="$(digest_file identity-bundle/rendered/identities/enroller-job.yaml)"
  "$TOOL_ROOT/fabricctl.sh" render --file "$EXAMPLE" --from 5 --to 5 --output identity-bundle >/dev/null
  [[ "$identity_digest" == "$(digest_file identity-bundle/rendered/identities/enroller-job.yaml)" ]]

  "$TOOL_ROOT/fabricctl.sh" render --file "$EXAMPLE" --from 6 --to 6 --output orderer-bundle >/dev/null
  [[ "$(find orderer-bundle/values/orderers -type f -name '*.yaml' | wc -l | tr -d ' ')" == 3 ]]
  [[ "$(find orderer-bundle/rendered/orderers -type f -name '*.yaml' | wc -l | tr -d ' ')" == 3 ]]
  orderer_manifest=orderer-bundle/rendered/orderers/orderer0.yaml
  [[ "$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.automountServiceAccountToken' "$orderer_manifest")" == false ]]
  [[ "$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.initContainers // [] | length' "$orderer_manifest")" == 0 ]]
  [[ "$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.containers | length' "$orderer_manifest")" == 1 ]]
  [[ "$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.containers[0].readinessProbe.httpGet.scheme' "$orderer_manifest")" == HTTPS ]]
  [[ "$(yq e -r 'select(.kind == "ConfigMap") | .data.ORDERER_GENERAL_BOOTSTRAPMETHOD' "$orderer_manifest")" == none ]]
  [[ "$(yq e -r 'select(.kind == "ConfigMap") | .data.ORDERER_OPERATIONS_TLS_ENABLED' "$orderer_manifest")" == true ]]
  [[ "$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.volumes[] | select(.name == "datadir") | .persistentVolumeClaim.claimName' "$orderer_manifest")" == orderer0 ]]
  if rg -q 'kind: (Namespace|StorageClass|PersistentVolume|ClusterRole|ClusterRoleBinding)|hostPath:|:latest' orderer-bundle/rendered/orderers; then
    echo 'Orderer bundle rendered forbidden resources or images' >&2
    exit 1
  fi
  orderer_digest="$(digest_file "$orderer_manifest")"
  "$TOOL_ROOT/fabricctl.sh" render --file "$EXAMPLE" --from 6 --to 6 --output orderer-bundle >/dev/null
  [[ "$orderer_digest" == "$(digest_file "$orderer_manifest")" ]]

  "$TOOL_ROOT/fabricctl.sh" render --file "$EXAMPLE" --from 7 --to 7 --output peer-bundle >/dev/null
  [[ "$(find peer-bundle/values/peers -type f -name '*.yaml' | wc -l | tr -d ' ')" == 4 ]]
  [[ "$(find peer-bundle/rendered/peers -type f -name '*.yaml' | wc -l | tr -d ' ')" == 4 ]]
  [[ "$(yq e -r '.spec.items | length' peer-bundle/secrets/couchdb-requirements.yaml)" == 4 ]]
  peer_manifest=peer-bundle/rendered/peers/peer0-org1.yaml
  [[ "$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.automountServiceAccountToken' "$peer_manifest")" == false ]]
  [[ "$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.initContainers // [] | length' "$peer_manifest")" == 0 ]]
  [[ "$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.containers | length' "$peer_manifest")" == 2 ]]
  [[ "$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.containers[] | select(.name == "peer0-org1") | .readinessProbe.httpGet.scheme' "$peer_manifest")" == HTTPS ]]
  [[ "$(yq e -r 'select(.kind == "ConfigMap" and .metadata.name == "peer0-org1-config") | .data.CORE_OPERATIONS_TLS_ENABLED' "$peer_manifest")" == true ]]
  [[ "$(yq e -r 'select(.kind == "ConfigMap" and .metadata.name == "peer0-org1-config") | .data.CORE_VM_ENDPOINT' "$peer_manifest")" == "" ]]
  [[ "$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.volumes[] | select(.name == "datadir") | .persistentVolumeClaim.claimName' "$peer_manifest")" == peer-org1 ]]
  [[ "$(yq e -r 'select(.kind == "StatefulSet") | .spec.template.spec.volumes[] | select(.name == "datadir-couchdb") | .persistentVolumeClaim.claimName' "$peer_manifest")" == couchdb-org1 ]]
  [[ -z "$(yq e 'select(.kind == "Service") | .spec.ports[] | select(.name == "couchdb" or .name == "grpc-web") | .name' "$peer_manifest")" ]]
  if rg -q 'kind: (Namespace|StorageClass|PersistentVolume|ClusterRole|ClusterRoleBinding)|hostPath:|supplychain-userpw' peer-bundle/rendered/peers; then
    echo 'Peer bundle rendered forbidden resources, images, mounts, or credentials' >&2
    exit 1
  fi
  peer_digest="$(digest_file "$peer_manifest")"
  "$TOOL_ROOT/fabricctl.sh" render --file "$EXAMPLE" --from 7 --to 7 --output peer-bundle >/dev/null
  [[ "$peer_digest" == "$(digest_file "$peer_manifest")" ]]

  "$TOOL_ROOT/fabricctl.sh" render --file "$EXAMPLE" --from 8 --to 8 --output channel-bundle >/dev/null
  [[ -f channel-bundle/channels/channel1/configtx.yaml ]]
  [[ -f channel-bundle/channels/channel1/run.sh ]]
  [[ -f channel-bundle/channels/channel1/profile.sha256 ]]
  [[ -f channel-bundle/rendered/channels/channel1.yaml ]]
  [[ -f channel-bundle/rendered/channels/channel1-receipt.yaml ]]
  channel_profile_sha="$(tr -d '\r\n' <channel-bundle/channels/channel1/profile.sha256)"
  [[ "$channel_profile_sha" == "$(digest_file channel-bundle/channels/channel1/configtx.yaml)" ]]
  [[ "$(yq e -r '.Organizations | length' channel-bundle/channels/channel1/configtx.yaml)" == 5 ]]
  [[ "$(yq e -r '.Orderer.EtcdRaft.Consenters | length' channel-bundle/channels/channel1/configtx.yaml)" == 3 ]]
  channel_manifest=channel-bundle/rendered/channels/channel1.yaml
  [[ "$(yq ea '[select(.kind == "ConfigMap")] | length' "$channel_manifest")" == 1 ]]
  [[ "$(yq ea '[select(.kind == "Job")] | length' "$channel_manifest")" == 1 ]]
  [[ "$(yq e -r 'select(.kind == "Job") | .spec.template.spec.automountServiceAccountToken' "$channel_manifest")" == false ]]
  [[ "$(yq e -r 'select(.kind == "Job") | .spec.template.spec.initContainers // [] | length' "$channel_manifest")" == 0 ]]
  [[ "$(yq e -r 'select(.kind == "Job") | .spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem' "$channel_manifest")" == true ]]
  [[ "$(yq e -r 'select(.kind == "Job") | .spec.template.spec.containers[0].image' "$channel_manifest")" == "$(yq e -r '.spec.images.fabricTools' "$EXAMPLE")" ]]
  [[ "$(yq e -r 'select(.kind == "Job") | .spec.template.spec.volumes[] | select(.name == "admin-tls") | .secret.secretName' "$channel_manifest")" == ordererorg-admin-tls ]]
  [[ "$(yq e -r '.data.profileSha256' channel-bundle/rendered/channels/channel1-receipt.yaml)" == "$channel_profile_sha" ]]
  if rg -q 'kubectl|pods/exec|hostPath:|:latest|REPLACE_WITH' "$channel_manifest"; then
    echo 'Channel bundle rendered an unsafe command, mount, image, or placeholder' >&2
    exit 1
  fi
  channel_digest="$(digest_file "$channel_manifest")"
  "$TOOL_ROOT/fabricctl.sh" render --file "$EXAMPLE" --from 8 --to 8 --output channel-bundle >/dev/null
  [[ "$channel_digest" == "$(digest_file "$channel_manifest")" ]]

  "$TOOL_ROOT/fabricctl.sh" render --file "$EXAMPLE" --from 9 --to 9 --output peer-channel-bundle >/dev/null
  [[ -f peer-channel-bundle/channels/channel1/peers/plan.yaml ]]
  [[ "$(find peer-channel-bundle/channels/channel1/peers -type f -name '*-run.sh' | wc -l | tr -d ' ')" == 4 ]]
  [[ "$(find peer-channel-bundle/rendered/channels -type f -name 'channel1-org*.yaml' | wc -l | tr -d ' ')" == 4 ]]
  [[ -f peer-channel-bundle/rendered/channels/channel1-peers-receipt.yaml ]]
  [[ "$(yq e -r '.spec.organizations | length' peer-channel-bundle/channels/channel1/peers/plan.yaml)" == 4 ]]
  [[ "$(yq e -r '.spec.organizations[].peers | length' peer-channel-bundle/channels/channel1/peers/plan.yaml | sort -u)" == 1 ]]
  [[ "$(yq e -r '.spec.organizations[0].anchorPeer.name' peer-channel-bundle/channels/channel1/peers/plan.yaml)" == peer0-org1 ]]
  peer_channel_manifest=peer-channel-bundle/rendered/channels/channel1-org1.yaml
  [[ "$(yq ea '[select(.kind == "ConfigMap")] | length' "$peer_channel_manifest")" == 1 ]]
  [[ "$(yq ea '[select(.kind == "Job")] | length' "$peer_channel_manifest")" == 1 ]]
  [[ "$(yq e -r 'select(.kind == "Job") | .spec.template.spec.automountServiceAccountToken' "$peer_channel_manifest")" == false ]]
  [[ "$(yq e -r 'select(.kind == "Job") | .spec.template.spec.initContainers // [] | length' "$peer_channel_manifest")" == 0 ]]
  [[ "$(yq e -r 'select(.kind == "Job") | .spec.template.spec.containers | length' "$peer_channel_manifest")" == 1 ]]
  [[ "$(yq e -r 'select(.kind == "Job") | .spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem' "$peer_channel_manifest")" == true ]]
  [[ "$(yq e -r 'select(.kind == "Job") | .spec.template.spec.containers[0].image' "$peer_channel_manifest")" == "$(yq e -r '.spec.images.fabricTools' "$EXAMPLE")" ]]
  [[ "$(yq e -r 'select(.kind == "Job") | .spec.template.spec.volumes[] | select(.name == "admin-msp") | .projected.sources[] | select(.secret.name == "org1-admin-msp") | .secret.name' "$peer_channel_manifest")" == org1-admin-msp ]]
  [[ "$(yq e -r 'select(.kind == "Job") | .spec.template.spec.volumes[] | select(.name == "operation") | .projected.sources[] | select(.configMap.name == "peer0-org1-builders-config") | .configMap.items[0].key' "$peer_channel_manifest")" == core.yaml ]]
  [[ "$(yq e -r '.data.peers' peer-channel-bundle/rendered/channels/channel1-peers-receipt.yaml)" == peer0-org1,peer0-org2,peer0-org3,peer0-org4 ]]
  rg -F '| .value.anchor_peers = [{"host":$host,"port":$port}])'"'"' /work/original-config.json > /work/modified-config.json' peer-channel-bundle/channels/channel1/peers/org1-run.sh >/dev/null
  if rg -q '^[[:space:]]*/work/original-config.json >' peer-channel-bundle/channels/channel1/peers/org1-run.sh; then
    echo 'Peer channel runner split the jq input into an executable path' >&2
    exit 1
  fi
  for contract in 'peer channel join' 'peer channel getinfo' 'configtxlator compute_update' 'peer channel update' PEER_READY ANCHOR_READY; do
    rg -F "$contract" "$peer_channel_manifest" >/dev/null
  done
  if rg -q 'kubectl|pods/exec|hostPath:|:latest|REPLACE_WITH' peer-channel-bundle/rendered/channels; then
    echo 'Peer channel bundle rendered an unsafe command, mount, image, or placeholder' >&2
    exit 1
  fi
  peer_channel_digest="$(digest_file "$peer_channel_manifest")"
  "$TOOL_ROOT/fabricctl.sh" render --file "$EXAMPLE" --from 9 --to 9 --output peer-channel-bundle >/dev/null
  [[ "$peer_channel_digest" == "$(digest_file "$peer_channel_manifest")" ]]

  "$TOOL_ROOT/fabricctl.sh" render --file "$EXAMPLE" --from 10 --to 10 --output chaincode-bundle >/dev/null
  [[ -f chaincode-bundle/chaincodes/supplychain/plan.yaml ]]
  [[ "$(find chaincode-bundle/rendered/chaincodes -type f -name 'supplychain-org*-lifecycle.yaml' | wc -l | tr -d ' ')" == 4 ]]
  [[ "$(yq e -r '.spec.organizations | length' chaincode-bundle/chaincodes/supplychain/plan.yaml)" == 4 ]]
  [[ "$(yq ea -N -r '[select(.kind == "Deployment") | .spec.template.spec.automountServiceAccountToken] | unique | .[]' chaincode-bundle/rendered/chaincodes/supplychain-runtime.yaml)" == false ]]
  [[ "$(yq ea -N -r '[select(.kind == "Deployment") | .spec.template.spec.containers[0].image] | unique | .[]' chaincode-bundle/rendered/chaincodes/supplychain-runtime.yaml)" == "$(yq e -r '.spec.images.chaincode' "$EXAMPLE")" ]]
  rg -F 'peer lifecycle chaincode install' chaincode-bundle/chaincodes/supplychain/org1-run.sh >/dev/null
  rg -F 'peer lifecycle chaincode commit' chaincode-bundle/chaincodes/supplychain/commit-run.sh >/dev/null
  rg -F 'Invalid function name: __fabricctl_healthcheck__' chaincode-bundle/chaincodes/supplychain/commit-run.sh >/dev/null
  if rg -q 'hostPath:|pods/exec|:latest|REPLACE_WITH' chaincode-bundle/rendered/chaincodes; then
    echo 'Chaincode bundle rendered an unsafe command, mount, image, or placeholder' >&2
    exit 1
  fi
  chaincode_digest="$(digest_file chaincode-bundle/rendered/chaincodes/supplychain-runtime.yaml)"
  "$TOOL_ROOT/fabricctl.sh" render --file "$EXAMPLE" --from 10 --to 10 --output chaincode-bundle >/dev/null
  [[ "$chaincode_digest" == "$(digest_file chaincode-bundle/rendered/chaincodes/supplychain-runtime.yaml)" ]]

  multi_peer_config="$TEMP_DIR/multi-peer-production.yaml"
  cp "$PRODUCTION_EXAMPLE" "$multi_peer_config"
  yq e -i '.spec.topology.peerOrganizations = 2 | .spec.topology.peersPerOrganization = 2' "$multi_peer_config"
  "$TOOL_ROOT/fabricctl.sh" render --file "$multi_peer_config" --from 9 --to 9 --output multi-peer-channel-bundle >/dev/null
  [[ "$(find multi-peer-channel-bundle/rendered/channels -type f -name 'channel1-org*.yaml' | wc -l | tr -d ' ')" == 2 ]]
  [[ "$(yq e -r '.spec.organizations[].peers | length' multi-peer-channel-bundle/channels/channel1/peers/plan.yaml | sort -u)" == 2 ]]
  rg -F 'PEER_READY channel=%s org=%s peer=peer1-org1' multi-peer-channel-bundle/channels/channel1/peers/org1-run.sh >/dev/null
  [[ "$(yq e -r '.spec.organizations[0].anchorPeer.name' multi-peer-channel-bundle/channels/channel1/peers/plan.yaml)" == peer0-org1 ]]

  "$TOOL_ROOT/fabricctl.sh" apply --file "$EXAMPLE" --to 1 --output generated --confirm carbon-kind >/dev/null
  first_digest="$(digest_file generated/inventory.yaml)"
  "$TOOL_ROOT/fabricctl.sh" apply --file "$EXAMPLE" --to 1 --output generated --confirm carbon-kind >/dev/null
  second_digest="$(digest_file generated/inventory.yaml)"
  [[ "$first_digest" == "$second_digest" ]]
  grep -q '^configSha256=' generated/.state/01.done

  yq e -i '.metadata.configSha256 = "stale"' generated/inventory.yaml
  "$TOOL_ROOT/fabricctl.sh" apply --file "$EXAMPLE" --to 1 --output generated --confirm carbon-kind >/dev/null 2>&1
  [[ "$(yq e -r '.metadata.configSha256' generated/inventory.yaml)" == "$(digest_file "$EXAMPLE")" ]]

  mkdir -p generated/.state/.apply.lock
  {
    printf 'pid=999999\n'
    printf 'host=%s\n' "$(hostname)"
  } >generated/.state/.apply.lock/owner
  "$TOOL_ROOT/fabricctl.sh" apply --file "$EXAMPLE" --to 1 --output generated --confirm carbon-kind >/dev/null 2>&1
  [[ ! -d generated/.state/.apply.lock ]]

)

echo 'fabricctl tests passed'
