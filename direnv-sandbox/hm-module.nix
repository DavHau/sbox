# Home Manager module for programs.direnv.sandbox — direnv integration with sbox.
# Imports the sbox HM module so programs.sbox options are available.
{ wrappers, sboxHmModule }:
{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.programs.direnv.sandbox;
  direnv-cfg = config.programs.direnv;
  sboxCfg = config.programs.sbox;
  pkg = cfg.package;

  sboxLib = import ../sbox-lib.nix {
    inherit wrappers lib pkgs;
    cfg = sboxCfg;
  };

  direnvLib = import ./direnv-sandbox-lib.nix {
    inherit wrappers lib pkgs;
    inherit sboxCfg;
    inherit (sboxLib) sboxArgs;
  };
in
{
  imports = [ sboxHmModule ];

  options.programs.direnv.sandbox = import ./options.nix {
    inherit lib pkgs;
    inherit (direnvLib) sboxDirenvWrapped;
  };

  config = lib.mkIf (direnv-cfg.enable && cfg.enable) {
    # Ensure sbox is enabled when direnv sandbox is enabled
    programs.sbox.enable = lib.mkDefault true;

    home.packages = [ pkg ];

    # Disable direnv's own shell integration — we replace it with sandbox-aware hooks.
    programs.direnv = {
      enableBashIntegration = lib.mkForce false;
      enableZshIntegration = lib.mkForce false;
      enableFishIntegration = lib.mkForce false;
    };

    programs.bash.initExtra = ''
      DIRENV_SANDBOX_CMD=("${lib.getExe cfg.sandboxCommand}")
      DIRENV_SANDBOX_DIRENV_BIN="${lib.getExe direnv-cfg.package}"
      source "${pkg}/share/direnv-sandbox/direnv-sandbox.bash"
    '';

    programs.zsh.initContent = ''
      DIRENV_SANDBOX_CMD=("${lib.getExe cfg.sandboxCommand}")
      DIRENV_SANDBOX_DIRENV_BIN="${lib.getExe direnv-cfg.package}"
      source "${pkg}/share/direnv-sandbox/direnv-sandbox.zsh"
    '';

    programs.fish.interactiveShellInit = ''
      functions --erase __direnv_export_eval 2>/dev/null
      functions --erase __direnv_cd_hook 2>/dev/null
      set -gx DIRENV_SANDBOX_CMD "${lib.getExe cfg.sandboxCommand}"
      set -gx DIRENV_SANDBOX_DIRENV_BIN "${lib.getExe direnv-cfg.package}"
      source "${pkg}/share/direnv-sandbox/direnv-sandbox.fish"
    '';
  };
}
