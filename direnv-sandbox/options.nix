# Direnv-specific option declarations for programs.direnv.sandbox.
# Imported by both the NixOS module and the Home Manager module.
{ lib, pkgs, sboxDirenvWrapped }:
{
  enable = lib.mkEnableOption "bubblewrap sandboxing for direnv sessions";

  package = lib.mkOption {
    type = lib.types.package;
    default = pkgs.callPackage ./direnv-sandbox.nix {};
    description = "The direnv-sandbox package to use.";
  };

  sandboxCommand = lib.mkOption {
    type = lib.types.package;
    default = sboxDirenvWrapped;
    description = "The sandbox wrapper package. It is invoked with the shell to exec appended after '--'.";
  };
}
