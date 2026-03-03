#!/usr/bin/env zsh
# direnv-sandbox: bubblewrap sandboxing for direnv sessions (zsh)
#
# Source this file in your .zshrc INSTEAD OF eval "$(direnv hook zsh)".
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
      local status_json
      status_json="$("${DIRENV_SANDBOX_DIRENV_BIN:-direnv}" status --json 2>/dev/null)" || return 1
      local allowed
      allowed="$(print -r -- "$status_json" | tr -d '\n' | sed -n 's/.*"foundRC"[^}]*"allowed"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')"
      if [[ "$allowed" == "0" ]]; then
        print -rn -- "$dir"
        return 0
      fi
      return 1
    fi
    [[ "$dir" == "/" ]] && return 1
    dir="${dir:h}"
  done
}

# precmd hook for the OUTER shell (unsandboxed).
# Detects .envrc and launches a bwrap sandbox.
__direnv_sandbox_hook() {
  # Don't recurse if already inside a sandbox
  [[ -n "${_DIRENV_SANDBOX_ACTIVE:-}" ]] && return

  # Require DIRENV_SANDBOX_CMD to be set
  (( ${#DIRENV_SANDBOX_CMD[@]} == 0 )) && return

  local project_root
  project_root="$(__direnv_sandbox_find_envrc)" || return

  # Temp file for the inner shell to communicate its final directory
  local _DIRENV_SANDBOX_EXIT_DIR_FILE
  _DIRENV_SANDBOX_EXIT_DIR_FILE="${XDG_RUNTIME_DIR:-/tmp}/.direnv-sandbox-exit.$$"

  # Create the file so the sandbox can bind-mount it
  touch "$_DIRENV_SANDBOX_EXIT_DIR_FILE"

  # Launch sandboxed subshell
  _DIRENV_SANDBOX_ACTIVE=1 \
  _DIRENV_SANDBOX_ROOT="$project_root" \
  _DIRENV_SANDBOX_EXIT_DIR_FILE="$_DIRENV_SANDBOX_EXIT_DIR_FILE" \
    "${DIRENV_SANDBOX_CMD[@]}" -- zsh

  # Sync outer shell's CWD with where the user navigated inside the sandbox
  if [[ -s "$_DIRENV_SANDBOX_EXIT_DIR_FILE" ]]; then
    builtin cd -- "$(<"$_DIRENV_SANDBOX_EXIT_DIR_FILE")" 2>/dev/null
  fi
  rm -f "$_DIRENV_SANDBOX_EXIT_DIR_FILE" 2>/dev/null
}

# chpwd hook for the INNER shell (sandboxed).
# Exits the sandbox when the user navigates outside the project root.
# Using chpwd fires immediately on cd, not just on next prompt.
__direnv_sandbox_exit_hook() {
  case "$PWD" in
    "${_DIRENV_SANDBOX_ROOT}"|"${_DIRENV_SANDBOX_ROOT}/"*)
      ;;
    *)
      print -rn -- "$PWD" > "${_DIRENV_SANDBOX_EXIT_DIR_FILE:-/dev/null}" 2>/dev/null || true
      exit 0
      ;;
  esac
}

# --- Hook registration ---

if [[ -n "${_DIRENV_SANDBOX_ACTIVE:-}" ]]; then
  # INSIDE sandbox: install exit monitor + standard direnv hook
  typeset -ag chpwd_functions
  if (( ! ${chpwd_functions[(I)__direnv_sandbox_exit_hook]} )); then
    chpwd_functions=(__direnv_sandbox_exit_hook $chpwd_functions)
  fi
  eval "$("${DIRENV_SANDBOX_DIRENV_BIN:-direnv}" hook zsh)"
else
  # OUTSIDE sandbox: install sandbox entry hook (NO direnv hook)
  typeset -ag precmd_functions
  if (( ! ${precmd_functions[(I)__direnv_sandbox_hook]} )); then
    precmd_functions=(__direnv_sandbox_hook $precmd_functions)
  fi
fi
