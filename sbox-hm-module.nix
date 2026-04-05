# Home Manager module for programs.sbox — the bubblewrap sandbox wrapper.
# Can be imported independently of direnv-sandbox.
{ wrappers }:
{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.programs.sbox;
  sboxLib = import ./sbox-lib.nix {
    inherit wrappers lib pkgs cfg;
  };
in
{
  options.programs.sbox = import ./sbox-options.nix {
    inherit lib pkgs;
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ pkgs.bubblewrap sboxLib.sboxWrapped ];
  };
}
