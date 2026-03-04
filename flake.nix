{
  description = "Bubblewrap sandboxing for direnv sessions";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs [
          "x86_64-linux"
          "aarch64-linux"
        ] (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: {
        default = self.packages.${pkgs.system}.direnv-sandbox;
        sbox = pkgs.callPackage ./sbox.nix { };
        direnv-sandbox = pkgs.stdenvNoCC.mkDerivation {
          pname = "direnv-sandbox";
          version = "0.1.0";
          src = ./.;
          installPhase = ''
            mkdir -p $out/share/direnv-sandbox
            mkdir -p $out/bin
            cp direnv-sandbox.bash $out/share/direnv-sandbox/
            cp direnv-sandbox.zsh $out/share/direnv-sandbox/
            cp direnv-sandbox.fish $out/share/direnv-sandbox/
            cp direnv-sandbox-cmd.bash $out/bin/direnv-sandbox
            chmod +x $out/bin/direnv-sandbox
          '';
        };
      });

      nixosModules.default = self.nixosModules.direnv-sandbox;
      nixosModules.direnv-sandbox = import ./module.nix { inherit self; };

      checks = forAllSystems (pkgs: {
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
        build = self.packages.${pkgs.system}.direnv-sandbox;
        vm-bash = import ./tests/vm.nix { inherit lib pkgs self; shell = "bash"; };
        vm-zsh = import ./tests/vm.nix { inherit lib pkgs self; shell = "zsh"; };
        vm-fish = import ./tests/vm.nix { inherit lib pkgs self; shell = "fish"; };
      });
    };
}
