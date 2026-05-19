# Node configuration for the direnv-sandbox NixOS-module test variant.
{ nixosModule, shell, shellPkg }:
{ pkgs, lib, ... }:
let
  mkProjectActivationScript = import ../project-activation.nix { inherit lib shell; };
in
{
  nodes.machine = {
    imports = [ nixosModule ];

    networking.useDHCP = false;

    users.users.alice = {
      isNormalUser = true;
      password = "foobar";
      shell = shellPkg;
    };

    programs.zsh.enable = shell == "zsh";
    programs.fish.enable = shell == "fish";

    programs.sbox = {
      bind = {
        "$HOME/.cache" = { };
      };
    };

    programs.direnv = {
      enable = true;
      sandbox.enable = true;
    };

    system.activationScripts.createProject =
      mkProjectActivationScript { zshrcWorkaround = true; };
  };
}
