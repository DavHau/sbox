# Flake compatibility wrapper. The actual project entry point is nilla.nix.
{
  description = "sbox — bubblewrap sandbox for development environments, with direnv integration";

  # All inputs are managed by nixtamal via nilla.nix — no flake inputs needed.
  inputs = { };

  outputs =
    { self }:
    (import ./nilla.nix).flakeOutputs;
}
