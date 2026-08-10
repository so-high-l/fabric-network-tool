#!/usr/bin/env bash
set -euo pipefail

TOOL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CALLER_DIR="$PWD"
export FABRIC_TOOL_ROOT="$TOOL_ROOT"
export FABRIC_TOOL_CALLER_DIR="$CALLER_DIR"

# shellcheck source=lib/common.sh
source "$TOOL_ROOT/lib/common.sh"
# shellcheck source=lib/config.sh
source "$TOOL_ROOT/lib/config.sh"
# shellcheck source=lib/inventory.sh
source "$TOOL_ROOT/lib/inventory.sh"
# shellcheck source=lib/kubernetes.sh
source "$TOOL_ROOT/lib/kubernetes.sh"
# shellcheck source=lib/identities.sh
source "$TOOL_ROOT/lib/identities.sh"
# shellcheck source=lib/peers.sh
source "$TOOL_ROOT/lib/peers.sh"
# shellcheck source=lib/chaincodes.sh
source "$TOOL_ROOT/lib/chaincodes.sh"
# shellcheck source=lib/reset.sh
source "$TOOL_ROOT/lib/reset.sh"

usage() {
  cat <<'USAGE'
fabricctl - staged Hyperledger Fabric deployment orchestrator

Usage:
  ./fabricctl.sh <command> --file <network.yaml> [options]

Commands:
  validate    Validate the user input and all generated names.
  plan        Show the selected deployment waves without touching a cluster.
  render      Generate reviewable local artifacts without touching a cluster.
  preflight   Run read-only readiness checks for the selected waves.
  apply       Run implemented waves, verify them, and record resumable state.
  status      Show implementation and local completion state.
  reset       Remove this network's workloads so deployment can restart cleanly.

Options:
  -f, --file PATH       FabricNetwork input file (required).
      --from STEP       First step, 1-10 (default: 1).
      --to STEP         Last step, 1-10 (default: 10).
      --output PATH     Override the relative output directory.
      --confirm NAME    Required for apply; must equal metadata.name.
      --confirm-context CONTEXT
                        Required for reset; must equal spec.cluster.context.
      --confirm-namespace NAMESPACE
                        Required for reset; must equal spec.cluster.namespace.
      --purge-data      Development kind only: also delete generated Fabric
                        Secrets and every configured PVC claim.
      --confirm-purge VALUE
                        Required with --purge-data; exact value is
                        NAME:CONTEXT:NAMESPACE:PURGE.
      --force           Re-run completed apply steps with the same config.
  -h, --help            Show this help.

Milestone safety:
  Steps 1-10 are implemented. plan, validate, status, and preflight never
  modify the cluster. reset is destructive and requires three exact target
  confirmations; full data purge is restricted to development kind contexts.
USAGE
}

COMMAND="${1:-help}"
if [[ "$COMMAND" == -h || "$COMMAND" == --help ]]; then
  COMMAND=help
