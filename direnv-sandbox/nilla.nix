# Standalone nilla configuration for the direnv-sandbox sub-project.
# For a full setup (with sbox modules and tests), use the parent nilla.nix.
let
  tamal = import ../nix/tamal { };
  nilla = import tamal.nilla;
in
nilla.create [
  (
    { config }:
    let
      inherit (config.lib) systems;
    in
    {
      config = {
        lib.systems = [
          "x86_64-linux"
          "aarch64-linux"
        ];

        inputs = {
          nixpkgs = {
            src = tamal.nixpkgs;
            loader = "nixpkgs";
            settings.systems = systems;
          };
        };

        packages = {
          direnv-sandbox = {
            inherit systems;
            package = import ./direnv-sandbox.nix;
          };
        };
      };
    }
  )
]
