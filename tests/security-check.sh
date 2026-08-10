#!/usr/bin/env bash
set -euo pipefail

TOOL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for command_name in bash helm rg shellcheck yq; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'Missing security-check dependency: %s\n' "$command_name" >&2
    exit 1
  }
done

while IFS= read -r script; do
  bash -n "$script"
done < <(rg --files "$TOOL_ROOT" -g '*.sh')

shellcheck --external-sources --severity=warning \
  "$TOOL_ROOT/fabricctl.sh" \
  "$TOOL_ROOT"/lib/*.sh \
  "$TOOL_ROOT"/runtime/*.sh \
  "$TOOL_ROOT"/steps/*.sh \
  "$TOOL_ROOT"/local-kind/*.sh \
  "$TOOL_ROOT"/tests/*.sh \
  "$TOOL_ROOT"/tests/fixtures/reset-bin/*

for chart in fabric-ca-server fabric-orderernode fabric-peernode; do
  helm lint "$TOOL_ROOT/charts/$chart" >/dev/null
done

if rg -n -i \
  '(ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----)' \
  "$TOOL_ROOT"
then
  printf 'Potential committed credential or private key detected.\n' >&2
  exit 1
fi

if rg -n 'source[[:space:]]+[^#]*FABRIC_TOOL_CONFIG|eval[[:space:]]' "$TOOL_ROOT" -g '*.sh'; then
  printf 'Network YAML must never be sourced or evaluated as shell code.\n' >&2
  exit 1
fi

SENSITIVE_FILES="$(find "$TOOL_ROOT" -type f \( -name '*.key' -o -name '*.pem' -o -name '*.p12' -o -name '*.pfx' -o -name '*.jks' -o -name 'kubeconfig*' \) -print)"
[[ -z "$SENSITIVE_FILES" ]] || {
  printf 'Sensitive file type found in the source tree:\n%s\n' "$SENSITIVE_FILES" >&2
  exit 1
}

"$TOOL_ROOT/tests/test-fabricctl.sh"
printf 'fabric-network-tool security checks passed\n'
