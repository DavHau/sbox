{ lib, stdenvNoCC }:
stdenvNoCC.mkDerivation {
  pname = "direnv-sandbox";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./direnv-sandbox.bash
      ./direnv-sandbox.zsh
      ./direnv-sandbox.fish
      ./direnv-sandbox.nu
      ./direnv-sandbox-cmd.bash
    ];
  };
  installPhase = ''
    mkdir -p $out/share/direnv-sandbox
    mkdir -p $out/bin
    cp direnv-sandbox.bash $out/share/direnv-sandbox/
    cp direnv-sandbox.zsh $out/share/direnv-sandbox/
    cp direnv-sandbox.fish $out/share/direnv-sandbox/
    cp direnv-sandbox.nu $out/share/direnv-sandbox/
    cp direnv-sandbox-cmd.bash $out/bin/direnv-sandbox
    chmod +x $out/bin/direnv-sandbox
  '';
}
