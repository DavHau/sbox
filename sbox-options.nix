# Option declarations for programs.sbox.
# This module can be imported independently to configure the sbox sandbox wrapper.
{ lib, pkgs }:
{
  enable = lib.mkEnableOption "the sbox bubblewrap sandbox wrapper";

  bind = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
      options.to = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "Destination path inside the sandbox. Defaults to the source path (attribute name).";
      };
    }));
    default = {};
    description = "Paths to bind-mount read-write inside the sandbox. Attribute names are source paths; set `to` to override the destination.";
    example = lib.literalExpression ''
      {
        "$HOME/.cache" = {};
        "/data" = {};
      }
    '';
  };

  bindReadOnly = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
      options.to = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "Destination path inside the sandbox. Defaults to the source path (attribute name).";
      };
    }));
    default = {};
    description = "Paths to bind-mount read-only inside the sandbox. Attribute names are source paths; set `to` to override the destination.";
    example = lib.literalExpression ''
      {
        "/opt/tools" = {};
        "$HOME/.ssh/id_ed25519_github".to = "$HOME/.ssh/id_ed25519";
      }
    '';
  };

  allowedTCPPorts = lib.mkOption {
    type = lib.types.listOf lib.types.port;
    default = [];
    description = "Host TCP ports to forward into the sandbox (sandbox can access host services).";
    example = [ 8080 5432 ];
  };

  exposedTCPPorts = lib.mkOption {
    type = lib.types.listOf lib.types.port;
    default = [];
    description = "Sandbox TCP ports to expose to the host (host can access sandbox services).";
    example = [ 3000 8000 ];
  };

  allowParent = lib.mkOption {
    type = lib.types.enum [ "off" "read" "write" ];
    default = "off";
    description = ''
      Mount the parent directory of the project inside the sandbox.
      "read" mounts it read-only, "write" mounts it read-write.
      The project directory itself is always mounted read-write regardless.
    '';
  };

  network = lib.mkOption {
    type = lib.types.enum [ "isolated" "blocked" "host" ];
    default = "isolated";
    description = ''
      Network mode for the sandbox.
      "isolated" — isolated namespace with user-mode networking via slirp4netns (default).
      "blocked" — isolated namespace with loopback only; all internet/LAN access
        is blocked, but --allow-port and --expose-port forwarding still works.
      "host" — use the host network directly (no isolation).
    '';
  };

  persist = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [];
    description = ''
      Paths to persist across sandbox sessions. Each path gets a
      per-project backing store in ''${XDG_STATE_HOME:-~/.local/state}/sbox/.

      Persist mounts are applied before explicit bind/bindReadOnly
      mounts, so you can overlay read-only files from the host on
      top. For example, persist $HOME/.claude for per-project state
      while binding credentials and settings read-only from the host.
    '';
    example = lib.literalExpression ''
      [
        "$HOME/.claude"   # per-project Claude Code state
      ]

      # Combine with bindReadOnly to keep host auth/settings:
      # bindReadOnly = {
      #   "$HOME/.claude/.credentials.json" = {};
      #   "$HOME/.claude/settings.json" = {};
      # };
    '';
  };

  shareHistory = lib.mkOption {
    type = lib.types.enum [ "host" "project" "off" ];
    default = "host";
    description = ''
      Shell history mode inside the sandbox.
      "host" — share the host's history files read-write (default).
      "project" — persist history per-project under $XDG_STATE_HOME/sbox/.
      "off" — no history persistence across sessions.
    '';
  };

  shareKnownHosts = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Share ~/.ssh/known_hosts (read-only) with the sandbox so SSH host verification works.";
  };

  allowAudio = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Allow audio inside the sandbox by passing through the host PipeWire socket.";
  };

  packages = lib.mkOption {
    type = lib.types.listOf lib.types.package;
    default = [];
    description = "Extra packages to make available on PATH inside the sandbox.";
    example = lib.literalExpression "[ pkgs.nodejs pkgs.python3 ]";
  };

  environment = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = {};
    description = "Environment variables to set inside the sandbox.";
    example = lib.literalExpression ''{ CUDA_HOME = "''${pkgs.cudaPackages.cudatoolkit}"; }'';
  };

  shellHook = lib.mkOption {
    type = lib.types.lines;
    default = "";
    description = ''
      Shell commands to run when entering the sandbox, before the
      interactive shell starts. If empty, the sandbox drops straight
      into the user's shell.
    '';
    example = ''
      if [ ! -d .venv ]; then
        python -m venv .venv --system-site-packages
      fi
      source .venv/bin/activate
    '';
  };
}
