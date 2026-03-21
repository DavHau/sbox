# direnv-sandbox

![direnv-sandbox](https://gist.githubusercontent.com/DavHau/87d0c3b66bd44b852e5f85bb555202e8/raw/direnv-sandbox.jpg)

Automatic [bubblewrap](https://github.com/containers/bubblewrap) sandboxing for [direnv](https://direnv.net/) environments on NixOS.

## The problem

direnv is powerful but inherently risky. Running `direnv allow` on a project grants its `.envrc` full access to your user account — it can read your SSH keys, browser cookies, credentials, or anything else your user can touch. A malicious or compromised `.envrc` runs with the same privileges as you. This also means that any Nix devShell's `shellHook` — which direnv evaluates via `use flake` or `use nix` — executes with your full user privileges.

**direnv-sandbox** fixes this by running every direnv environment inside an isolated [bubblewrap](https://github.com/containers/bubblewrap) container. The sandbox gets its own PID, IPC, UTS, and cgroup namespaces. Only the project directory is mounted read-write; the rest of the filesystem is either read-only or not visible at all. Network access goes through [slirp4netns](https://github.com/rootless-containers/slirp4netns) user-mode networking, so projects can still fetch dependencies and talk to APIs without having raw access to your host network stack.

The result: `direnv allow` no longer means "I trust this project with my entire home directory." It means "I trust this project with its own directory."

## How it works

When you `cd` into a project with an allowed `.envrc`, the shell hook detects it and transparently launches a sandboxed subshell. Inside, direnv evaluates the `.envrc` as usual — `nix develop`, `use flake`, custom scripts, whatever — but the damage any code can do is contained to the project directory.

## Features

- Transparent entry/exit — `cd` in, `cd` out
- Works with **bash**, **zsh**, and **fish**
- Per-directory opt-out — `direnv-sandbox off` to disable sandboxing for trusted projects
- Isolated PID, IPC, UTS, cgroup, and network namespaces
- User-mode networking via slirp4netns (no root required)
- Optional access to host services via TCP port forwarding
- Read-write bind mounts for paths the project needs
- GPU passthrough (NVIDIA + DRI devices)
- `$PATH` entries from the host are mounted read-only
- NixOS module with declarative configuration
- Full NixOS VM integration tests for all three shells

## Installation

Add direnv-sandbox as a flake input and enable the NixOS module:

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    direnv-sandbox.url = "github:DavHau/direnv-sandbox";
  };

  outputs = { nixpkgs, direnv-sandbox, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        direnv-sandbox.nixosModules.direnv-sandbox
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

## Configuration

All options live under `programs.direnv.sandbox`:

```nix
programs.direnv.sandbox = {
  enable = true;

  # Extra paths to mount read-write inside the sandbox
  bind."$HOME/.cache" = {};

  # Mount a GitHub-only SSH key into the sandbox (read-only)
  bindReadOnly."$HOME/.ssh/id_ed25519_github".to = "$HOME/.ssh/id_ed25519";
  bindReadOnly."$HOME/.ssh/id_ed25519_github.pub".to = "$HOME/.ssh/id_ed25519.pub";

  # Persist paths across sandbox sessions. Each path gets a per-project
  # backing store in <project>/.sbox/state/ and is bind-mounted read-write.
  # Useful for tools that need writable state without breaking isolation.
  persist = [ "$HOME/.claude" ];

  # Forward host TCP ports into the sandbox
  allowedTCPPorts = [ 5432 6379 ];

  # Expose sandbox TCP ports to the host
  exposedTCPPorts = [ 3000 8000 ];

  # Mount the parent directory of the project inside the sandbox
  # "off" (default) = not mounted, "read" = read-only, "write" = read-write
  # The project directory itself is always mounted read-write regardless.
  allowParent = "off";

  # Use host network instead of isolated slirp4netns networking
  hostNetwork = false;
};
```

For advanced use cases, you can override the `command` option directly:

```nix
programs.direnv.sandbox.command = [ "/path/to/my-wrapper" "--custom-flag" ];
```

The shell to exec is appended after `--` automatically.

## Disabling the sandbox for specific projects

```bash
direnv-sandbox off ~/my-trusted-project   # disable
direnv-sandbox on  ~/my-trusted-project   # re-enable
```

The path is optional — without it, the command searches upward from `$PWD`.

This command must be run **outside** the sandbox. Code inside a sandbox cannot disable its own sandboxing (the disabled state is stored read-only inside the sandbox).

## Manual sandbox usage

The `sbox` command is available on your `$PATH` when the module is enabled. It lets you manually launch sandboxed shells with the same isolation and configuration (bind mounts, port forwarding, network mode, etc.) that direnv-sandbox applies automatically:

```bash
sbox                                    # sandbox the current directory
sbox ~/projects/myapp                   # sandbox a specific directory
sbox -- make build                      # run a command inside the sandbox
sbox -p 5432 -- psql                    # additionally forward a host port
sbox --persist $HOME/.claude            # persist Claude Code state per-project
sbox --persist $HOME/.npm -- npm i      # persist npm cache per-project
```

Run `sbox --help` for all available options. Any options configured via the NixOS module (e.g. `bind`, `allowedTCPPorts`, `hostNetwork`) are baked into the wrapper, so `sbox` inherits your system configuration by default. Extra flags passed on the command line are appended on top.

## Running tests

The project includes full NixOS VM tests that boot a virtual machine, log in as a user, and exercise the sandbox entry/exit lifecycle:

```bash
nix build .#checks.x86_64-linux.vm-bash
nix build .#checks.x86_64-linux.vm-zsh
nix build .#checks.x86_64-linux.vm-fish
```

## License

MIT
