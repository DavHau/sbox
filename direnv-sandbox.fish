# direnv-sandbox: bubblewrap sandboxing for direnv sessions (fish)
#
# Source this file in your config.fish INSTEAD OF direnv hook fish | source.
# It replaces the standard direnv hook with a sandbox-aware version.
#
# Required environment:
#   DIRENV_SANDBOX_CMD - list with the bwrap command and arguments
#                        e.g. set -gx DIRENV_SANDBOX_CMD bwrap --ro-bind / / --dev /dev
#
# Optional environment:
#   DIRENV_SANDBOX_DIRENV_BIN - path to direnv binary (default: direnv)

# Walk $PWD upward looking for .envrc or .env.
# Only returns success if the envrc is allowed by direnv.
# Sets __direnv_sandbox_project_root on success.
function __direnv_sandbox_find_envrc
    set -l dir $PWD
    while true
        if test -f "$dir/.envrc"; or test -f "$dir/.env"
            set -l direnv_bin (set -q DIRENV_SANDBOX_DIRENV_BIN; and echo $DIRENV_SANDBOX_DIRENV_BIN; or echo direnv)
            set -l status_json ($direnv_bin status --json 2>/dev/null)
            or return 1
            set -l allowed (echo $status_json | tr -d '\n' | sed -n 's/.*"foundRC"[^}]*"allowed"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')
            if test "$allowed" = "0"
                set -g __direnv_sandbox_project_root $dir
                return 0
            end
            return 1
        end
        if test "$dir" = "/"
            return 1
        end
        set dir (dirname $dir)
    end
end

# --- INNER shell mode: exit monitor ---
if set -q _DIRENV_SANDBOX_ACTIVE
    # Monitor PWD changes and exit when leaving the project tree
    function __direnv_sandbox_exit_hook --on-variable PWD
        switch $PWD
            case "$_DIRENV_SANDBOX_ROOT" "$_DIRENV_SANDBOX_ROOT/*"
                # Still inside the project tree
            case '*'
                # Save the directory the user navigated to
                if set -q _DIRENV_SANDBOX_EXIT_DIR_FILE
                    echo -n $PWD > $_DIRENV_SANDBOX_EXIT_DIR_FILE 2>/dev/null; or true
                end
                exit 0
        end
    end

    # Set up standard direnv hook inside the sandbox
    set -l direnv_bin (set -q DIRENV_SANDBOX_DIRENV_BIN; and echo $DIRENV_SANDBOX_DIRENV_BIN; or echo direnv)
    $direnv_bin hook fish | source

# --- OUTER shell mode: sandbox entry ---
else
    function __direnv_sandbox_hook --on-event fish_prompt
        # Don't recurse if already inside a sandbox
        set -q _DIRENV_SANDBOX_ACTIVE; and return

        # Require DIRENV_SANDBOX_CMD to be set
        set -q DIRENV_SANDBOX_CMD; or return
        if test (count $DIRENV_SANDBOX_CMD) -eq 0
            return
        end

        __direnv_sandbox_find_envrc; or return

        # Temp file for the inner shell to communicate its final directory
        set -lx _DIRENV_SANDBOX_EXIT_DIR_FILE (set -q XDG_RUNTIME_DIR; and echo $XDG_RUNTIME_DIR; or echo /tmp)"/.direnv-sandbox-exit."$fish_pid

        # Create the file so the sandbox can bind-mount it
        touch $_DIRENV_SANDBOX_EXIT_DIR_FILE

        # Launch sandboxed subshell
        set -lx _DIRENV_SANDBOX_ACTIVE 1
        set -lx _DIRENV_SANDBOX_ROOT $__direnv_sandbox_project_root
        $DIRENV_SANDBOX_CMD -- fish

        # Sync outer shell's CWD with where the user navigated inside the sandbox
        if test -s "$_DIRENV_SANDBOX_EXIT_DIR_FILE"
            set -l exit_dir (cat $_DIRENV_SANDBOX_EXIT_DIR_FILE)
            builtin cd -- $exit_dir 2>/dev/null
        end
        rm -f $_DIRENV_SANDBOX_EXIT_DIR_FILE 2>/dev/null
    end
end
