# Combined direnv-sandbox VM test — NixOS module variant.
#
# Modules are listed in reverse functional order: the NixOS module system
# concatenates `testScriptSnippets` in reverse import order, so listing
# `[off-on entry-exit symlink allow-deny]` here yields runtime order
# `[allow-deny, symlink, entry-exit, off-on]`, matching the original
# monolithic test flow.
{ nixosModule, shell }:
pkgsArgs@{ testers, bash, zsh, fish, nushell, ... }:
(import ./lib/mk-test.nix {
  name = "direnv-sandbox-${shell}";
  inherit shell;
  nodeModule = import ./lib/vm-test-modules/node-nixos.nix {
    inherit nixosModule shell;
    shellPkg = { inherit bash zsh fish nushell; }.${shell};
  };
  modules = [
    ./off-on.nix
    ./entry-exit.nix
    ./symlink.nix
    ./allow-deny.nix
  ];
}) pkgsArgs
