# Combined direnv-sandbox VM test — Home Manager module variant.
#
# See ./all-nixos.nix for the module-order rationale.
{ homeManagerModule, home-manager-src, shell }:
pkgsArgs@{ testers, bash, zsh, fish, nushell, ... }:
(import ./lib/mk-test.nix {
  name = "direnv-sandbox-hm-${shell}";
  inherit shell;
  nodeModule = import ./lib/vm-test-modules/node-hm.nix {
    inherit homeManagerModule home-manager-src shell;
    shellPkg = { inherit bash zsh fish nushell; }.${shell};
  };
  modules = [
    ./off-on.nix
    ./entry-exit.nix
    ./symlink.nix
    ./allow-deny.nix
  ];
}) pkgsArgs
