{
  testScriptSnippets = [
    ''
      with subtest("jj config: sbox works when ~/.config/jj exists but repos subdir does not"):
          # Reproduces bug: bwrap fails with
          #   "Can't mkdir /home/alice/.config/jj/repos: Read-only file system"
          # because the script ro-binds ~/.config/jj then tries to tmpfs-mount
          # ~/.config/jj/repos on top of the read-only mount.
          machine.succeed("su - alice -c 'rm -rf /home/alice/.config/jj'")
          machine.succeed("su - alice -c 'mkdir -p /home/alice/.config/jj && echo x > /home/alice/.config/jj/config.toml'")
          val = sbox_run("echo jj-ok")
          assert val == "jj-ok", \
              f"Expected sandbox to start with jj config dir present, got: {val!r}"

      with subtest("nix-path-skip: PATH entries under /nix but outside /nix/store do not break bwrap"):
          # /nix is already mounted via --ro-bind /nix /nix.
          # If the PATH loop only skips /nix/store/* (not all /nix/*),
          # a PATH entry like /nix/var/nix/profiles/default/bin causes bwrap
          # to attempt a redundant bind-mount onto a symlink destination that
          # lives under the already-mounted /nix, which fails.
          #
          # Reproduce by creating a symlink under /nix/ (mimicking a NixOS
          # profile) whose target has a bin/ directory, then putting that
          # bin/ in PATH.
          machine.succeed(
              "mkdir -p /tmp/fake-profile/bin && "
              "ln -sfn /tmp/fake-profile /nix/var/nix/profiles/sbox-test-profile"
          )
          val = machine.succeed(
              f"su - alice -c 'export PATH=\"/nix/var/nix/profiles/sbox-test-profile/bin:$PATH\"; cd \"{project}\" && sbox echo nix-path-ok'"
          ).strip()
          assert "nix-path-ok" in val, \
              f"Expected sbox to handle /nix/var/... in PATH, got: {val!r}"
    ''
  ];
}
