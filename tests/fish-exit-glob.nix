# Regression test: fish's __direnv_sandbox_exit_check must not produce glob
# errors when the project directory has no visible children (only dotfiles
# like .envrc).
#
# In fish, `case "$VAR/"*` is a glob pattern. If nothing matches the wildcard,
# fish prints "No matches for wildcard" to stderr. This test ensures the exit
# check uses `string match` instead of `case` with globs.
{ pkgs }:
pkgs.runCommandLocal "fish-exit-glob" {
  nativeBuildInputs = [ pkgs.fish ];
} ''
  # Create a project dir with only a dotfile (no glob-visible children)
  PROJECT=$(mktemp -d)
  touch "$PROJECT/.envrc"

  # Extract just the exit check function from the fish script and test it
  STDERR=$(fish -c '
    set -gx _DIRENV_SANDBOX_ROOT "'$PROJECT'"
    set -gx _DIRENV_SANDBOX_ACTIVE 1
    source ${../direnv-sandbox.fish}

    # Simulate navigating outside the project — triggers __direnv_sandbox_exit_check.
    # The function calls exit, so run in a subshell.
    fish -c "
      set -gx _DIRENV_SANDBOX_ROOT \"'$PROJECT'\"
      set -gx _DIRENV_SANDBOX_ACTIVE 1
      source ${../direnv-sandbox.fish}
      cd /tmp
    " 2>&1
  ' 2>&1)

  if echo "$STDERR" | grep -q "No matches for wildcard"; then
    echo "FAIL: fish glob error detected in exit check:"
    echo "$STDERR"
    exit 1
  fi

  echo "PASS: no glob errors on sandbox exit from empty project dir"
  touch $out
''
