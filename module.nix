{ self }:
{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.programs.direnv.sandbox;
  direnv-cfg = config.programs.direnv;
  pkg = cfg.package;
  # Like lib.escapeShellArg but uses double quotes instead of single quotes
  # when quoting is needed, so that shell variables like $HOME in bind paths
  # (e.g. bind = [ "$HOME/.cache" ]) expand naturally at shell init time.
  escapeShellArgWithExpansion = arg:
    let string = toString arg;
    in if builtins.match "[[:alnum:],._+:@%/-]+" string != null
       then string
       else ''"'' + builtins.replaceStrings [ ''"'' "\\" ] [ ''\"'' "\\\\" ] string + ''"'';
  escapedCmd = lib.concatMapStringsSep " " escapeShellArgWithExpansion cfg.command;

  # Build the sbox package with module-configured overrides.
  sboxBase = (self.packages.${pkgs.system}.sbox).override {
    inherit (cfg) packages shellHook;
    env = cfg.environment;
  };

  # sbox with direnv-specific bind mounts:
  #  - direnv allow/deny database (read-only)
  #  - exit-dir file for CWD sync between inner and outer shell
  sboxDirenv = (self.packages.${pkgs.system}.sbox).override {
    inherit (cfg) packages shellHook;
    env = cfg.environment;
    bubblewrapArgs = [
      "--ro-bind-try" "$HOME/.local/share/direnv" "$HOME/.local/share/direnv"
      "--ro-bind-try" "$HOME/.local/share/direnv-sandbox" "$HOME/.local/share/direnv-sandbox"
      "--bind" "$_DIRENV_SANDBOX_EXIT_DIR_FILE" "$_DIRENV_SANDBOX_EXIT_DIR_FILE"
    ];
  };

  sboxArgs =
    (lib.concatMap (p: [ "--bind-try" p p ]) cfg.bind)
    ++ (lib.concatMap (p: [ "--ro-bind-try" p p ]) cfg.bindReadOnly)
    ++ (lib.concatMap (p: [ "--allow-port" (toString p) ]) cfg.allowedTCPPorts)
    ++ (lib.concatMap (p: [ "--expose-port" (toString p) ]) cfg.exposedTCPPorts)
    ++ (lib.optionals cfg.hostNetwork [ "--network" "host" ])
    ++ (lib.optionals (cfg.allowParent != "off") [ "--allow-parent" cfg.allowParent ]);

  escapedSboxArgs = lib.concatMapStringsSep " " escapeShellArgWithExpansion sboxArgs;

  # Standalone wrapper: bakes in module-configured args for manual use.
  sboxWrapped = pkgs.writeShellScriptBin "sbox" ''
    exec ${sboxBase}/bin/sbox ${escapedSboxArgs} "$@"
  '';

  # Direnv wrapper: same args, but includes direnv-specific bind mounts.
  sboxDirenvWrapped = pkgs.writeShellScriptBin "sbox" ''
    exec ${sboxDirenv}/bin/sbox ${escapedSboxArgs} "$@"
  '';
in
{
  options.programs.direnv.sandbox = {
    enable = lib.mkEnableOption "bubblewrap sandboxing for direnv sessions";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.system}.direnv-sandbox;
      description = "The direnv-sandbox package to use.";
    };

    command = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "${sboxDirenvWrapped}/bin/sbox" ];
      description = "The sandbox command and arguments. The shell to exec is appended after '--'.";
      example = [
        "bwrap"
        "--ro-bind"
        "/"
        "/"
        "--dev"
        "/dev"
        "--tmpfs"
        "/tmp"
      ];
    };

    bind = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Paths to bind-mount read-write inside the sandbox.";
      example = [ "$HOME/.cache" "/data" ];
    };

    bindReadOnly = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Paths to bind-mount read-only inside the sandbox.";
      example = [ "/opt/tools" ];
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

    hostNetwork = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Use host network instead of isolated network namespace.";
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

    sbox.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Add the sbox command to systemPackages. The wrapper inherits all
        sandbox options configured via this module (bind mounts, ports, etc.).
        Set to false to omit sbox from the system PATH.
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.sbox.enable {
      environment.systemPackages = [ pkgs.bubblewrap sboxWrapped ];
    })

    (lib.mkIf (direnv-cfg.enable && cfg.enable) {
      assertions = [
        {
          assertion = cfg.command != [ ];
          message = "programs.direnv.sandbox.command must be set when sandbox is enabled.";
        }
      ];

      environment.systemPackages = [ pkg ];

      # Disable direnv's own shell integration — we replace it with sandbox-aware hooks.
      # This only disables the eval "$(direnv hook <shell>)" lines, not other
      # interactiveShellInit content from other modules.
      programs.direnv = {
        enableBashIntegration = lib.mkForce false;
        enableZshIntegration = lib.mkForce false;
        enableFishIntegration = lib.mkForce false;
      };

      # Add sandbox-aware hook sourcing. These append normally to
      # interactiveShellInit without overriding other modules' content.
      programs.bash.interactiveShellInit = ''
        DIRENV_SANDBOX_CMD=(${escapedCmd})
        DIRENV_SANDBOX_DIRENV_BIN="${lib.getExe direnv-cfg.package}"
        source "${pkg}/share/direnv-sandbox/direnv-sandbox.bash"
      '';

      programs.zsh.interactiveShellInit = ''
        DIRENV_SANDBOX_CMD=(${escapedCmd})
        DIRENV_SANDBOX_DIRENV_BIN="${lib.getExe direnv-cfg.package}"
        source "${pkg}/share/direnv-sandbox/direnv-sandbox.zsh"
      '';

      # Fish: the direnv package ships share/fish/vendor_conf.d/direnv.fish
      # which auto-hooks direnv regardless of enableFishIntegration. Since
      # vendor_conf.d is sourced before interactiveShellInit, we erase its
      # functions here and replace them with our sandbox-aware hook.
      # This goes into /etc/fish/config.fish via the NixOS fish module,
      # which fish sources via its built-in NixOS support (even inside bwrap,
      # as long as /etc/fish is bind-mounted).
      programs.fish.interactiveShellInit = ''
        functions --erase __direnv_export_eval 2>/dev/null
        functions --erase __direnv_cd_hook 2>/dev/null
        set -gx DIRENV_SANDBOX_CMD ${escapedCmd}
        set -gx DIRENV_SANDBOX_DIRENV_BIN "${lib.getExe direnv-cfg.package}"
        source "${pkg}/share/direnv-sandbox/direnv-sandbox.fish"
      '';
    })
  ];
}
