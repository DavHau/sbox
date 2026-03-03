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
  escapedCmd = lib.escapeShellArgs cfg.command;

  # sbox with direnv-specific bind mounts:
  #  - direnv allow/deny database (read-only)
  #  - exit-dir file for CWD sync between inner and outer shell
  sbox = (self.packages.${pkgs.system}.sbox).override {
    bubblewrapArgs = [
      "--ro-bind-try" "$HOME/.local/share/direnv" "$HOME/.local/share/direnv"
      "--bind" "$_DIRENV_SANDBOX_EXIT_DIR_FILE" "$_DIRENV_SANDBOX_EXIT_DIR_FILE"
    ];
  };
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
      default = [ "${sbox}/bin/sbox" ];
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
  };

  config = lib.mkIf (direnv-cfg.enable && cfg.enable) {
    assertions = [
      {
        assertion = cfg.command != [ ];
        message = "programs.direnv.sandbox.command must be set when sandbox is enabled.";
      }
    ];

    environment.systemPackages = [ pkgs.bubblewrap ];

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
