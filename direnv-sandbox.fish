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

# Check whether sandboxing is disabled for a given envrc directory.
# Returns 0 (true) if disabled, 1 (false) if enabled.
function __direnv_sandbox_is_disabled
    set -l dir (realpath $argv[1] 2>/dev/null; or echo $argv[1])
    set -l disabled_dir (set -q XDG_DATA_HOME; and echo $XDG_DATA_HOME; or echo $HOME/.local/share)/direnv-sandbox/disabled
    # Hash with trailing newline, matching direnv's pathHash convention
    set -l hash (printf '%s\n' $dir | command sha256sum | cut -d' ' -f1)
    test -L "$disabled_dir/$hash"
end

# --- INNER shell mode: exit monitor ---
if set -q _DIRENV_SANDBOX_ACTIVE
    # Clean up exported variables that may have leaked from the outer shell.
    # When the sandbox is entered via `z` (zoxide), the outer shell's
    # __zoxide_cd sets __zoxide_loop=1 as an exported variable for the
    # duration of __zoxide_cd_internal.  Our --on-variable PWD handler
    # spawns the sandbox subshell *during* that execution, so the child
    # inherits the exported __zoxide_loop — making every `z` inside the
    # sandbox think it's in an infinite loop.
    set -e __zoxide_loop

    # Set up standard direnv hook inside the sandbox
    set -l direnv_bin (set -q DIRENV_SANDBOX_DIRENV_BIN; and echo $DIRENV_SANDBOX_DIRENV_BIN; or echo direnv)
    $direnv_bin hook fish | source

    # Exit the sandbox when the user navigates outside the project tree.
    # Uses --on-variable PWD to catch cd, pushd, popd, prevd, nextd, etc.
    # exit 0 works from --on-variable handlers in fish 4.x.
    function __direnv_sandbox_exit_check --on-variable PWD
        if string match -q -- "$_DIRENV_SANDBOX_ROOT" $PWD
                ; or string match -q -- "$_DIRENV_SANDBOX_ROOT/*" $PWD
            # Still inside the project tree
            return
        end
        if set -q _DIRENV_SANDBOX_EXIT_DIR_FILE
            echo -n $PWD > $_DIRENV_SANDBOX_EXIT_DIR_FILE 2>/dev/null; or true
        end
        exit 0
    end

# --- OUTER shell mode: sandbox entry ---
else
    # Launch a sandboxed subshell and sync CWD on exit.
    function __direnv_sandbox_run
        set -lx _DIRENV_SANDBOX_EXIT_DIR_FILE (set -q XDG_RUNTIME_DIR; and echo $XDG_RUNTIME_DIR; or echo /tmp)"/.direnv-sandbox-exit."$fish_pid
        touch $_DIRENV_SANDBOX_EXIT_DIR_FILE
        # Resolve symlinks so the physical path inside the sandbox matches
        # what direnv's Go runtime sees via os.Getwd(), ensuring the allow
        # database hash is consistent.
        set -l resolved_root (realpath $__direnv_sandbox_project_root)
        set -lx _DIRENV_SANDBOX_ACTIVE 1
        set -lx _DIRENV_SANDBOX_ROOT $resolved_root
        $DIRENV_SANDBOX_CMD $resolved_root -- fish
        if test -s "$_DIRENV_SANDBOX_EXIT_DIR_FILE"
            set -l exit_dir (cat $_DIRENV_SANDBOX_EXIT_DIR_FILE)
            builtin cd -- $exit_dir 2>/dev/null
        end
        rm -f $_DIRENV_SANDBOX_EXIT_DIR_FILE 2>/dev/null
    end

    # Core sandbox logic: find envrc, check disabled state, launch sandbox
    # or fall back to plain direnv.  Called from the prompt hook and after
    # direnv allow/permit/grant.
    function __direnv_sandbox_maybe_enter
        set -q _DIRENV_SANDBOX_ACTIVE; and return 0
        set -q DIRENV_SANDBOX_CMD; or return 0
        test (count $DIRENV_SANDBOX_CMD) -eq 0; and return 0

        set -l direnv_bin (set -q DIRENV_SANDBOX_DIRENV_BIN; and echo $DIRENV_SANDBOX_DIRENV_BIN; or echo direnv)

        if not __direnv_sandbox_find_envrc
            # No envrc found. If direnv was active from a disabled-sandbox dir, let it unload.
            if set -q DIRENV_DIR
                eval ($direnv_bin export fish)
            end
            return 0
        end

        # Sandbox is disabled for this directory — run direnv directly (unsandboxed)
        if __direnv_sandbox_is_disabled $__direnv_sandbox_project_root
            eval ($direnv_bin export fish)
            return 0
        end

        __direnv_sandbox_run
    end

    # Trigger sandbox entry on any directory change (catches z, autojump,
    # cd, pushd, popd, and any other tool that modifies PWD).
    # The --on-variable PWD handler fires synchronously during cd,
    # launching the sandbox subshell before the builtin even returns.
    function __direnv_sandbox_pwd_watch --on-variable PWD
        __direnv_sandbox_maybe_enter
    end

    # Prompt hook: handles cases where PWD didn't change but action is
    # needed — disabled-sandbox direnv reloads/unloads, sandbox re-enable
    # after "direnv-sandbox on", and initial terminal startup in a project dir.
    function __direnv_sandbox_prompt_hook --on-event fish_prompt
        __direnv_sandbox_maybe_enter
    end

    # Re-check after direnv allow/permit/grant in case we're already
    # in a project directory whose .envrc just became allowed.
    function direnv --wraps direnv
        set -l direnv_bin (set -q DIRENV_SANDBOX_DIRENV_BIN; and echo $DIRENV_SANDBOX_DIRENV_BIN; or echo direnv)
        command $direnv_bin $argv
        set -l cmd_status $status
        if contains -- $argv[1] allow permit grant
            __direnv_sandbox_maybe_enter
        end
        return $cmd_status
    end
end
