# direnv-sandbox: bubblewrap sandboxing for direnv sessions (nushell)
#
# Source this file in your config.nu INSTEAD OF the standard direnv hook.
# It replaces the standard direnv hook with a sandbox-aware version.
#
# Required environment:
#   DIRENV_SANDBOX_CMD - path to the sbox wrapper binary
#
# Optional environment:
#   DIRENV_SANDBOX_DIRENV_BIN - path to direnv binary (default: direnv)

# Return the configured direnv binary or "direnv" as default.
def __direnv_sandbox_direnv_bin [] {
    $env.DIRENV_SANDBOX_DIRENV_BIN? | default "direnv"
}

# Walk $PWD upward looking for .envrc or .env.
# Only returns success if the envrc is allowed by direnv.
# Returns the project root path, or null if not found/not allowed.
def __direnv_sandbox_find_envrc [] {
    mut dir = $env.PWD
    loop {
        if ($dir | path join ".envrc" | path exists) or ($dir | path join ".env" | path exists) {
            let direnv_bin = (__direnv_sandbox_direnv_bin)
            let result = (do { ^$direnv_bin status --json } | complete)
            if $result.exit_code != 0 {
                return null
            }
            let status = ($result.stdout | from json)
            let allowed = ($status | get -o state.foundRC.allowed | default null)
            if $allowed == 0 {
                return $dir
            }
            return null
        }
        if $dir == "/" {
            return null
        }
        $dir = ($dir | path dirname)
    }
}

# Check whether sandboxing is disabled for a given envrc directory.
# Returns true if disabled, false if enabled.
def __direnv_sandbox_is_disabled [dir: string] {
    let resolved = (do { ^realpath $dir } | complete)
    let resolved_dir = if $resolved.exit_code == 0 {
        $resolved.stdout | str trim
    } else {
        $dir
    }
    let disabled_dir = (
        $env.XDG_DATA_HOME? | default ($env.HOME | path join ".local" "share")
        | path join "direnv-sandbox" "disabled"
    )
    # Hash with trailing newline, matching direnv's pathHash convention
    let hash = ($"($resolved_dir)\n" | ^sha256sum | split row " " | first)
    let link_path = ($disabled_dir | path join $hash)
    # Check it's a symlink (matching bash's [[ -L ... ]])
    ($link_path | path type) == "symlink"
}

# Apply direnv export json to the current environment.
# Handles PATH conversion from string to list and null values for unsetting.
def --env __direnv_sandbox_apply_export [] {
    let direnv_bin = (__direnv_sandbox_direnv_bin)
    let result = (do { ^$direnv_bin export json } | complete)
    if $result.exit_code != 0 or ($result.stdout | str trim | is-empty) {
        return
    }
    let changes = ($result.stdout | from json)
    for col in ($changes | columns) {
        let val = ($changes | get $col)
        if ($val | describe) == "nothing" {
            hide-env $col
        } else if $col == "PATH" {
            $env.PATH = ($val | split row (char esep))
        } else {
            load-env {($col): $val}
        }
    }
}

# --- INNER shell mode: exit monitor ---
if ("_DIRENV_SANDBOX_ACTIVE" in $env) {

    # Set up standard direnv hook inside the sandbox
    $env.config.hooks.pre_prompt = (
        $env.config.hooks.pre_prompt? | default [] | append {||
            __direnv_sandbox_apply_export
        }
    )

    # Exit the sandbox when the user navigates outside the project tree.
    let existing_pwd_hooks = ($env.config.hooks.env_change? | default {} | get -o PWD | default [])
    $env.config.hooks.env_change = (
        $env.config.hooks.env_change? | default {} | merge {
            PWD: ($existing_pwd_hooks | append {|before, after|
                let root = $env._DIRENV_SANDBOX_ROOT
                if ($after != $root) and (not ($after | str starts-with $"($root)/")) {
                    if ("_DIRENV_SANDBOX_EXIT_DIR_FILE" in $env) {
                        $after | save -f $env._DIRENV_SANDBOX_EXIT_DIR_FILE
                    }
                    exit 0
                }
            })
        }
    )

# --- OUTER shell mode: sandbox entry ---
} else {

    # Core sandbox logic: find envrc, check disabled state, launch sandbox
    # or fall back to plain direnv.
    def --env __direnv_sandbox_maybe_enter [] {
        if ("_DIRENV_SANDBOX_ACTIVE" in $env) { return }
        if not ("DIRENV_SANDBOX_CMD" in $env) { return }
        if ($env.DIRENV_SANDBOX_CMD | is-empty) { return }

        let project_root = (__direnv_sandbox_find_envrc)
        if ($project_root == null) {
            # No envrc found. If direnv was active from a disabled-sandbox dir, let it unload.
            if ("DIRENV_DIR" in $env) {
                __direnv_sandbox_apply_export
            }
            return
        }

        # Sandbox is disabled for this directory — run direnv directly (unsandboxed)
        if (__direnv_sandbox_is_disabled $project_root) {
            __direnv_sandbox_apply_export
            return
        }

        # Launch sandbox
        let resolved_root = (do { ^realpath $project_root } | complete).stdout | str trim
        let exit_file = (
            $env.XDG_RUNTIME_DIR? | default "/tmp"
            | path join $".direnv-sandbox-exit.($nu.pid)"
        )
        touch $exit_file
        let saved_pwd = $env.PWD

        $env._DIRENV_SANDBOX_ACTIVE = "1"
        $env._DIRENV_SANDBOX_ROOT = $resolved_root
        $env._DIRENV_SANDBOX_EXIT_DIR_FILE = $exit_file
        cd $resolved_root
        ^$env.DIRENV_SANDBOX_CMD nu

        # Cleanup after sandbox exits
        cd $saved_pwd
        hide-env _DIRENV_SANDBOX_ACTIVE
        hide-env _DIRENV_SANDBOX_ROOT

        if ($exit_file | path exists) {
            let exit_dir = (open $exit_file | str trim)
            if not ($exit_dir | is-empty) {
                cd $exit_dir
            }
        }
        rm -f $exit_file
        hide-env _DIRENV_SANDBOX_EXIT_DIR_FILE
    }

    # Register hooks
    # Prompt hook: handles initial startup, disabled-sandbox reloads, re-enable
    $env.config.hooks.pre_prompt = (
        $env.config.hooks.pre_prompt? | default [] | append {||
            __direnv_sandbox_maybe_enter
        }
    )

    # PWD change hook: catches cd, z, autojump, etc.
    let existing_pwd_hooks = ($env.config.hooks.env_change? | default {} | get -o PWD | default [])
    $env.config.hooks.env_change = (
        $env.config.hooks.env_change? | default {} | merge {
            PWD: ($existing_pwd_hooks | append {|before, after|
                __direnv_sandbox_maybe_enter
            })
        }
    )

    # Re-check after direnv allow/permit/grant in case we're already
    # in a project directory whose .envrc just became allowed.
    #
    # Do NOT capture stdout here: `direnv status`, `direnv edit`, etc. produce
    # multi-line output that must reach the terminal unchanged, and capturing
    # with `let` would also abort the wrapper on non-zero exit codes (which
    # `direnv status` uses to signal 'no .envrc in this tree').
    def --wrapped direnv [...args: string] {
        let direnv_bin = (__direnv_sandbox_direnv_bin)
        ^$direnv_bin ...$args
        # The actual sandbox entry for allow/permit/grant will happen on the
        # next prompt via the pre_prompt hook — no explicit call needed.
    }
}
