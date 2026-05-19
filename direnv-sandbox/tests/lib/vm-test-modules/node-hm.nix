# Node configuration for the direnv-sandbox Home-Manager-module test variant.
{ homeManagerModule, home-manager-src, shell, shellPkg }:
{ pkgs, lib, ... }:
let
  mkProjectActivationScript = import ../project-activation.nix { inherit lib shell; };
in
{
  nodes.machine = {
    imports = [
      "${home-manager-src}/nixos"
    ];

    networking.useDHCP = false;

    users.users.alice = {
      isNormalUser = true;
      password = "foobar";
      shell = shellPkg;
    };

    # Enable zsh/fish at the system level so the shell binary is available.
    # nushell needs no system-level enable; the binary in users.users.alice.shell is sufficient.
    programs.zsh.enable = shell == "zsh";
    programs.fish.enable = shell == "fish";

    # Configure direnv-sandbox via Home Manager instead of the NixOS module.
    home-manager.useGlobalPkgs = true;
    home-manager.useUserPackages = true;
    home-manager.users.alice = {
      imports = [ homeManagerModule ];

      home.stateVersion = "24.11";

      programs.bash.enable = shell == "bash";
      programs.zsh.enable = shell == "zsh";
      programs.fish.enable = shell == "fish";
      programs.nushell.enable = shell == "nushell";

      programs.sbox = {
        bind = {
          "$HOME/.cache" = { };
        };
      };

      programs.direnv = {
        enable = true;
        sandbox.enable = true;
      };
    };

    # No zshrcWorkaround needed — HM manages .zshrc itself.
    system.activationScripts.createProject =
      mkProjectActivationScript { zshrcWorkaround = false; };
  };
}
