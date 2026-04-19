# Combined sbox VM test: runs all subtest groups in a single VM.
{ sboxPackage }:
import ./lib/mk-test.nix {
  inherit sboxPackage;
  name = "sbox";
  modules = [
    ./command-syntax.nix
    ./basic-sandbox.nix
    ./ports.nix
    ./persist.nix
    ./network.nix
    ./history.nix
    ./misc.nix
  ];
}
