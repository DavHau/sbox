# direnv-sandbox

<p align="center">
  <img src="https://gist.githubusercontent.com/DavHau/87d0c3b66bd44b852e5f85bb555202e8/raw/direnv-sandbox-small.jpg" alt="direnv-sandbox" />
</p>

**`direnv allow` without the trust issues.**

## The problem

direnv is powerful but inherently risky. Running `direnv allow` on a project grants its `.envrc` full access to your user account — it can read your SSH keys, browser cookies, credentials, or anything else your user can touch. A malicious or compromised `.envrc` runs with the same privileges as you. This also means that any Nix devShell's `shellHook` — which direnv evaluates via `use flake` or `use nix` — executes with your full user privileges.

**direnv-sandbox** fixes this by running every direnv environment inside an isolated sandbox. The result: `direnv allow` no longer means "I trust this project with my entire home directory." It means "I trust this project with its own directory."

## How it works

When you `cd` into a project with an allowed `.envrc`, the shell hook transparently launches a sandboxed subshell. Inside, direnv evaluates the `.envrc` as usual — `nix develop`, `use flake`, custom scripts, whatever — but the code can only touch the project directory. When you `cd` out, the sandbox exits and your original shell resumes.

It feels like normal direnv. You don't interact with the sandbox at all.

## Features

- **Transparent entry/exit** — `cd` in, `cd` out. That's it.
- **Works with bash, zsh, fish, and nushell\***
- **Feels native** — your shell, your prompt, your history, your tools, your git config — all there
- **Networking just works** — `nix build`, `npm install`, `cargo fetch` — no extra setup
- **Per-directory opt-out** — `direnv-sandbox off` to disable sandboxing for trusted projects

<sub>\* nushell is only supported via the Home Manager module.</sub>

## Installation

### NixOS Module

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    sbox.url = "github:DavHau/sbox";
  };

  outputs = { nixpkgs, sbox, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        sbox.nixosModules.direnv-sandbox
        {
          programs.direnv = {
            enable = true;
            sandbox.enable = true;
          };
        }
      ];
    };
  };
}
```

That's it. The module replaces direnv's shell hooks with sandbox-aware versions.

### Home Manager

```nix
# home.nix
{ inputs, ... }:
{
  imports = [ inputs.sbox.homeManagerModules.direnv-sandbox ];

  programs.direnv = {
    enable = true;
    sandbox.enable = true;
  };
}
```

## Configuration

The sandbox is powered by [sbox](../), a standalone sandboxing tool that can also be used independently. Sandbox options live under `programs.sbox` (see the [sbox README](../) for the full list):

```nix
# Sandbox configuration
programs.sbox = {
  bind."$HOME/.cache" = {};
  bindReadOnly."$HOME/.ssh/id_ed25519_github".to = "$HOME/.ssh/id_ed25519";
  persist = [ "$HOME/.claude" ];
  allowedTCPPorts = [ 5432 6379 ];
  exposedTCPPorts = [ 3000 8000 ];
  network = "isolated";
  shareHistory = "host";
  shareKnownHosts = true;
};

# Enable direnv sandboxing
programs.direnv = {
  enable = true;
  sandbox.enable = true;
};
```

## Disabling the sandbox for specific projects

```bash
direnv-sandbox off ~/my-trusted-project   # disable
direnv-sandbox on  ~/my-trusted-project   # re-enable
```

This command must be run **outside** the sandbox. Code inside a sandbox cannot disable its own sandboxing.

## Running tests

```bash
nix build .#checks.x86_64-linux.vm-bash
nix build .#checks.x86_64-linux.vm-zsh
nix build .#checks.x86_64-linux.vm-fish
nix build .#checks.x86_64-linux.vm-hm-bash
nix build .#checks.x86_64-linux.vm-hm-zsh
nix build .#checks.x86_64-linux.vm-hm-fish
nix build .#checks.x86_64-linux.vm-hm-nushell
```

## License

MIT
