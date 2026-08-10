#!/usr/bin/env bash
set -euo pipefail

TOOL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export FABRIC_TOOL_ROOT="$TOOL_ROOT"
# shellcheck source=../lib/common.sh
source "$TOOL_ROOT/lib/common.sh"
# shellcheck source=../lib/config.sh
source "$TOOL_ROOT/lib/config.sh"
# shellcheck source=../lib/inventory.sh
source "$TOOL_ROOT/lib/inventory.sh"

ACTION="${1:-}"

case "$ACTION" in
  name)
    printf '%s\n' 'Freeze design and inventory'
    ;;
  implementation)
    printf '%s\n' 'ready'
    ;;
  plan)
    print_inventory_summary
    printf '  Output inventory:     %s/inventory.yaml\n' "$FABRIC_TOOL_OUTPUT"
    ;;
  check)
    require_tool_environment
    validate_config
    ;;
  render)
    require_tool_environment
    validate_config
    render_inventory "$FABRIC_TOOL_OUTPUT/inventory.yaml"
    ;;
  apply)
    require_tool_environment
    validate_config
    render_inventory "$FABRIC_TOOL_OUTPUT/inventory.yaml"
    ;;
  verify)
    require_tool_environment
    [[ -f "$FABRIC_TOOL_OUTPUT/inventory.yaml" ]] || die "Inventory was not generated"
    yq e '.' "$FABRIC_TOOL_OUTPUT/inventory.yaml" >/dev/null
    [[ "$(yq e -r '.metadata.configSha256' "$FABRIC_TOOL_OUTPUT/inventory.yaml")" == "$FABRIC_TOOL_CONFIG_SHA" ]] || die "Inventory config digest is stale"
    log_ok 'Generated inventory matches the current network input'
    ;;
  *)
    die "Unsupported action for step 01: $ACTION"
    ;;
esac
