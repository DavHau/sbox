#!/usr/bin/env bash
# direnv-sandbox: bubblewrap sandboxing for direnv sessions
#
# Source this file in your .bashrc INSTEAD OF eval "$(direnv hook bash)".
# It replaces the standard direnv hook with a sandbox-aware version.
#
# Required environment:
#   DIRENV_SANDBOX_CMD - array with the bwrap command and arguments
#                        e.g. DIRENV_SANDBOX_CMD=(bwrap --ro-bind / / --dev /dev)
#
# Optional environment:
#   DIRENV_SANDBOX_DIRENV_BIN - path to direnv binary (default: direnv)

# Walk $PWD upward looking for .envrc or .env.
# Prints the directory containing the file, or nothing if not found.
# Only returns a result if the envrc is allowed by direnv.
__direnv_sandbox_find_envrc() {
  local dir="$PWD"
  while true; do
    if [[ -f "$dir/.envrc" ]] || [[ -f "$dir/.env" ]]; then
      # Check if direnv considers this RC allowed
      local status_json
      status_json="$("${DIRENV_SANDBOX_DIRENV_BIN:-direnv}" status --json 2>/dev/null)" || return 1
      local allowed
      allowed="$(printf '%s' "$status_json" | tr -d '\n' | sed -n 's/.*"foundRC"[^}]*"allowed"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')"
      # allowed == 0 means Allowed (the AllowStatus enum: 0=Allowed, 1=NotAllowed, 2=Denied)
      if [[ "$allowed" == "0" ]]; then
        printf '%s' "$dir"
        return 0
      fi
      return 1
    fi
    [[ "$dir" == "/" ]] && return 1
    dir="$(dirname "$dir")"
  done
}

# PROMPT_COMMAND hook for the OUTER shell (unsandboxed).
# Detects .envrc and launches a bwrap sandbox.
__direnv_sandbox_hook() {
  local previous_exit_status=$?

  # Don't recurse if already inside a sandbox
  if [[ -n "${_DIRENV_SANDBOX_ACTIVE:-}" ]]; then
    return "$previous_exit_status"
  fi

  # Require DIRENV_SANDBOX_CMD to be set
  if [[ ${#DIRENV_SANDBOX_CMD[@]} -eq 0 ]]; then
    return "$previous_exit_status"
  fi

  local project_root
  project_root="$(__direnv_sandbox_find_envrc)" || return "$previous_exit_status"

  # Temp file for the inner shell to communicate its final directory
  local _DIRENV_SANDBOX_EXIT_DIR_FILE
  _DIRENV_SANDBOX_EXIT_DIR_FILE="${XDG_RUNTIME_DIR:-/tmp}/.direnv-sandbox-exit.$$"

  # Create the file so the sandbox can bind-mount it
  touch "$_DIRENV_SANDBOX_EXIT_DIR_FILE"

  # Launch sandboxed subshell
  _DIRENV_SANDBOX_ACTIVE=1 \
  _DIRENV_SANDBOX_ROOT="$project_root" \
  _DIRENV_SANDBOX_EXIT_DIR_FILE="$_DIRENV_SANDBOX_EXIT_DIR_FILE" \
    "${DIRENV_SANDBOX_CMD[@]}" -- bash

  # Sync outer shell's CWD with where the user navigated inside the sandbox
  if [[ -s "$_DIRENV_SANDBOX_EXIT_DIR_FILE" ]]; then
    builtin cd -- "$(< "$_DIRENV_SANDBOX_EXIT_DIR_FILE")" 2>/dev/null
  fi
  rm -f "$_DIRENV_SANDBOX_EXIT_DIR_FILE" 2>/dev/null

  return "$previous_exit_status"
}

# PROMPT_COMMAND hook for the INNER shell (sandboxed).
# Exits the sandbox when the user navigates outside the project root.
__direnv_sandbox_exit_hook() {
  case "$PWD" in
    "${_DIRENV_SANDBOX_ROOT}"|"${_DIRENV_SANDBOX_ROOT}/"*)
      # Still inside the project tree, do nothing
      ;;
    *)
      # Save the directory the user navigated to, then exit the sandbox
      printf '%s' "$PWD" > "${_DIRENV_SANDBOX_EXIT_DIR_FILE:-/dev/null}" 2>/dev/null || true
      exit 0
      ;;
  esac
}

# --- Hook registration ---
# The same script serves both roles depending on whether we're inside a sandbox.

if [[ -n "${_DIRENV_SANDBOX_ACTIVE:-}" ]]; then
  # INSIDE sandbox: install exit monitor + standard direnv hook
  if [[ ";${PROMPT_COMMAND[*]:-};" != *";__direnv_sandbox_exit_hook;"* ]]; then
    if [[ "$(declare -p PROMPT_COMMAND 2>&1)" == "declare -a"* ]]; then
      PROMPT_COMMAND=(__direnv_sandbox_exit_hook "${PROMPT_COMMAND[@]}")
    else
      # shellcheck disable=SC2178,SC2128
      PROMPT_COMMAND="__direnv_sandbox_exit_hook${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
    fi
  fi
  eval "$("${DIRENV_SANDBOX_DIRENV_BIN:-direnv}" hook bash)"
else
  # OUTSIDE sandbox: install sandbox entry hook (NO direnv hook)
  if [[ ";${PROMPT_COMMAND[*]:-};" != *";__direnv_sandbox_hook;"* ]]; then
    if [[ "$(declare -p PROMPT_COMMAND 2>&1)" == "declare -a"* ]]; then
      PROMPT_COMMAND=(__direnv_sandbox_hook "${PROMPT_COMMAND[@]}")
    else
      # shellcheck disable=SC2178,SC2128
      PROMPT_COMMAND="__direnv_sandbox_hook${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
    fi
  fi
fi
