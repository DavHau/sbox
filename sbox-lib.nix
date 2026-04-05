# Shared derivations and helpers for the sbox wrapper.
# Returns: { sboxBase, sboxWrapped, sboxArgs }
{ wrappers, lib, pkgs, cfg }:
let
  sboxPackageArgs = {
    inherit (cfg) packages shellHook;
    env = cfg.environment;
  };

  # Build the sbox package with module-configured overrides.
  sboxBase = pkgs.callPackage ./sbox.nix sboxPackageArgs;

  bindMountArgs = flag: mounts:
    lib.concatMap (src:
      let dst = mounts.${src}.to;
      in [ flag src dst ]
    ) (builtins.attrNames mounts);

  sboxArgs =
    (bindMountArgs "--bind-try" cfg.bind)
    ++ (bindMountArgs "--ro-bind-try" cfg.bindReadOnly)
    ++ (lib.concatMap (p: [ "--allow-port" (toString p) ]) cfg.allowedTCPPorts)
    ++ (lib.concatMap (p: [ "--expose-port" (toString p) ]) cfg.exposedTCPPorts)
    ++ (lib.optionals (cfg.network == "host") [ "--network" "host" ])
    ++ (lib.optionals (cfg.network == "blocked") [ "--network" "blocked" ])
    ++ (lib.optionals (cfg.network == "isolated") [ "--network" "isolated" ])
    ++ (lib.optionals (cfg.allowParent != "off") [ "--allow-parent" cfg.allowParent ])
    ++ (lib.optionals cfg.allowAudio [ "--audio" ])
    ++ (lib.optionals (!cfg.shareKnownHosts) [ "--no-known-hosts" ])
    ++ (lib.optionals (cfg.shareHistory != "host") [ "--history" cfg.shareHistory ])
    ++ (lib.concatMap (p: [ "--persist" p ]) cfg.persist);

  # Standalone wrapper: bakes in module-configured args for manual use.
  sboxWrapped = wrappers.lib.wrapPackage {
    inherit pkgs;
    package = sboxBase;
    args = sboxArgs;
  };
in
{
  inherit sboxBase sboxWrapped sboxArgs;
}
