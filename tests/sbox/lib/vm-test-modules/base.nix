# Base module for sbox VM tests: node config for the bare sbox package.
#
# Provides `machine` with the alice user, the bare sbox package + common
# packages, and the /home/alice/my project directory. The reusable testScript
# preamble (fast_retry, `project`, `sbox_run`, ...) lives in ./preamble.nix.
{ sbox, pythonWithPkgs }:
{ pkgs, lib, ... }:
{
  imports = [ ./preamble.nix ];

  nodes.machine = {
    # No networking needed — sbox creates its own isolated namespace.
    networking.useDHCP = false;

    users.users.alice = {
      isNormalUser = true;
      password = "foobar";
      shell = pkgs.bash;
    };

    environment.systemPackages = [
      sbox
      pythonWithPkgs
      pkgs.socat
      pkgs.curl
      pkgs.netcat.nc
      pkgs.iproute2
      pkgs.iputils
      pkgs.zsh
      pkgs.fish
    ];

    system.activationScripts.createProject = {
      deps = [ "users" ];
      text = ''
        mkdir -p "/home/alice/my project"
        chown -R alice:users "/home/alice/my project"
      '';
    };
  };
}
