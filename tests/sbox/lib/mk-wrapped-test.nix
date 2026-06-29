# Factory for sbox NixOS VM tests that exercise the *module-wrapped* sbox.
#
# Usage:
#   import ./mk-wrapped-test.nix {
#     inherit wrappers;
#     name = "sbox-wrapped-command";
#     modules = [ ./wrapped-command.nix ];
#   }
#
# Builds a VM whose sbox comes from the real `programs.sbox` module (via
# wrappers.lib.wrapPackage), so regressions in the wrapper's argument
# forwarding are caught — something mk-test.nix (bare package) cannot do.
{ wrappers, name, modules }:
{ testers, python3, ... }:
let
  pythonWithPkgs = python3.withPackages (ps: [ ps.requests ]);
  sboxModule = import ../../../sbox-module.nix { inherit wrappers; };
in
testers.runNixOSTest {
  inherit name;
  imports = [
    ./vm-test-modules/snippets.nix
    (import ./vm-test-modules/wrapped-base.nix { inherit pythonWithPkgs sboxModule; })
  ] ++ modules;
}
