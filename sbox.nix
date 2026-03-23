# Sandboxed development environment using bubblewrap + slirp4netns.
#
# Two scripts are generated:
#
#   innerScript — sets up and exec's bwrap. Knows nothing about network
#     namespace creation. It inherits whatever network the caller provides
#     (--share-net) and adds the remaining isolation (pid, mount, ipc, etc.).
#
#   outerScript (the user-facing entry point) — creates an isolated network
#     namespace via unshare, starts slirp4netns to provide user-mode
#     networking, then runs innerScript inside that namespace.
#
# Why two scripts instead of one?
#   bwrap marks its child as non-dumpable, which prevents slirp4netns from
#   attaching via setns() from outside. By creating the network namespace
#   with unshare first (which slirp4netns CAN attach to), the inner bwrap
#   simply inherits the already-configured network via --share-net.
#
# Coordination between outer and inner via three env vars:
#   __SANDBOX_PIDFILE — inner writes $$ here so slirp4netns knows the
#                       namespace PID to attach to
#   __SANDBOX_READY   — inner polls until this file is non-empty, meaning
#                       slirp4netns has finished configuring tap0
#   __SANDBOX_RESOLV  — path to a resolv.conf pointing at slirp4netns's
#                       built-in DNS forwarder (10.0.2.3)
{
  lib,
  writeShellScript,
  writeShellScriptBin,
  bubblewrap,
  slirp4netns,
  util-linux,
  socat,
  cacert,
  coreutils,
  bash,
  writeText,
  # configuration of the wrapper
  packages ? [],
  bubblewrapArgs ? [],
  env ? {},
  shellHook ? "",
}:
let
  escapeArg = arg:
    let
      escaped = lib.replaceStrings [ "\\" ''"'' ] [ "\\\\" ''\"'' ] (toString arg);
    in ''"${escaped}"'';
  extraBwrapArgs = builtins.concatStringsSep " " (map escapeArg bubblewrapArgs);
  extraEnv =
    lib.concatStringsSep " "
    (lib.mapAttrsToList (k: v: "--setenv ${k} ${escapeArg v}") env);
  customHosts = writeText "hosts" ''
    127.0.0.1 localhost
    ::1 localhost ip6-localhost ip6-loopback
  '';
  bashPrompt = writeText "sandbox-prompt.bashrc" ''
    # Source the user's original bashrc if present
    [ -f "$HOME/.bashrc.orig" ] && . "$HOME/.bashrc.orig"
    # Prepend [sandbox] to whatever PS1 was configured
    PS1="[sandbox] ''${PS1#\\n}"
  '';
  fishPrompt = writeText "sandbox-prompt.fish" ''
    functions --copy fish_prompt __original_fish_prompt
    function fish_prompt
      echo -n -s (set_color green) '[sandbox]' (set_color normal) ' '
      __original_fish_prompt
    end
  '';
  entrypoint =
    if shellHook == "" then
      "$SHELL"
    else
      writeShellScript "sbox-entry" ''
        ${shellHook}
        exec "$SHELL"
      '';

  # ---------------------------------------------------------------------------
  # Inner script: bwrap sandbox
  # ---------------------------------------------------------------------------
  innerScript = writeShellScript "sbox-inner" ''
    set -euo pipefail

    # Resolve a command to an absolute path.
    # Handles both absolute paths (/bin/bash) and bare names (bash).
    resolve_cmd() {
      local cmd="$1"
      if [[ "$cmd" == /* ]]; then
        realpath "$cmd"
      else
        command -v "$cmd"
      fi
    }

    PROJECT_DIR="$(pwd)"
    EXEC_CMD=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --)
          shift
          EXEC_CMD=("$@")
          break
          ;;
        *)
          PROJECT_DIR="$(realpath -s "$1")"
          if [ ! -d "$PROJECT_DIR" ]; then
            echo "Error: Directory '$1' does not exist"
            exit 1
          fi
          shift
          ;;
      esac
    done

    SHELL=$(resolve_cmd "$SHELL")

    EDITOR_ARGS=()
    if [ -n "''${EDITOR:-}" ]; then
      EDITOR=$(resolve_cmd "$EDITOR")
      EDITOR_ARGS+=(--setenv EDITOR "$EDITOR")
    fi

    # Bind-mount GPU device nodes (NVIDIA + DRI) if present
    GPU_ARGS=()
    for dev in /dev/nvidia* /dev/nvidia-caps/* /dev/dri/*; do
      [ -e "$dev" ] && GPU_ARGS+=(--dev-bind-try "$dev" "$dev")
    done

    # Wayland socket forwarding (requires both XDG_RUNTIME_DIR and WAYLAND_DISPLAY)
    WAYLAND_ARGS=()
    if [ -n "''${XDG_RUNTIME_DIR:-}" ]; then
      WAYLAND_ARGS+=(--dir "$XDG_RUNTIME_DIR")
      if [ -n "''${WAYLAND_DISPLAY:-}" ]; then
        WAYLAND_ARGS+=(--ro-bind-try "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY")
      fi
    fi

    # Audio: bind PipeWire, PulseAudio sockets and ALSA device nodes.
    AUDIO_ARGS=()
    if [ "''${__SANDBOX_USE_AUDIO:-0}" = 1 ]; then
      if [ -n "''${XDG_RUNTIME_DIR:-}" ]; then
        AUDIO_ARGS+=(--ro-bind-try "$XDG_RUNTIME_DIR/pipewire-0" "$XDG_RUNTIME_DIR/pipewire-0")
        AUDIO_ARGS+=(--ro-bind-try "$XDG_RUNTIME_DIR/pulse/native" "$XDG_RUNTIME_DIR/pulse/native")
      fi
      AUDIO_ARGS+=(--dev-bind-try /dev/snd /dev/snd)
    fi

    # Mount all directories from the host PATH into the sandbox
    PATH_BIND_ARGS=()
    SANDBOX_PATH=""
    IFS=: read -ra PATH_DIRS <<< "$PATH"
    declare -A SEEN_DIRS
    for dir in "''${PATH_DIRS[@]}"; do
      [ -d "$dir" ] || continue
      SANDBOX_PATH="''${SANDBOX_PATH:+$SANDBOX_PATH:}$dir"
      # Mount the parent of bin/sbin dirs (e.g., /foo/bin -> /foo)
      mount_dir="''${dir%/bin}"
      mount_dir="''${mount_dir%/sbin}"
      [ -z "''${SEEN_DIRS[$mount_dir]:-}" ] || continue
      SEEN_DIRS[$mount_dir]=1
      # Skip dirs already covered by --ro-bind /nix /nix
      [[ "$mount_dir" == /nix/store/* ]] && continue
      PATH_BIND_ARGS+=(--ro-bind "$mount_dir" "$mount_dir")
    done

    # Signal our PID and wait for slirp4netns to finish configuring
    # the network. If the env vars aren't set, we're running standalone
    # without the outer wrapper — skip the handshake.
    if [ -n "''${__SANDBOX_PIDFILE:-}" ]; then
      echo $$ > "$__SANDBOX_PIDFILE"
      while [ ! -s "$__SANDBOX_READY" ]; do sleep 0.1; done
    fi

    RESOLV="''${__SANDBOX_RESOLV:-/etc/resolv.conf}"

    # Start port forwarders inside the namespace (before bwrap).
    # Each listens on 127.0.0.1:PORT and connects to a UNIX socket
    # bridged to the host's 127.0.0.1:PORT by the outer script.
    if [ -n "''${__SANDBOX_FORWARD_PORTS:-}" ]; then
      read -ra FWD_PORTS <<< "$__SANDBOX_FORWARD_PORTS"
      for port in "''${FWD_PORTS[@]}"; do
        ${socat}/bin/socat \
          TCP4-LISTEN:"$port",bind=127.0.0.1,fork,reuseaddr \
          UNIX-CONNECT:"''${__SANDBOX_WORK}/fwd-$port.sock" >/dev/null 2>&1 &
      done
    fi

    # Extra bind mounts passed from the outer script via null-delimited file.
    EXTRA_BIND_ARGS=()
    if [ -n "''${__SANDBOX_BIND_ARGS_FILE:-}" ] && [ -s "$__SANDBOX_BIND_ARGS_FILE" ]; then
      while IFS= read -r -d "" arg; do
        EXTRA_BIND_ARGS+=("$arg")
      done < "$__SANDBOX_BIND_ARGS_FILE"
      rm -f "$__SANDBOX_BIND_ARGS_FILE"
    fi

    # Sort extra bind mounts by destination path so that parent mounts
    # are processed before children. This lets child mounts (e.g. an
    # --ro-bind on a subdir) correctly overlay parent mounts (e.g. a
    # --bind from --persist) regardless of argument order.
    if [ ''${#EXTRA_BIND_ARGS[@]} -gt 3 ]; then
      SORTED_BIND_ARGS=()
      while IFS=$'\t' read -r dest flag src; do
        SORTED_BIND_ARGS+=("$flag" "$src" "$dest")
      done < <(
        for ((i = 0; i < ''${#EXTRA_BIND_ARGS[@]}; i += 3)); do
          printf '%s\t%s\t%s\n' "''${EXTRA_BIND_ARGS[i+2]}" "''${EXTRA_BIND_ARGS[i]}" "''${EXTRA_BIND_ARGS[i+1]}"
        done | sort -t$'\t' -k1,1
      )
      EXTRA_BIND_ARGS=("''${SORTED_BIND_ARGS[@]}")
    fi

    # Parent directory bind mount (read-only or read-write).
    # Placed before the project dir mount so that bwrap's --bind for the
    # project itself overlays it with full read-write access.
    PARENT_BIND_ARGS=()
    ALLOW_PARENT="''${__SANDBOX_ALLOW_PARENT:-off}"
    if [[ "$ALLOW_PARENT" != "off" ]]; then
      PARENT_DIR="$(dirname "$PROJECT_DIR")"
      if [[ "$ALLOW_PARENT" == "write" ]]; then
        PARENT_BIND_ARGS+=(--bind "$PARENT_DIR" "$PARENT_DIR")
      else
        PARENT_BIND_ARGS+=(--ro-bind "$PARENT_DIR" "$PARENT_DIR")
      fi
    fi

    # Use explicit command if given (-- <cmd>), otherwise the configured entrypoint
    if [ ''${#EXEC_CMD[@]} -gt 0 ]; then
      SANDBOX_ENTRYPOINT=("''${EXEC_CMD[@]}")
    else
      SANDBOX_ENTRYPOINT=(${entrypoint})
    fi

    # If the real cwd is under PROJECT_DIR, start there; otherwise PROJECT_DIR.
    WORK_DIR="$(pwd)"
    case "$WORK_DIR" in
      "$PROJECT_DIR"|"$PROJECT_DIR"/*) ;;
      *) WORK_DIR="$PROJECT_DIR" ;;
    esac

    # Restore the original UID/GID inside the sandbox so the user
    # identity is preserved across the user-namespace boundary.
    ID_ARGS=()
    if [ -n "''${__SANDBOX_UID:-}" ]; then
      ID_ARGS+=(--unshare-user --uid "$__SANDBOX_UID" --gid "$__SANDBOX_GID")
    fi

    echo "Starting bubblewrap sandbox in: $PROJECT_DIR"
    exec ${bubblewrap}/bin/bwrap \
      --die-with-parent \
      --unshare-pid \
      --unshare-ipc \
      --unshare-uts \
      --unshare-cgroup \
      "''${ID_ARGS[@]}" \
      --proc /proc \
      --dev /dev \
      "''${GPU_ARGS[@]}" \
      --tmpfs /tmp \
      --dir /var \
      --dir /run \
      --ro-bind-try /run/opengl-driver /run/opengl-driver \
      --ro-bind-try /run/opengl-driver-32 /run/opengl-driver-32 \
      "''${WAYLAND_ARGS[@]}" \
      "''${AUDIO_ARGS[@]}" \
      --dir /usr/bin \
      --dir /bin \
      --dir /etc/ssl \
      --dir /etc/ssl/certs \
      --dir $HOME/.local/share \
      --dir $HOME/.config/fish/conf.d \
      --ro-bind ${fishPrompt} $HOME/.config/fish/conf.d/sandbox-prompt.fish \
      --ro-bind-try $HOME/.bashrc $HOME/.bashrc.orig \
      --ro-bind ${bashPrompt} $HOME/.bashrc \
      --ro-bind-try $HOME/.bash_profile $HOME/.bash_profile \
      --ro-bind-try $HOME/.profile $HOME/.profile \
      --ro-bind-try $HOME/.zshrc $HOME/.zshrc \
      --ro-bind-try $HOME/.zshenv $HOME/.zshenv \
      --ro-bind-try $HOME/.zprofile $HOME/.zprofile \
      --ro-bind-try $HOME/.config/fish/config.fish $HOME/.config/fish/config.fish \
      --ro-bind-try /etc/bashrc /etc/bashrc \
      --ro-bind-try /etc/bash.bashrc /etc/bash.bashrc \
      --ro-bind-try /etc/zshrc /etc/zshrc \
      --ro-bind-try /etc/zsh /etc/zsh \
      --ro-bind-try /etc/fish /etc/fish \
      --ro-bind-try /etc/fonts /etc/fonts \
      --ro-bind-try /etc/alsa /etc/alsa \
      --ro-bind /etc/nix /etc/nix \
      --ro-bind-try /etc/static /etc/static \
      --ro-bind "$RESOLV" /etc/resolv.conf \
      --ro-bind ${customHosts} /etc/hosts \
      --ro-bind ${cacert}/etc/ssl/certs/ca-bundle.crt /etc/ssl/certs/ca-bundle.crt \
      --symlink /etc/ssl/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt \
      --symlink ${coreutils}/bin/env /usr/bin/env \
      --symlink ${bash}/bin/bash /bin/sh \
      --ro-bind /nix /nix \
      --ro-bind /etc/passwd /etc/passwd \
      --ro-bind /etc/group /etc/group \
      --ro-bind "$SHELL" "$SHELL" \
      --ro-bind-try $HOME/.gitconfig $HOME/.gitconfig \
      --ro-bind-try $HOME/.config/git $HOME/.config/git \
      --ro-bind-try /etc/gitconfig /etc/gitconfig \
      "''${PATH_BIND_ARGS[@]}" \
      "''${EDITOR_ARGS[@]}" \
      "''${EXTRA_BIND_ARGS[@]}" \
      ${extraBwrapArgs} \
      "''${PARENT_BIND_ARGS[@]}" \
      --bind "$PROJECT_DIR" "$PROJECT_DIR" \
      --chdir "$WORK_DIR" \
      --setenv HOME "$HOME" \
      --setenv USER $USER \
      --setenv SANDBOX 1 \
      --setenv PATH "${lib.makeBinPath packages}:$SANDBOX_PATH" \
      ${extraEnv} \
      "''${SANDBOX_ENTRYPOINT[@]}"
  '';

  # ---------------------------------------------------------------------------
  # Outer script: network namespace orchestrator (user-facing entry point)
  # ---------------------------------------------------------------------------
  outerScript = writeShellScriptBin "sbox" ''
    set -euo pipefail

    USE_HOST_NET=0
    USE_AUDIO=0
    HISTORY_MODE="host"
    ALLOW_PARENT="off"
    HOST_PORTS=()
    SANDBOX_PORTS=()
    BIND_ARGS=()
    PERSIST_ARGS=()
    ARGS=()
    EXEC_CMD=()
    usage() {
      cat <<USAGE
Usage: sbox [OPTIONS] [DIR] [-- COMMAND...]

Launch an isolated development sandbox using bubblewrap and slirp4netns.

If DIR is given, it is mounted read-write as the project directory inside the
sandbox. Defaults to the current working directory.

If COMMAND is given (after --), it is executed inside the sandbox instead of
an interactive shell.

Options:
  --network host          Use the host network instead of an isolated namespace
  --allow-parent MODE     Mount the parent of the project directory inside the
                          sandbox. MODE is "ro" (read-only) or "rw" (read-write)
  --allow-port, -p PORT   Forward a host TCP port into the sandbox
  --expose-port PORT      Expose a sandbox TCP port to the host
  --bind SRC DEST         Bind-mount SRC to DEST (read-write) inside the sandbox
  --bind-try SRC DEST     Like --bind, but skip silently if SRC does not exist
  --ro-bind SRC DEST      Bind-mount SRC to DEST (read-only) inside the sandbox
  --ro-bind-try SRC DEST  Like --ro-bind, but skip silently if SRC does not exist
  --persist PATH          Persist PATH across sandbox sessions. Writes are
                          stored in \$XDG_STATE_HOME (~/.local/state) keyed by
                          project directory hash. Can be repeated.
  --history MODE          Shell history mode: "host" (shared, default), "project"
                          (per-project), or "off" (no persistence)
  --audio                 Allow audio playback and capture (PipeWire passthrough)
  -h, --help              Show this help message

Examples:
  sbox                    Sandbox the current directory
  sbox ~/projects/myapp   Sandbox a specific directory
  sbox -p 5432            Allow access to host PostgreSQL
  sbox --expose-port 8080 Expose sandbox port 8080 to the host
  sbox -- make build      Run a command inside the sandbox
USAGE
      exit 0
    }

    while [ $# -gt 0 ]; do
      case "$1" in
        -h|--help)
          usage
          ;;
        --network)
          if [ "''${2:-}" = "host" ]; then
            USE_HOST_NET=1
            shift 2
          else
            echo "Error: --network requires 'host' as argument" >&2
            exit 1
          fi
          ;;
        --persist)
          PERSIST_ARGS+=("$2")
          shift 2
          ;;
        --audio)
          USE_AUDIO=1
          shift
          ;;
        --history)
          case "''${2:-}" in
            host|project|off) HISTORY_MODE="$2" ;;
            *) echo "Error: --history requires 'host', 'project', or 'off'" >&2; exit 1 ;;
          esac
          shift 2
          ;;
        --allow-parent)
          ALLOW_PARENT="$2"
          shift 2
          ;;
        --allow-port|-p)
          HOST_PORTS+=("$2")
          shift 2
          ;;
        --expose-port)
          SANDBOX_PORTS+=("$2")
          shift 2
          ;;
        --bind)
          BIND_ARGS+=(--bind "$2" "$3")
          shift 3
          ;;
        --bind-try)
          BIND_ARGS+=(--bind-try "$2" "$3")
          shift 3
          ;;
        --ro-bind)
          BIND_ARGS+=(--ro-bind "$2" "$3")
          shift 3
          ;;
        --ro-bind-try)
          BIND_ARGS+=(--ro-bind-try "$2" "$3")
          shift 3
          ;;
        --)
          shift
          EXEC_CMD=("$@")
          break
          ;;
        *)
          ARGS+=("$1")
          shift
          ;;
      esac
    done

    # Per-project state directory, computed lazily for --persist and --history project.
    _project_state_dir() {
      if [ -z "''${_PROJECT_STATE_DIR:-}" ]; then
        local project_dir="''${ARGS[0]:-$(pwd)}"
        project_dir="$(realpath -s "$project_dir")"
        local hash
        hash="$(printf '%s\n' "$project_dir" | sha256sum | cut -d' ' -f1)"
        _PROJECT_STATE_DIR="''${XDG_STATE_HOME:-$HOME/.local/state}/sbox/$hash"
      fi
      printf '%s' "$_PROJECT_STATE_DIR"
    }

    # Resolve persist paths into bind mounts backed by XDG state dir.
    if [ ''${#PERSIST_ARGS[@]} -gt 0 ]; then
      for p in "''${PERSIST_ARGS[@]}"; do
        rel="''${p#/}"
        backing="$(_project_state_dir)/$rel"
        [ -d "$backing" ] || mkdir -p "$backing"
        BIND_ARGS+=(--bind "$backing" "$p")
      done
    fi

    # Shell history: bind-mount history files into the sandbox.
    # "host"    — share host files directly (read-write)
    # "project" — per-project backing store under XDG state dir
    # "off"     — no history mounts
    HISTORY_FILES=(
      "$HOME/.bash_history"
      "$HOME/.zsh_history"
      "$HOME/.local/share/fish/fish_history"
    )
    if [ "$HISTORY_MODE" = "host" ]; then
      for hf in "''${HISTORY_FILES[@]}"; do
        BIND_ARGS+=(--bind-try "$hf" "$hf")
      done
    elif [ "$HISTORY_MODE" = "project" ]; then
      for hf in "''${HISTORY_FILES[@]}"; do
        rel="''${hf#/}"
        backing="$(_project_state_dir)/$rel"
        backing_dir="$(dirname "$backing")"
        [ -d "$backing_dir" ] || mkdir -p "$backing_dir"
        [ -f "$backing" ] || touch "$backing"
        BIND_ARGS+=(--bind "$backing" "$hf")
      done
    fi

    # Build args for the inner script, passing through -- <cmd> if given
    INNER_ARGS=("''${ARGS[@]}")
    if [ ''${#EXEC_CMD[@]} -gt 0 ]; then
      INNER_ARGS+=(-- "''${EXEC_CMD[@]}")
    fi

    ORIG_UID=$(id -u)
    ORIG_GID=$(id -g)

    # Common env vars passed to the inner script in both network modes.
    # Bind args are passed via a null-delimited file to preserve paths with spaces.
    BIND_ARGS_FILE=$(mktemp)
    if [ ''${#BIND_ARGS[@]} -gt 0 ]; then
      printf '%s\0' "''${BIND_ARGS[@]}" > "$BIND_ARGS_FILE"
    fi
    export __SANDBOX_BIND_ARGS_FILE="$BIND_ARGS_FILE"
    export __SANDBOX_ALLOW_PARENT="$ALLOW_PARENT"
    export __SANDBOX_UID="$ORIG_UID"
    export __SANDBOX_GID="$ORIG_GID"
    export __SANDBOX_USE_AUDIO="$USE_AUDIO"

    if [ "$USE_HOST_NET" = 1 ]; then
      exec ${util-linux}/bin/unshare --user --map-root-user \
        -- ${innerScript} "''${INNER_ARGS[@]}"
    fi

    WORK=$(mktemp -d)

    cleanup() {
      kill "$SLIRP_PID" 2>/dev/null || :
      for pid in "''${SOCAT_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || :
      done
      rm -rf "$WORK"
    }
    trap cleanup EXIT

    # Start host-side port forwarders. Each listens on a UNIX socket
    # and forwards connections to the host's 127.0.0.1:PORT.
    SOCAT_PIDS=()
    for port in "''${HOST_PORTS[@]}"; do
      ${socat}/bin/socat \
        UNIX-LISTEN:"$WORK/fwd-$port.sock",fork \
        TCP4:127.0.0.1:"$port" &
      SOCAT_PIDS+=($!)
    done

    PIDFILE="$WORK/ns-pid"
    READY="$WORK/ready"
    RESOLV="$WORK/resolv.conf"

    # slirp4netns provides a built-in DNS forwarder at 10.0.2.3. Use it
    # instead of the host's resolv.conf, which typically points at
    # 127.0.0.53 (systemd-resolved) — unreachable from an isolated namespace.
    echo "nameserver 10.0.2.3" > "$RESOLV"

    # Background helper: polls for the inner script's PID, then starts
    # slirp4netns. `exec` replaces the subshell so SLIRP_PID can kill
    # slirp4netns directly during cleanup.
    #   -c : auto-configure tap0 (10.0.2.100/24, gateway 10.0.2.2)
    #   -6 : enable IPv6 (fd00::100/64, DNS at fd00::3)
    #   -r 3 : write "1" to FD 3 when the interface is ready, which lands
    #          in READY to unblock the inner script
    (
      while [ ! -s "$PIDFILE" ]; do sleep 0.1; done
      NS_PID=$(cat "$PIDFILE")
      exec ${slirp4netns}/bin/slirp4netns --disable-host-loopback -c -6 -r 3 -a "$WORK/slirp-api.sock" "$NS_PID" tap0 3>"$READY" >/dev/null 2>&1
    ) &
    SLIRP_PID=$!

    # Expose sandbox ports to the host via slirp4netns host forwarding.
    # Waits for slirp4netns to be ready, then adds forwarding rules via
    # the API socket. Each rule maps host 127.0.0.1:PORT → sandbox 10.0.2.100:PORT.
    if [ ''${#SANDBOX_PORTS[@]} -gt 0 ]; then
      (
        while [ ! -s "$READY" ]; do sleep 0.1; done
        for port in "''${SANDBOX_PORTS[@]}"; do
          printf '{"execute":"add_hostfwd","arguments":{"proto":"tcp","host_addr":"127.0.0.1","host_port":%d,"guest_addr":"10.0.2.100","guest_port":%d}}\n' "$port" "$port" \
            | ${socat}/bin/socat - UNIX-CONNECT:"$WORK/slirp-api.sock"
        done
      ) &
    fi

    # Run the inner script inside a new user + network namespace.
    # Foreground so the TTY is preserved for the interactive shell.
    # unshare execs the inner script, so the process keeps the same PID
    # throughout: unshare → inner script → bwrap.
    export __SANDBOX_PIDFILE="$PIDFILE"
    export __SANDBOX_READY="$READY"
    export __SANDBOX_RESOLV="$RESOLV"
    export __SANDBOX_FORWARD_PORTS="''${HOST_PORTS[*]}"
    export __SANDBOX_WORK="$WORK"
    ${util-linux}/bin/unshare --user --map-root-user --net \
      -- ${innerScript} "''${INNER_ARGS[@]}"
  '';

in
outerScript
