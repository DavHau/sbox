# Factory for sbox NixOS VM test derivations.
#
# Usage:
#   import ./mk-test.nix {
#     sboxPackage = import ../../sbox.nix;
#     name = "sbox-ports";
#     modules = [ ./ports.nix ];
#   }
#
# Returns a function compatible with the nilla `check` slot.
{ sboxPackage, name, modules }:
{ testers, python3, callPackage, ... }:
let
  sbox = callPackage sboxPackage { };
  pythonWithPkgs = python3.withPackages (ps: [ ps.requests ]);
in
testers.runNixOSTest {
  inherit name;
  imports = [
    ./vm-test-modules/snippets.nix
    (import ./vm-test-modules/base.nix { inherit sbox pythonWithPkgs; })
  ] ++ modules;
}
