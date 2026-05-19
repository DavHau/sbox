# Factory for direnv-sandbox NixOS VM test derivations.
#
# Usage:
#   (import ./lib/mk-test.nix {
#     name = "direnv-sandbox-bash";
#     shell = "bash";
#     nodeModule = import ./lib/vm-test-modules/node-nixos.nix { ... };
#     modules = [ ./allow-deny.nix ./symlink.nix ./entry-exit.nix ./off-on.nix ];
#   }) pkgsArgs
{ name, shell, nodeModule, modules }:
{ testers, ... }:
testers.runNixOSTest {
  inherit name;
  imports = [
    ./vm-test-modules/snippets.nix
    (import ./vm-test-modules/base.nix { inherit shell; })
    nodeModule
  ] ++ modules;
}
