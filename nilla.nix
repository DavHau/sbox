let
  tamal = import ./nix/tamal { };
  nilla = import tamal.nilla;
in
nilla.create [
  ./modules/nilla/checks.nix
  ./modules/nilla/flake-outputs.nix
  (
    { config }:
    let
      inherit (config.lib) systems;
      wrappers = config.inputs.wrappers.result;
      sboxModule = import ./sbox-module.nix { inherit wrappers; };
      sboxHmModule = import ./sbox-hm-module.nix { inherit wrappers; };
      nixosModule = import ./direnv-sandbox/module.nix { inherit wrappers sboxModule; };
      homeManagerModule = import ./direnv-sandbox/hm-module.nix { inherit wrappers; sboxHmModule = sboxHmModule; };
      home-manager-src = config.inputs.home-manager.result;
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

          wrappers = {
            src = tamal.wrappers;
            loader = "legacy";
            settings.args = {
              pkgs = {
                lib = config.inputs.nixpkgs.result.lib;
              };
            };
          };

          home-manager = {
            src = tamal.home-manager;
            loader = "raw";
          };

          nilla-cli = {
            src = tamal.nilla-cli;
            loader = "nilla";
          };
        };

        packages = {
          sbox = {
            inherit systems;
            package = import ./sbox.nix;
          };

          direnv-sandbox = {
            inherit systems;
            package = import ./direnv-sandbox/direnv-sandbox.nix;
          };
        };

        shells.default = {
          inherit systems;
          shell =
            {
              mkShell,
              bubblewrap,
              slirp4netns,
              system,
              ...
            }:
            let
              nilla-cli = config.inputs.nilla-cli.result.packages.nilla-cli.result.${system};
            in
            mkShell {
              packages = [
                bubblewrap
                slirp4netns
                nilla-cli
              ];
            };
        };

        modules.nixos = {
          default = nixosModule;
          sbox = sboxModule;
          direnv-sandbox = nixosModule;
        };

        modules.homeManager = {
          default = homeManagerModule;
          sbox = sboxHmModule;
          direnv-sandbox = homeManagerModule;
        };

        checks = {
          shellcheck = {
            inherit systems;
            check =
              { runCommandLocal, shellcheck, ... }:
              runCommandLocal "shellcheck"
                { nativeBuildInputs = [ shellcheck ]; }
                ''
                  cd ${./direnv-sandbox}
                  shellcheck direnv-sandbox.bash
                  touch $out
                '';
          };

          build-sbox = {
            inherit systems;
            check =
              { system, ... }:
              config.packages.sbox.result.${system};
          };

          build-direnv-sandbox = {
            inherit systems;
            check =
              { system, ... }:
              config.packages.direnv-sandbox.result.${system};
          };

          fish-exit-glob = {
            inherit systems;
            check = import ./direnv-sandbox/tests/fish-exit-glob.nix;
          };

          vm-bash = {
            inherit systems;
            check = import ./direnv-sandbox/tests/vm.nix { inherit nixosModule; shell = "bash"; };
          };

          vm-zsh = {
            inherit systems;
            check = import ./direnv-sandbox/tests/vm.nix { inherit nixosModule; shell = "zsh"; };
          };

          vm-fish = {
            inherit systems;
            check = import ./direnv-sandbox/tests/vm.nix { inherit nixosModule; shell = "fish"; };
          };

          vm-hm-bash = {
            inherit systems;
            check = import ./direnv-sandbox/tests/hm-vm.nix { inherit homeManagerModule home-manager-src; shell = "bash"; };
          };

          vm-hm-zsh = {
            inherit systems;
            check = import ./direnv-sandbox/tests/hm-vm.nix { inherit homeManagerModule home-manager-src; shell = "zsh"; };
          };

          vm-hm-fish = {
            inherit systems;
            check = import ./direnv-sandbox/tests/hm-vm.nix { inherit homeManagerModule home-manager-src; shell = "fish"; };
          };

          vm-sbox = {
            inherit systems;
            check = import ./tests/sbox-vm.nix { sboxPackage = import ./sbox.nix; };
          };

          vm-audio = {
            inherit systems;
            check = import ./tests/audio-vm.nix { sboxPackage = import ./sbox.nix; };
          };
        };
      };
    }
  )
]
