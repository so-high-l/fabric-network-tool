# Fabric Network Tool

`fabricctl` builds a Hyperledger Fabric 2.5 network from one YAML file. It
generates deterministic artifacts, deploys namespace-scoped workloads in ten
verified stages, creates a Raft application channel, joins every peer,
configures anchor peers, and installs, approves, commits, and exercises one
mutual-TLS CCaaS chaincode definition.

Release scope: the current repository is a complete, tested local kind
deployment. The production schema is included for review, but the production
cluster runbook and target-specific configuration are the next release and are
not certified yet.

## Verified local result

The checked-in `examples/carbon-kind.yaml` four-organization reference is
running and passed the complete Step 1-10 verifier with:

- 5 healthy Fabric CAs;
- 3 healthy Raft orderers;
- 4 healthy peers, each with a private CouchDB sidecar;
- `channel1` active on all consenters;
- every peer joined with one anchor peer per organization;
- four healthy CCaaS services;
- `supplychain` installed, approved by all organizations, committed, and
  execution-verified;
- zero workload restarts during acceptance; and
- 12 healthy Helm releases.

Release packaging was independently tested from a blank cluster with
`examples/minimal-kind.yaml`: the one-command deploy created the cluster and
storage, completed all ten stages, executed the chaincode probe, then passed a
second idempotency run with six healthy Helm releases and zero restarts. That
disposable acceptance cluster was deleted after the test.

The setup is topology-driven. Orderer, organization, and peer counts come from
the network YAML; the local platform renderer generates the corresponding
namespace, RBAC, PVs, and PVCs.

`examples/minimal-kind.yaml` provides a smaller three-orderer/one-organization
fixture for quick smoke deployments. The carbon fixture is the full tested
four-organization reference.

## Repository layout

```text
fabricctl.sh             central validate/plan/render/apply/status/reset command
examples/                tested kind input and production-schema reference
steps/                   ten independently executable deployment stages
lib/                     rendering, validation, reconciliation, and verification
runtime/                 in-cluster identity-enrollment runtime
local-kind/              disposable cluster setup, image loading, deploy/verify
charts/                  vendored and hardened Hyperledger Bevel Fabric charts
tests/                   offline regression and security checks
```

The three vendored charts are intentionally part of this repository. A clone of
this directory no longer depends on a sibling Bevel checkout.

## Prerequisites

Install these commands before running a local deployment:

- Bash 3.2 or newer;
- Docker with a reachable daemon;
- kind;
- kubectl;
- Helm 3 or 4;
- mikefarah `yq` 4.x;
- OpenSSL 3.x;
- ripgrep (`rg`); and
- `sha256sum` or `shasum`.

The final clean acceptance run used Docker 29.4.2, kind 0.31.0, kubectl 1.36.0,
Helm 4.1.4, yq 4.53.2, and OpenSSL 3.6.2 on Apple Silicon. CI repeats the
offline rendering and security suite on Ubuntu.

## Quick start: complete kind deployment

Run commands from the repository root (`fabric-network-tool/`). First inspect
and validate the tested input:

```bash
./fabricctl.sh validate --file examples/carbon-kind.yaml
./fabricctl.sh plan --file examples/carbon-kind.yaml
```

The example references this digest-pinned local chaincode image:

```text
supplychain-ccaas:kind-arm64@sha256:46659da28466b6158b0ecff9facb6f5ce927d8ffed76b0948a2a917cc77b80ba
```

That application image is not distributed by this repository. Build or obtain
the trusted image first. The local loader refuses to alias it unless the OCI
digest imported into kind exactly matches `spec.images.chaincode`.

Deploy everything with one command:

```bash
./local-kind/deploy.sh \
  --file examples/carbon-kind.yaml \
  --chaincode-image supplychain-ccaas:kind-arm64
```

The command is modular internally. It:

1. validates the configuration;
2. creates or reuses only the configured `kind-*` cluster;
3. creates a Pod Security `restricted` namespace and namespace-scoped service
   account/RBAC;
