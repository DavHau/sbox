# sbox

<p align="center">
  <img src="https://gist.githubusercontent.com/DavHau/87d0c3b66bd44b852e5f85bb555202e8/raw/sbox-logo-small.jpg" alt="sbox" />
</p>

**Like sudo, but in reverse.**
Sandboxing you won't notice — until you need it.

---

Type `sbox`, and your shell is sandboxed. The project stays writable, the rest of your system disappears — but it still feels like home, because sbox brings along everything that makes your shell yours:

- **Your shell** — bash, zsh, or fish, with your rc files and prompt
- **Your tools** — every program on your `$PATH`, mounted read-only
- **Your history** — shell history shared from the host (or per-project, your choice)
- **Your git config** — global gitconfig and jj config, ready to commit
- **Your SSH known hosts** — so SSH host verification works out of the box
- **Your editor** — `$EDITOR` resolved and available
- **Your GPU** — NVIDIA and DRI devices passed through
- **Networking** — `curl`, `npm install`, `nix build` — it all just works

And when you need to lock things down or open them up, everything is configurable: bind mounts, port forwarding, network modes, audio passthrough, persistent state, and more.

Under the hood, sbox uses [bubblewrap](https://github.com/containers/bubblewrap) for isolation and [slirp4netns](https://github.com/rootless-containers/slirp4netns) for user-mode networking — no root, no daemon, no Docker.

For automatic sandboxing of [direnv](https://direnv.net/) environments, see the [direnv-sandbox](./direnv-sandbox/) integration.

## Try it out

No install needed:

```bash
nix shell github:DavHau/sbox#sbox
```

Then:

```bash
sbox           # sandbox the current directory
sbox --help    # see all options
```

## Installation

### NixOS Module

Add sbox as a flake input and enable the NixOS module:

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
        sbox.nixosModules.sbox
        {
          programs.sbox = {
            enable = true;
            # optional configuration:
            bind."$HOME/.cache" = {};
            allowedTCPPorts = [ 5432 ];
            network = "isolated";
          };
        }
      ];
    };
  };
}
```

### Home Manager

```nix
# home.nix
{ inputs, ... }:
{
  imports = [ inputs.sbox.homeManagerModules.sbox ];

  programs.sbox = {
    enable = true;
    bind."$HOME/.cache" = {};
  };
}
```

## Configuration

All options live under `programs.sbox`:

```nix
programs.sbox = {
  enable = true;

  # Extra paths to mount read-write inside the sandbox
  bind."$HOME/.cache" = {};

  # Mount a GitHub-only SSH key into the sandbox (read-only)
  bindReadOnly."$HOME/.ssh/id_ed25519_github".to = "$HOME/.ssh/id_ed25519";
  bindReadOnly."$HOME/.ssh/id_ed25519_github.pub".to = "$HOME/.ssh/id_ed25519.pub";

  # Persist paths across sandbox sessions
  persist = [ "$HOME/.claude" ];

  # Forward host TCP ports into the sandbox
  allowedTCPPorts = [ 5432 6379 ];

  # Expose sandbox TCP ports to the host
  exposedTCPPorts = [ 3000 8000 ];

  # Mount the parent directory of the project inside the sandbox
  allowParent = "off";  # "off" (default), "read", or "write"

  # Shell history mode: "host" (shared, default), "project" (per-project), "off"
  shareHistory = "host";

  # Share ~/.ssh/known_hosts read-only (default: true)
  shareKnownHosts = true;

  # Network mode: "isolated" (default), "blocked", or "host"
  network = "isolated";

  # Allow audio passthrough (PipeWire)
  allowAudio = false;

  # Extra packages on PATH inside the sandbox
  packages = [];

  # Environment variables inside the sandbox
  environment = {};

  # Shell commands to run when entering the sandbox
  shellHook = "";
};
```

Any options configured via the NixOS/HM module are baked into the `sbox` wrapper, so the command inherits your system configuration by default. Extra flags passed on the command line are appended on top.

## Hardening

### Shell history

By default `shareHistory = "host"`: the host's bash, zsh, and fish history files are bind-mounted read-write into every sandbox. Set `shareHistory = "project"` for per-project history, or `"off"` to disable:

```nix
programs.sbox.shareHistory = "project";
```

### SSH known_hosts

By default `shareKnownHosts = true`: the host's `~/.ssh/known_hosts` is shared read-only. Disable with:

```nix
programs.sbox.shareKnownHosts = false;
```

### Network mode

- `"isolated"` (default) — full internet via slirp4netns
- `"blocked"` — loopback only, port forwarding still works
- `"host"` — no network isolation

```nix
programs.sbox = {
  network = "blocked";
  allowedTCPPorts = [ 5432 ];  # only PostgreSQL
};
```

## Running tests

```bash
nix build .#checks.x86_64-linux.vm-sbox
nix build .#checks.x86_64-linux.vm-audio
```

## Direnv Integration

For automatic sandboxing when `cd`-ing into project directories with `.envrc`, see the [direnv-sandbox](./direnv-sandbox/) sub-project.

## License

MIT
