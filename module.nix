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

  # sbox with direnv-specific bind mounts:
  #  - direnv allow/deny database (read-only)
  #  - exit-dir file for CWD sync between inner and outer shell
  sbox = (self.packages.${pkgs.system}.sbox).override {
    bubblewrapArgs = [
      "--ro-bind-try" "$HOME/.local/share/direnv" "$HOME/.local/share/direnv"
      "--ro-bind-try" "$HOME/.local/share/direnv-sandbox" "$HOME/.local/share/direnv-sandbox"
      "--bind" "$_DIRENV_SANDBOX_EXIT_DIR_FILE" "$_DIRENV_SANDBOX_EXIT_DIR_FILE"
    ];
  };
  sboxArgs =
    (lib.concatMap (p: [ "--bind" p p ]) cfg.bind)
    ++ (lib.concatMap (p: [ "--ro-bind" p p ]) cfg.bindReadOnly)
    ++ (lib.concatMap (p: [ "-p" (toString p) ]) cfg.allowedTCPPorts)
    ++ (lib.optionals cfg.hostNetwork [ "--network" "host" ])
    ++ (lib.optionals (cfg.allowParent != "off") [ "--allow-parent" cfg.allowParent ]);
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
      default = [ "${sbox}/bin/sbox" ] ++ sboxArgs;
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
      description = "Host TCP ports to forward into the sandbox.";
      example = [ 8080 5432 ];
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
  };

  config = lib.mkIf (direnv-cfg.enable && cfg.enable) {
    assertions = [
      {
        assertion = cfg.command != [ ];
        message = "programs.direnv.sandbox.command must be set when sandbox is enabled.";
      }
    ];

    environment.systemPackages = [ pkgs.bubblewrap pkg ];

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
  };
}