4. creates topology-derived local static PVs and PVCs;
5. verifies the imported chaincode OCI digest;
6. runs Steps 1-10; and
7. performs a second deep verification/idempotency pass.

If `spec.images.chaincode` uses a registry-qualified public image, omit
`--chaincode-image` and kind will pull the configured digest. For a private
registry, create the configured pull Secret out of band. Never place a registry
token in the YAML or a committed shell script.

The same workflow is available through Make:

```bash
make validate
make kind-deploy CHAINCODE_IMAGE=supplychain-ccaas:kind-arm64
make verify
```

## Customize the local topology

Copy the tested example to an ignored local file:

```bash
cp examples/carbon-kind.yaml examples/my-network.local.yaml
```

Edit these user-facing fields:

- `metadata.name`;
- `spec.cluster.context`, which must start with `kind-`;
- `spec.cluster.namespace` and `serviceAccount`;
- `spec.network.domain` and `spec.dns.clusterDomain`;
- `spec.topology.orderers` (an odd number);
- `spec.topology.peerOrganizations`;
- `spec.topology.peersPerOrganization`;
- `spec.channel.name`;
- `spec.chaincode` definition; and
- the digest-pinned chaincode image.

The carbon fixture has custom one-peer PVC templates matching the original
limited-access simulation. Remove its `storage.claimTemplates` block when
increasing `peersPerOrganization`; the default templates include the peer index
and avoid collisions.

Secret values are rejected anywhere under common sensitive YAML keys. Local
development may generate missing CA roots, identity registration passwords,
and CouchDB passwords once inside Kubernetes. Staging and production inputs
must use externally supplied material.

## Modular commands

Validate without writing:

```bash
./fabricctl.sh validate --file examples/carbon-kind.yaml
```

Show the selected stages without contacting Kubernetes:

```bash
./fabricctl.sh plan --file examples/carbon-kind.yaml --from 1 --to 10
```

Render deterministic artifacts without contacting Kubernetes:

```bash
./fabricctl.sh render --file examples/carbon-kind.yaml --to 10
```

Run read-only cluster preflight checks:

```bash
./fabricctl.sh preflight --file examples/carbon-kind.yaml --from 1 --to 2
```

Apply a selected range with the exact network-name confirmation:

```bash
./fabricctl.sh apply \
  --file examples/carbon-kind.yaml \
  --from 1 --to 10 \
  --confirm carbon-kind
```

Show local completion records:

```bash
./fabricctl.sh status --file examples/carbon-kind.yaml
```

A repeat `apply` does not blindly trust local state. It verifies artifacts,
Kubernetes health, identities, channel receipts, peer membership, anchor state,
and chaincode execution before skipping each completed stage.

## The ten stages

| Step | Module | Verified result |
|---:|---|---|
| 1 | Freeze design and inventory | Deterministic, validated topology inventory |
| 2 | Verify Kubernetes platform | Exact context, namespace RBAC, and bound PVCs |
| 3 | Establish secret management | Complete and valid CA bootstrap/TLS contracts |
| 4 | Deploy Fabric CAs | Healthy digest-pinned CA releases |
| 5 | Enroll and package identities | Valid MSP/TLS pairs for admins, nodes, and CCaaS |
| 6 | Deploy Raft orderers | Healthy participation-mode orderers |
| 7 | Deploy peers and CouchDB | Healthy peers and private CouchDB sidecars |
| 8 | Create channel and activate Raft | Channel active on every consenter with leader evidence |
| 9 | Join peers and set anchors | Every peer joined and every anchor configured |
| 10 | Deploy and commit CCaaS | Installed, approved, committed, executable chaincode |

An apply completion record is written only after both reconciliation and deep
verification succeed. Records include the complete input SHA-256 digest.

## Generated output

The default local output is `build/<network>/`, which is ignored by Git:

```text
inventory.yaml
secrets/requirements.yaml
identities/
values/cas/
values/orderers/
values/peers/
channels/
chaincodes/
rendered/
.state/
```

Generated artifacts contain public topology/configuration and local resume
state, not exported Kubernetes Secret values. Private identity material stays
inside the namespace and is created by a short-lived, restricted enrollment
Job. Do not weaken the ignore rules or commit generated output.

