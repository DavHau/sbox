# Base module for sbox VM tests that exercise the *module-wrapped* sbox.
#
# Unlike base.nix (which installs the bare sbox.nix package), this enables the
# real `programs.sbox` NixOS module, so the sbox on PATH is the one produced by
# wrappers.lib.wrapPackage with module-configured args (here a baked --persist)
# prepended. That is the exact code path users run, and the only one that can
# regress argument forwarding ("$@") independently of sbox.nix's own argv loop.
{ pythonWithPkgs, sboxModule }:
{ pkgs, lib, ... }:
{
  imports = [ ./preamble.nix ];

  nodes.machine = {
    imports = [ sboxModule ];

    # No networking needed — sbox creates its own isolated namespace.
    networking.useDHCP = false;

    users.users.alice = {
      isNormalUser = true;
      password = "foobar";
      shell = pkgs.bash;
    };

    # Enable the wrapper module. The baked --persist arg guarantees a non-empty
    # `args` list reaches wrappers.lib.wrapPackage — the case that previously
    # dropped the user's command instead of forwarding it.
    programs.sbox = {
      enable = true;
      persist = [ "/home/alice/.sbox-wrapped-state" ];
    };

    environment.systemPackages = [
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
