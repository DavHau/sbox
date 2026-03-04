#!/usr/bin/env bash
# direnv-sandbox: enable or disable bubblewrap sandboxing per .envrc directory
#
# Usage:
#   direnv-sandbox off [path]  — disable sandbox for the .envrc directory
#   direnv-sandbox on  [path]  — re-enable sandbox for the .envrc directory
#
# If [path] is omitted, walks upward from $PWD to find .envrc/.env.
# If [path] is given, walks upward from that directory instead.
#
# The disabled state is stored as symlinks in
#   ${XDG_DATA_HOME:-$HOME/.local/share}/direnv-sandbox/disabled/
# Each symlink is named by the sha256 hash of the .envrc directory path
# and points to the directory itself (similar to how direnv tracks allow/deny).
#
# This directory must never be writable from inside a sandbox.

set -euo pipefail

DISABLED_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/direnv-sandbox/disabled"

_hash_dir() {
  # Hash with trailing newline, matching direnv's pathHash convention
  printf '%s\n' "$1" | sha256sum | cut -d' ' -f1
}

# Walk upward from a starting directory looking for .envrc or .env.
_find_envrc_dir() {
  local dir="${1:-$PWD}"
  dir="$(cd "$dir" && pwd)" || return 1
  while true; do
    if [[ -f "$dir/.envrc" ]] || [[ -f "$dir/.env" ]]; then
      printf '%s' "$dir"
      return 0
    fi
    [[ "$dir" == "/" ]] && return 1
    dir="$(dirname "$dir")"
  done
}

_check_not_in_sandbox() {
  local action="$1"
  local envrc_dir="$2"
  if [[ -n "${SANDBOX:-}" ]]; then
    echo "Error: cannot disable the sandbox from inside the sandbox." >&2
    echo "" >&2
    echo "Open a new terminal and run:" >&2
    echo "" >&2
    echo "  direnv-sandbox $action $envrc_dir" >&2
    echo "" >&2
    exit 1
  fi
}

cmd_off() {
  local envrc_dir
  envrc_dir="$(_find_envrc_dir "${1:-}")" || {
    echo "Error: no .envrc or .env found in current directory or parents" >&2
    exit 1
  }
  _check_not_in_sandbox off "$envrc_dir"
  mkdir -p "$DISABLED_DIR"
  local hash
  hash="$(_hash_dir "$envrc_dir")"
  ln -sfn "$envrc_dir" "$DISABLED_DIR/$hash"
  echo "Sandbox disabled for: $envrc_dir"
}

cmd_on() {
  local envrc_dir
  envrc_dir="$(_find_envrc_dir "${1:-}")" || {
    echo "Error: no .envrc or .env found in current directory or parents" >&2
    exit 1
  }
  _check_not_in_sandbox on "$envrc_dir"
  local hash
  hash="$(_hash_dir "$envrc_dir")"
  if [[ -L "$DISABLED_DIR/$hash" ]]; then
    rm -f "$DISABLED_DIR/$hash"
    echo "Sandbox re-enabled for: $envrc_dir"
  else
    echo "Sandbox was already enabled for: $envrc_dir"
  fi
}

case "${1:-}" in
  off)
    cmd_off "${2:-}"
    ;;
  on)
    cmd_on "${2:-}"
    ;;
  *)
    echo "Usage: direnv-sandbox {on|off} [path]" >&2
    echo "" >&2
    echo "  off [path]  Disable sandbox for the .envrc directory" >&2
    echo "  on  [path]  Re-enable sandbox for the .envrc directory" >&2
    echo "" >&2
    echo "If path is omitted, searches upward from the current directory." >&2
    exit 1
    ;;
esac