## Verification and tests

Run the offline regression suite:

```bash
./tests/test-fabricctl.sh
```

For the full release gate, install `shellcheck` and run:

```bash
./tests/security-check.sh
```

The release gate performs Bash syntax checks, ShellCheck, Helm lint, credential
and private-key pattern scans, unsafe evaluation checks, configuration abuse
tests, deterministic Step 1-10 rendering, Kubernetes security-context checks,
reset-scope tests, stale-state repair, and idempotency checks.

Verify a running local deployment:

```bash
./local-kind/verify.sh --file examples/carbon-kind.yaml
```

This performs the deep idempotency pass and fails on missing/unhealthy releases,
non-running workloads, unready containers, or any container restart.

## Reset and clean rebuild

Normal reset removes this network's workloads and lifecycle evidence while
preserving identities, credentials, PVCs, ledger data, the namespace, and
cluster-scoped resources:

```bash
./fabricctl.sh reset \
  --file examples/carbon-kind.yaml \
  --confirm carbon-kind \
  --confirm-context kind-carbon-preprod-sim \
  --confirm-namespace carbon-stg
```

Development kind only: purge generated Secrets and configured PVC claims with
the additional target-bound confirmation:

```bash
./fabricctl.sh reset \
  --file examples/carbon-kind.yaml \
  --confirm carbon-kind \
  --confirm-context kind-carbon-preprod-sim \
  --confirm-namespace carbon-stg \
  --purge-data \
  --confirm-purge carbon-kind:kind-carbon-preprod-sim:carbon-stg:PURGE
```

The cleanest local restart is deleting the disposable kind cluster:

```bash
./local-kind/destroy.sh \
  --file examples/carbon-kind.yaml \
  --confirm carbon-kind:kind-carbon-preprod-sim:DELETE
```

Deletion is refused unless the configuration is development, its context starts
with `kind-`, and the confirmation matches the network and context exactly.

## Security model

- Network YAML is parsed as data and is never sourced or evaluated as shell.
- All generated Kubernetes names, DNS names, MSP IDs, and PVC claims are
  validated for format and collision.
- Every runtime image must include an immutable SHA-256 digest.
- Fabric node workloads disable API-token automounting, privilege escalation,
  and added Linux capabilities, use non-root identities and seccomp, and avoid
  host paths and Docker sockets.
- Operations endpoints use TLS; CCaaS uses mutual TLS.
- CouchDB is not exposed through a Service and credentials are Secret refs.
- Lifecycle Jobs receive only the MSP/TLS material required for their task and
  do not mount Kubernetes API tokens.
- The identity enrollment container cannot access the Kubernetes API. Separate
  digest-pinned publisher containers receive short-lived projected tokens only
  after enrollment has completed.
- Rendered charts are checked for cluster-scoped resources and server-admitted
  before the first Helm reconciliation.
- An atomic, ownership-recorded lock blocks concurrent apply/reset operations.
- Production rejects generated credentials, CA debug mode, disabled operations
  TLS, dynamic storage, and fewer than three/even Raft members.

This does not defend against a compromised workstation, Kubernetes control
plane, cluster administrator, container registry, or malicious chaincode image.
Image provenance, vulnerability scanning, admission policy, backup, monitoring,
certificate rotation, and external secret management remain operator duties.
See [SECURITY.md](SECURITY.md) for reporting and trust boundaries.

## Current limitations

- The supported release target is local kind; production rollout is next.
- v1alpha1 supports Fabric 2.5.x, one initial channel, uniform peers per
  organization, and one initial CCaaS definition.
- Identity renewal policy is preserve-only; automatic rotation is intentionally
  fail-closed and not implemented.
- The backend and frontend applications are outside this repository.
- The chaincode application image/source is supplied separately.

## License and third-party code

The repository is distributed under the Apache License 2.0. The vendored,
modified Hyperledger Bevel charts retain their upstream notices; see
[NOTICE](NOTICE) and [LICENSE](LICENSE).
