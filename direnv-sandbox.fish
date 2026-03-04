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
    set -l dir $argv[1]
    set -l disabled_dir (set -q XDG_DATA_HOME; and echo $XDG_DATA_HOME; or echo $HOME/.local/share)/direnv-sandbox/disabled
    # Hash with trailing newline, matching direnv's pathHash convention
    set -l hash (printf '%s\n' $dir | command sha256sum | cut -d' ' -f1)
    test -L "$disabled_dir/$hash"
end

# --- INNER shell mode: exit monitor ---
if set -q _DIRENV_SANDBOX_ACTIVE
    # Set up standard direnv hook inside the sandbox
    set -l direnv_bin (set -q DIRENV_SANDBOX_DIRENV_BIN; and echo $DIRENV_SANDBOX_DIRENV_BIN; or echo direnv)
    $direnv_bin hook fish | source

    # Exit the sandbox when the user navigates outside the project tree.
    # Uses --on-variable PWD to catch cd, pushd, popd, prevd, nextd, etc.
    # exit 0 works from --on-variable handlers in fish 4.x.
    function __direnv_sandbox_exit_check --on-variable PWD
        switch $PWD
            case "$_DIRENV_SANDBOX_ROOT" "$_DIRENV_SANDBOX_ROOT/"*
                # Still inside the project tree
            case '*'
                if set -q _DIRENV_SANDBOX_EXIT_DIR_FILE
                    echo -n $PWD > $_DIRENV_SANDBOX_EXIT_DIR_FILE 2>/dev/null; or true
                end
                exit 0
        end
    end

# --- OUTER shell mode: sandbox entry ---
else
    # Launch a sandboxed subshell and sync CWD on exit.
    function __direnv_sandbox_run
        set -lx _DIRENV_SANDBOX_EXIT_DIR_FILE (set -q XDG_RUNTIME_DIR; and echo $XDG_RUNTIME_DIR; or echo /tmp)"/.direnv-sandbox-exit."$fish_pid
        touch $_DIRENV_SANDBOX_EXIT_DIR_FILE
        set -lx _DIRENV_SANDBOX_ACTIVE 1
        set -lx _DIRENV_SANDBOX_ROOT $__direnv_sandbox_project_root
        $DIRENV_SANDBOX_CMD $__direnv_sandbox_project_root -- fish
        if test -s "$_DIRENV_SANDBOX_EXIT_DIR_FILE"
            set -l exit_dir (cat $_DIRENV_SANDBOX_EXIT_DIR_FILE)
            builtin cd -- $exit_dir 2>/dev/null
        end
        rm -f $_DIRENV_SANDBOX_EXIT_DIR_FILE 2>/dev/null
    end

    # Check for sandbox entry after directory changes.
    # Wraps directory-changing commands instead of using --on-event
    # fish_prompt because the event handler approach fails to reclaim
    # the terminal foreground process group in our NixOS VM test
    # (tty1 + full sbox/bwrap/slirp4netns chain), despite working
    # fine in standalone tests with pseudo-terminals.
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

    # Prompt hook: keeps direnv running for disabled-sandbox directories.
    # Only calls direnv export when DIRENV_DIR is set (an unsandboxed direnv
    # session is active) or when we're in a disabled-sandbox dir that hasn't
    # been loaded yet (e.g. terminal opened directly in the project).
    function __direnv_sandbox_prompt_hook --on-event fish_prompt
        set -q _DIRENV_SANDBOX_ACTIVE; and return 0
        set -l direnv_bin (set -q DIRENV_SANDBOX_DIRENV_BIN; and echo $DIRENV_SANDBOX_DIRENV_BIN; or echo direnv)
        if set -q DIRENV_DIR
            # Active unsandboxed direnv session — let direnv handle reloads/unloads
            eval ($direnv_bin export fish)
        else if __direnv_sandbox_find_envrc; and __direnv_sandbox_is_disabled $__direnv_sandbox_project_root
            # In a disabled-sandbox dir with no active session (e.g. terminal startup)
            eval ($direnv_bin export fish)
        end
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

    # cd is a builtin in fish 4.x
    function cd --wraps cd
        builtin cd $argv; or return $status
        __direnv_sandbox_maybe_enter
        return 0
    end

    # pushd/popd/prevd/nextd are functions — save originals before wrapping
    for cmd in pushd popd prevd nextd
        functions --copy $cmd __direnv_sandbox_original_$cmd 2>/dev/null
    end

    function pushd --wraps pushd
        __direnv_sandbox_original_pushd $argv; or return $status
        __direnv_sandbox_maybe_enter
        return 0
    end

    function popd --wraps popd
        __direnv_sandbox_original_popd $argv; or return $status
        __direnv_sandbox_maybe_enter
        return 0
    end

    function prevd --wraps prevd
        __direnv_sandbox_original_prevd $argv; or return $status
        __direnv_sandbox_maybe_enter
        return 0
    end

    function nextd --wraps nextd
        __direnv_sandbox_original_nextd $argv; or return $status
        __direnv_sandbox_maybe_enter
        return 0
    end
end
