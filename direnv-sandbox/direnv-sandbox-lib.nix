# Builds the direnv-specific sbox wrapper.
# The direnv wrapper adds bind mounts for direnv's allow/deny database
# and the exit-dir file for CWD sync between inner and outer shell.
# Returns: { sboxDirenvWrapped }
{ wrappers, lib, pkgs, sboxCfg, sboxArgs }:
let
  sboxPackageArgs = {
    inherit (sboxCfg) packages shellHook;
    env = sboxCfg.environment;
  };

  # sbox with direnv-specific bind mounts
  sboxDirenv = pkgs.callPackage ../sbox.nix (sboxPackageArgs // {
    bubblewrapArgs = [
      "--ro-bind-try" "$HOME/.local/share/direnv" "$HOME/.local/share/direnv"
      "--ro-bind-try" "$HOME/.local/share/direnv-sandbox" "$HOME/.local/share/direnv-sandbox"
      "--bind" "$_DIRENV_SANDBOX_EXIT_DIR_FILE" "$_DIRENV_SANDBOX_EXIT_DIR_FILE"
    ];
  });

  # Direnv wrapper: same args as sbox, but includes direnv-specific bind mounts.
  sboxDirenvWrapped = wrappers.lib.wrapPackage {
    inherit pkgs;
    package = sboxDirenv;
    args = sboxArgs;
  };
in
{
  inherit sboxDirenvWrapped;
}
