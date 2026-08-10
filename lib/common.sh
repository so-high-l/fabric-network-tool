#!/usr/bin/env bash

# Shared output and filesystem helpers. Callers enable their own strict mode.

readonly FABRICCTL_UNIMPLEMENTED=42

log_info() {
  printf '[INFO] %s\n' "$*"
}

log_ok() {
  printf '[ OK ] %s\n' "$*"
}

log_warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

require_command() {
  local command_name="$1"
  command -v "$command_name" >/dev/null 2>&1 || die "Missing required command: $command_name"
}

require_tool_environment() {
  : "${FABRIC_TOOL_ROOT:?FABRIC_TOOL_ROOT is required}"
  : "${FABRIC_TOOL_CONFIG:?FABRIC_TOOL_CONFIG is required}"
  : "${FABRIC_TOOL_OUTPUT:?FABRIC_TOOL_OUTPUT is required}"
  : "${FABRIC_TOOL_CONFIG_SHA:?FABRIC_TOOL_CONFIG_SHA is required}"
}

write_if_changed() {
  local source_file="$1"
  local destination_file="$2"

  mkdir -p "$(dirname "$destination_file")"
  if [[ -f "$destination_file" ]] && cmp -s "$source_file" "$destination_file"; then
    rm -f "$source_file"
    log_ok "Unchanged: $destination_file"
    return 0
  fi

  mv "$source_file" "$destination_file"
  log_ok "Wrote: $destination_file"
}

sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    die 'Missing SHA-256 command: install sha256sum or shasum'
  fi
}

require_sha256_command() {
  command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || \
    die 'Missing SHA-256 command: install sha256sum or shasum'
}

sha256_stream() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    die 'Missing SHA-256 command: install sha256sum or shasum'
  fi
}

utc_now() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

pending_apply() {
  log_warn "$1 has not been migrated into the apply path yet; no changes were made"
  return "$FABRICCTL_UNIMPLEMENTED"
}
