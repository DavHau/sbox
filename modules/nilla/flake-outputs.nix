# Nilla module that builds the full flake output attrset.
#
# This keeps flake.nix trivial: it just forwards `nilla.flakeOutputs`.
# All logic — packages, modules, shells, checks — lives here inside nilla's
# module system where we have access to `config`.
{ lib, config }:
let
  systems = config.lib.systems;
  nixpkgsLib = config.inputs.nixpkgs.result.lib;

  forAllSystems = f:
    nixpkgsLib.genAttrs systems (system: f system);
in
{
  options.flakeOutputs = lib.options.create {
    description = "Complete flake-compatible output attrset.";
    type = lib.types.raw;
    writable = false;
    default.value = {
      packages = forAllSystems (system:
        nixpkgsLib.mapAttrs (_: pkg: pkg.result.${system}) config.packages
        // { default = config.packages.sbox.result.${system}; });

      nixosModules = config.modules.nixos or {};
      homeManagerModules = config.modules.homeManager or {};

      devShells = forAllSystems (system:
        nixpkgsLib.mapAttrs (_: shell: shell.result.${system}) config.shells);

      checks = forAllSystems (system:
        nixpkgsLib.mapAttrs (_: check: check.result.${system}) config.checks);
    };
  };
}
