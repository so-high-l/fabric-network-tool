# Security policy

## Supported scope

The current release is supported for disposable local kind deployments. The
production configuration file is a schema reference, not a production
certification or runbook. Production support will be released separately after
validation against the target cluster, storage, identity, DNS, and secret
management controls.

## Reporting a vulnerability

Use the repository's private GitHub Security Advisory reporting flow. Do not
open a public issue for suspected credential exposure, privilege escalation,
unsafe reset behavior, certificate validation bypass, image-integrity failure,
or command injection.

Include the affected command, sanitized configuration, expected result, actual
result, and a minimal reproduction. Never include Kubernetes Secrets, private
keys, registry tokens, kubeconfigs, or enrollment credentials.

## Security boundaries

- `fabricctl` operates only in the configured namespace and never changes the
  current `kubectl` context.
- Cluster-scoped local PV and namespace creation exists only in `local-kind/`
  and is rejected for non-development or non-`kind-*` configurations.
- Production must use externally provisioned CA, registration, CouchDB, and
  registry credentials. Secret values are forbidden in network YAML.
- Every runtime image must be pinned by SHA-256 digest. The local image loader
  checks the imported OCI digest before creating the kind containerd alias.
- Normal reset preserves Secrets and PVCs. Data purge and kind-cluster deletion
  require explicit, target-bound confirmations.
- Generated development CA roots are for disposable kind environments only.

See the README's threat model and production limitations before use.
