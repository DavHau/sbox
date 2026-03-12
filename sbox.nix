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
} @ attrs:
let
  bubblewrapArgs = builtins.concatStringsSep " " attrs.bubblewrapArgs or [];
  env =
    lib.concatStringsSep " "
    (lib.mapAttrsToList (k: v: "--setenv ${k} ${lib.escapeShellArg v}") attrs.env or {});
  customHosts = writeText "hosts" ''
    127.0.0.1 localhost
    ::1 localhost ip6-localhost ip6-loopback
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

    # USER="$(whoami)"

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
          UNIX-CONNECT:"''${__SANDBOX_WORK}/fwd-$port.sock" &
      done
    fi

    # Extra bind mounts passed from the outer script.
    EXTRA_BIND_ARGS=()
    if [ -n "''${__SANDBOX_BIND_ARGS:-}" ]; then
      read -ra EXTRA_BIND_ARGS <<< "$__SANDBOX_BIND_ARGS"
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

    echo "Starting bubblewrap sandbox in: $PROJECT_DIR"
    exec ${bubblewrap}/bin/bwrap \
      --die-with-parent \
      --unshare-pid \
      --unshare-ipc \
      --unshare-uts \
      --unshare-cgroup \
      --proc /proc \
      --dev /dev \
      "''${GPU_ARGS[@]}" \
      --tmpfs /tmp \
      --dir /var \
      --dir /run \
      --ro-bind-try /run/opengl-driver /run/opengl-driver \
      --ro-bind-try /run/opengl-driver-32 /run/opengl-driver-32 \
      "''${WAYLAND_ARGS[@]}" \
      --dir /usr/bin \
      --dir /bin \
      --dir /etc/ssl \
      --dir /etc/ssl/certs \
      --dir $HOME/.local/share \
      --dir $HOME/.config/fish/conf.d \
      --ro-bind ${fishPrompt} $HOME/.config/fish/conf.d/sandbox-prompt.fish \
      --ro-bind-try $HOME/.bashrc $HOME/.bashrc \
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
      --ro-bind-try $HOME/.claude $HOME/.claude \
      --ro-bind-try $HOME/.claude.json $HOME/.claude.json \
      --ro-bind-try $HOME/.pi $HOME/.pi \
      "''${PATH_BIND_ARGS[@]}" \
      "''${EDITOR_ARGS[@]}" \
      "''${EXTRA_BIND_ARGS[@]}" \
      ${bubblewrapArgs} \
      "''${PARENT_BIND_ARGS[@]}" \
      --bind "$PROJECT_DIR" "$PROJECT_DIR" \
      --chdir "$WORK_DIR" \
      --setenv HOME "$HOME" \
      --setenv USER $USER \
      --setenv SANDBOX 1 \
      --setenv PS1 "[sandbox] \w \$ " \
      --setenv PATH "${lib.makeBinPath packages}:$SANDBOX_PATH" \
      ${env} \
      "''${SANDBOX_ENTRYPOINT[@]}"
  '';

  # ---------------------------------------------------------------------------
  # Outer script: network namespace orchestrator (user-facing entry point)
  # ---------------------------------------------------------------------------
  outerScript = writeShellScriptBin "sbox" ''
    set -euo pipefail

    USE_HOST_NET=0
    ALLOW_PARENT="off"
    FORWARD_PORTS=()
    BIND_ARGS=()
    ARGS=()
    EXEC_CMD=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --network)
          if [ "''${2:-}" = "host" ]; then
            USE_HOST_NET=1
            shift 2
          else
            echo "Error: --network requires 'host' as argument" >&2
            exit 1
          fi
          ;;
        --allow-parent)
          ALLOW_PARENT="$2"
          shift 2
          ;;
        -p)
          FORWARD_PORTS+=("$2")
          shift 2
          ;;
        --bind)
          BIND_ARGS+=(--bind "$2" "$3")
          shift 3
          ;;
        --ro-bind)
          BIND_ARGS+=(--ro-bind "$2" "$3")
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

    # Build args for the inner script, passing through -- <cmd> if given
    INNER_ARGS=("''${ARGS[@]}")
    if [ ''${#EXEC_CMD[@]} -gt 0 ]; then
      INNER_ARGS+=(-- "''${EXEC_CMD[@]}")
    fi

    if [ "$USE_HOST_NET" = 1 ]; then
      __SANDBOX_BIND_ARGS="''${BIND_ARGS[*]}" \
      __SANDBOX_ALLOW_PARENT="$ALLOW_PARENT" \
        exec ${util-linux}/bin/unshare --user --map-root-user \
          -- ${innerScript} "''${INNER_ARGS[@]}"
    fi

    WORK=$(mktemp -d)

    cleanup() {
      kill "$SLIRP_PID" 2>/dev/null || true
      for pid in "''${SOCAT_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
      done
      rm -rf "$WORK"
    }
    trap cleanup EXIT

    # Start host-side port forwarders. Each listens on a UNIX socket
    # and forwards connections to the host's 127.0.0.1:PORT.
    SOCAT_PIDS=()
    for port in "''${FORWARD_PORTS[@]}"; do
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
      exec ${slirp4netns}/bin/slirp4netns --disable-host-loopback -c -6 -r 3 "$NS_PID" tap0 3>"$READY" >/dev/null 2>&1
    ) &
    SLIRP_PID=$!

    # Run the inner script inside a new user + network namespace.
    # Foreground so the TTY is preserved for the interactive shell.
    # unshare execs the inner script, so the process keeps the same PID
    # throughout: unshare → inner script → bwrap.
    __SANDBOX_PIDFILE="$PIDFILE" \
    __SANDBOX_READY="$READY" \
    __SANDBOX_RESOLV="$RESOLV" \
    __SANDBOX_FORWARD_PORTS="''${FORWARD_PORTS[*]}" \
    __SANDBOX_WORK="$WORK" \
    __SANDBOX_BIND_ARGS="''${BIND_ARGS[*]}" \
    __SANDBOX_ALLOW_PARENT="$ALLOW_PARENT" \
      ${util-linux}/bin/unshare --user --map-root-user --net \
        -- ${innerScript} "''${INNER_ARGS[@]}"
  '';

in
outerScript
