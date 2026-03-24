# Flake compatibility wrapper. The actual project entry point is nilla.nix.
{
  description = "Bubblewrap sandboxing for direnv sessions";

  # All inputs are managed by nixtamal via nilla.nix — no flake inputs needed.
  inputs = { };

  outputs =
    { self }:
    let
      nilla = import ./nilla.nix;
      systems = nilla.lib.systems;
      lib = nilla.inputs.nixpkgs.result.lib;
      forAllSystems =
        f:
        lib.genAttrs systems (system: f system);
    in
    {
      packages = forAllSystems (system:
        lib.mapAttrs (name: pkg: pkg.result.${system}) nilla.packages
        // { default = nilla.packages.direnv-sandbox.result.${system}; });

      nixosModules = nilla.modules.nixos or {};

      homeManagerModules = nilla.modules.homeManager or {};

      devShells = forAllSystems (system:
        lib.mapAttrs (name: shell: shell.result.${system}) nilla.shells);

      checks = forAllSystems (system:
        let
          pkgs = nilla.inputs.nixpkgs.result.${system};
          home-manager-src = nilla.inputs.home-manager.result;
        in
        {
          shellcheck =
            pkgs.runCommandLocal "shellcheck"
              {
                nativeBuildInputs = [ pkgs.shellcheck ];
              }
              ''
                cd ${./.}
                shellcheck direnv-sandbox.bash
                touch $out
              '';
          build = nilla.packages.direnv-sandbox.result.${system};
          fish-exit-glob = import ./tests/fish-exit-glob.nix { inherit pkgs; };
          vm-bash = import ./tests/vm.nix { inherit lib pkgs self; shell = "bash"; };
          vm-zsh = import ./tests/vm.nix { inherit lib pkgs self; shell = "zsh"; };
          vm-fish = import ./tests/vm.nix { inherit lib pkgs self; shell = "fish"; };
          vm-hm-bash = import ./tests/hm-vm.nix { inherit lib pkgs self home-manager-src; shell = "bash"; };
          vm-hm-zsh = import ./tests/hm-vm.nix { inherit lib pkgs self home-manager-src; shell = "zsh"; };
          vm-hm-fish = import ./tests/hm-vm.nix { inherit lib pkgs self home-manager-src; shell = "fish"; };
          vm-sbox = import ./tests/sbox-vm.nix { inherit lib pkgs self; };
          vm-audio = import ./tests/audio-vm.nix { inherit lib pkgs self; };
        });
    };
}
