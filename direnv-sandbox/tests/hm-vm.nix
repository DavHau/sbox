# VM tests for the Home Manager module.
# Uses the same test script as vm.nix via vm-common.nix, but configures
# direnv-sandbox through home-manager instead of the NixOS module.
{ homeManagerModule, home-manager-src, shell ? "bash" }:
{ lib, testers, bash, zsh, fish, ... }:
let
  common = import ./vm-common.nix {
    inherit lib testers bash zsh fish shell;
    name = "direnv-sandbox-hm";
    nodeConfig = nodeConfig;
  };
  nodeConfig =
    { pkgs, ... }:
    {
      imports = [
        "${home-manager-src}/nixos"
      ];

      networking.useDHCP = false;

      users.users.alice = {
        isNormalUser = true;
        password = "foobar";
        shell = common.shellPkgs.${shell};
      };

      # Enable zsh/fish at the system level so the shell binary is available.
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

        programs.sbox = {
          bind = {
            "$HOME/.cache" = {};
          };
        };

        programs.direnv = {
          enable = true;
          sandbox.enable = true;
        };
      };

      # No zshrcWorkaround needed — HM manages .zshrc itself.
      system.activationScripts.createProject =
        common.mkProjectActivationScript { zshrcWorkaround = false; };
    };
in
common.test