fi
if [[ $# -gt 0 ]]; then
  shift
fi

CONFIG_FILE=''
FROM_STEP=1
TO_STEP=10
OUTPUT_OVERRIDE=''
CONFIRM_NAME=''
CONFIRM_CONTEXT=''
CONFIRM_NAMESPACE=''
CONFIRM_PURGE=''
PURGE_DATA=false
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file)
      [[ $# -ge 2 ]] || die "$1 requires a path"
      CONFIG_FILE="$2"
      shift 2
      ;;
    --from)
      [[ $# -ge 2 ]] || die "$1 requires a step number"
      FROM_STEP="$2"
      shift 2
      ;;
    --to)
      [[ $# -ge 2 ]] || die "$1 requires a step number"
      TO_STEP="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || die "$1 requires a path"
      OUTPUT_OVERRIDE="$2"
      shift 2
      ;;
    --confirm)
      [[ $# -ge 2 ]] || die "$1 requires the network name"
      CONFIRM_NAME="$2"
      shift 2
      ;;
    --confirm-context)
      [[ $# -ge 2 ]] || die "$1 requires the Kubernetes context"
      CONFIRM_CONTEXT="$2"
      shift 2
      ;;
    --confirm-namespace)
      [[ $# -ge 2 ]] || die "$1 requires the Kubernetes namespace"
      CONFIRM_NAMESPACE="$2"
      shift 2
      ;;
    --purge-data)
      PURGE_DATA=true
      shift
      ;;
    --confirm-purge)
      [[ $# -ge 2 ]] || die "$1 requires NAME:CONTEXT:NAMESPACE:PURGE"
      CONFIRM_PURGE="$2"
      shift 2
      ;;
    --force)
      FORCE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

if [[ "$COMMAND" == help ]]; then
  usage
  exit 0
fi

[[ "$COMMAND" =~ ^(validate|plan|render|preflight|apply|status|reset)$ ]] || die "Unknown command: $COMMAND"
if [[ "$COMMAND" != reset ]]; then
  [[ -z "$CONFIRM_CONTEXT" && -z "$CONFIRM_NAMESPACE" && -z "$CONFIRM_PURGE" && "$PURGE_DATA" == false ]] || \
    die '--confirm-context, --confirm-namespace, --purge-data, and --confirm-purge are valid only with reset'
fi
[[ -n "$CONFIG_FILE" ]] || die "--file is required"
[[ -f "$CONFIG_FILE" ]] || die "Configuration file does not exist: $CONFIG_FILE"
[[ "$FROM_STEP" =~ ^([1-9]|10)$ ]] || die "--from must be between 1 and 10"
[[ "$TO_STEP" =~ ^([1-9]|10)$ ]] || die "--to must be between 1 and 10"
((FROM_STEP <= TO_STEP)) || die "--from cannot be greater than --to"

CONFIG_DIR="$(cd "$(dirname "$CONFIG_FILE")" && pwd)"
FABRIC_TOOL_CONFIG="$CONFIG_DIR/$(basename "$CONFIG_FILE")"
export FABRIC_TOOL_CONFIG
require_sha256_command
FABRIC_TOOL_CONFIG_SHA="$(sha256_file "$FABRIC_TOOL_CONFIG")"
export FABRIC_TOOL_CONFIG_SHA

validate_config

OUTPUT_SETTING="$(output_directory_setting)"
if [[ -n "$OUTPUT_OVERRIDE" ]]; then
  OUTPUT_SETTING="$OUTPUT_OVERRIDE"
fi
[[ -n "$OUTPUT_SETTING" && "$OUTPUT_SETTING" != /* ]] || die "Output path must be a non-empty relative path"
[[ "$OUTPUT_SETTING" != '..' && "$OUTPUT_SETTING" != ../* && "$OUTPUT_SETTING" != */../* && "$OUTPUT_SETTING" != */.. ]] || die "Output path must not escape through .."
export FABRIC_TOOL_OUTPUT="$CALLER_DIR/${OUTPUT_SETTING#./}"
STATE_DIR="$FABRIC_TOOL_OUTPUT/.state"

step_number() {
  local step_file="$1"
  local base
  base="$(basename "$step_file")"
  printf '%d' "$((10#${base%%-*}))"
}

step_selected() {
  local number="$1"
  ((number >= FROM_STEP && number <= TO_STEP))
}

step_state_file() {
  local number="$1"
  printf '%s/%02d.done' "$STATE_DIR" "$number"
}

state_matches_config() {
  local state_file="$1"
  [[ -f "$state_file" ]] && grep -q "^configSha256=$FABRIC_TOOL_CONFIG_SHA$" "$state_file"
}

record_step_state() {
  local number="$1"
  local step_name="$2"
  local state_file temp_file
  state_file="$(step_state_file "$number")"
  mkdir -p "$STATE_DIR"
  temp_file="$(mktemp "${TMPDIR:-/tmp}/fabric-state.XXXXXX")"
  {
    printf 'network=%s\n' "$(network_name)"
    printf 'step=%02d\n' "$number"
    printf 'name=%s\n' "$step_name"
    printf 'configSha256=%s\n' "$FABRIC_TOOL_CONFIG_SHA"
    printf 'completedAt=%s\n' "$(utc_now)"
  } >"$temp_file"
  mv "$temp_file" "$state_file"
}

LOCK_DIR=''
LOCK_OWNER_FILE=''
release_lock() {
  if [[ -n "$LOCK_DIR" && -d "$LOCK_DIR" ]]; then
    if [[ -n "$LOCK_OWNER_FILE" ]]; then
      rm -f "$LOCK_OWNER_FILE"
    fi
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}

acquire_lock() {
  local owner_pid owner_host current_host
  mkdir -p "$STATE_DIR"
  LOCK_DIR="$STATE_DIR/.apply.lock"
  LOCK_OWNER_FILE="$LOCK_DIR/owner"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    if [[ -f "$LOCK_OWNER_FILE" ]]; then
      owner_pid="$(sed -n 's/^pid=//p' "$LOCK_OWNER_FILE")"
      owner_host="$(sed -n 's/^host=//p' "$LOCK_OWNER_FILE")"
      current_host="$(hostname)"
      if [[ "$owner_host" == "$current_host" && "$owner_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
        log_warn "Recovering stale apply lock from PID $owner_pid on $owner_host"
        rm -f "$LOCK_OWNER_FILE"
        rmdir "$LOCK_DIR" || die "Cannot recover stale apply lock: $LOCK_DIR"
        mkdir "$LOCK_DIR" || die "Cannot acquire apply lock after stale recovery: $LOCK_DIR"
      else
        die "Another apply owns $LOCK_DIR (pid=$owner_pid host=$owner_host)"
      fi
    else
      die "Another apply appears to be running, or an unowned lock requires inspection: $LOCK_DIR"
    fi
  fi
  {
    printf 'pid=%s\n' "$$"
    printf 'host=%s\n' "$(hostname)"
    printf 'network=%s\n' "$(network_name)"
    printf 'configSha256=%s\n' "$FABRIC_TOOL_CONFIG_SHA"
    printf 'startedAt=%s\n' "$(utc_now)"
  } >"$LOCK_OWNER_FILE"
  trap release_lock EXIT INT TERM
}

run_plan() {
  local step_file number title implementation
  printf '\nDeployment plan for %s\n' "$(network_name)"
  printf '%s\n' '============================================================'
  for step_file in "$TOOL_ROOT"/steps/[0-9][0-9]-*.sh; do
    number="$(step_number "$step_file")"
    step_selected "$number" || continue
    title="$($step_file name)"
    implementation="$($step_file implementation)"
    printf '\nStep %02d - %s [%s]\n' "$number" "$title" "$implementation"
    "$step_file" plan
  done
  printf '\nNo cluster changes were made.\n'
}

run_preflight() {
  local step_file number title failures=0
  for step_file in "$TOOL_ROOT"/steps/[0-9][0-9]-*.sh; do
    number="$(step_number "$step_file")"
    step_selected "$number" || continue
    title="$($step_file name)"
    printf '\nPreflight %02d - %s\n' "$number" "$title"
    if "$step_file" check; then
      log_ok "Step $(printf '%02d' "$number") preflight passed"
    else
      log_warn "Step $(printf '%02d' "$number") preflight failed"
      failures=$((failures + 1))
    fi
  done
  ((failures == 0)) || die "$failures preflight step(s) failed"
  log_ok "All selected read-only preflight checks passed"
}

run_render() {
  local step_file number title implementation
  for step_file in "$TOOL_ROOT"/steps/[0-9][0-9]-*.sh; do
    number="$(step_number "$step_file")"
    step_selected "$number" || continue
    title="$($step_file name)"
    implementation="$($step_file implementation)"
    if [[ "$implementation" != ready ]]; then
      log_warn "Skipping render for migration-pending step $(printf '%02d' "$number"): $title"
      continue
    fi
    printf '\nRender %02d - %s\n' "$number" "$title"
    "$step_file" render
  done
  log_ok "Selected apply-ready artifacts rendered under $FABRIC_TOOL_OUTPUT"
  printf 'No cluster changes were made.\n'
}

run_status() {
  local step_file number title implementation state_file completion
  printf '\n%-5s %-35s %-18s %s\n' 'STEP' 'NAME' 'IMPLEMENTATION' 'LOCAL STATE'
  printf '%-5s %-35s %-18s %s\n' '-----' '-----------------------------------' '------------------' '-----------'
  for step_file in "$TOOL_ROOT"/steps/[0-9][0-9]-*.sh; do
    number="$(step_number "$step_file")"
    step_selected "$number" || continue
    title="$($step_file name)"
    implementation="$($step_file implementation)"
    state_file="$(step_state_file "$number")"
    completion='pending'
    if state_matches_config "$state_file"; then
      completion='complete'
    elif [[ -f "$state_file" ]]; then
      completion='stale-config'
    fi
    printf '%-5s %-35s %-18s %s\n' "$(printf '%02d' "$number")" "$title" "$implementation" "$completion"
  done
}

run_apply() {
  local step_file number title implementation state_file
  [[ "$CONFIRM_NAME" == "$(network_name)" ]] || die "apply requires --confirm $(network_name)"
  acquire_lock

  for step_file in "$TOOL_ROOT"/steps/[0-9][0-9]-*.sh; do
    number="$(step_number "$step_file")"
    step_selected "$number" || continue
    title="$($step_file name)"
    implementation="$($step_file implementation)"
    state_file="$(step_state_file "$number")"

    if state_matches_config "$state_file" && [[ "$FORCE" != true ]]; then
      log_info "Verifying completed step $(printf '%02d' "$number") before resume: $title"
      if "$step_file" verify; then
        log_ok "Skipping verified step $(printf '%02d' "$number"): $title"
        continue
      fi
      log_warn "Recorded step $(printf '%02d' "$number") did not verify; reconciling it again"
    elif [[ -f "$state_file" && "$FORCE" != true ]]; then
      log_info "Verifying stale-config step $(printf '%02d' "$number") against the current input: $title"
      if "$step_file" verify; then
        record_step_state "$number" "$title"
        log_ok "Refreshed state without reconciliation for verified step $(printf '%02d' "$number"): $title"
        continue
      fi
      log_warn "Stale-config step $(printf '%02d' "$number") does not match the current desired state; reconciling it"
    fi
    [[ "$implementation" == ready ]] || die "Step $(printf '%02d' "$number") is not apply-ready in this milestone: $title"

    printf '\nApply %02d - %s\n' "$number" "$title"
    "$step_file" check
    "$step_file" apply
    "$step_file" verify
    record_step_state "$number" "$title"
    log_ok "Completed step $(printf '%02d' "$number"): $title"
  done
}

run_reset() {
  export RESET_CONFIRM_NAME="$CONFIRM_NAME"
  export RESET_CONFIRM_CONTEXT="$CONFIRM_CONTEXT"
  export RESET_CONFIRM_NAMESPACE="$CONFIRM_NAMESPACE"
  export RESET_CONFIRM_PURGE="$CONFIRM_PURGE"
  export RESET_PURGE_DATA="$PURGE_DATA"
  acquire_lock
  reset_network
}

case "$COMMAND" in
  validate)
    print_inventory_summary
    ;;
  plan)
    run_plan
    ;;
  render)
    run_render
    ;;
  preflight)
    run_preflight
    ;;
  status)
    run_status
    ;;
  apply)
    run_apply
    ;;
  reset)
    run_reset
    ;;
esac
