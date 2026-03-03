{ pkgs, lib, self, shell ? "bash" }:
let
  shellPkgs = {
    bash = pkgs.bashInteractive;
    zsh = pkgs.zsh;
    fish = pkgs.fish;
  };

  # Shell-specific command to check that SANDBOX_TEST is unset.
  # bash/zsh support ${VAR:-default}, fish needs set -q.
  checkUnsetCmd = {
    bash = "echo \${SANDBOX_TEST:-unset} > /tmp/env-after";
    zsh = "echo \${SANDBOX_TEST:-unset} > /tmp/env-after";
    fish = "set -q SANDBOX_TEST; and echo set > /tmp/env-after; or echo unset > /tmp/env-after";
  }.${shell};
in
pkgs.testers.runNixOSTest {
  name = "direnv-sandbox-${shell}";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ self.nixosModules.direnv-sandbox ];

      users.users.alice = {
        isNormalUser = true;
        password = "foobar";
        shell = shellPkgs.${shell};
      };

      programs.zsh.enable = shell == "zsh";
      programs.fish.enable = shell == "fish";

      programs.direnv = {
        enable = true;
        sandbox = {
          enable = true;
        };
      };

      # Create a project directory with an .envrc.
      # deps ensures this runs after user creation (default order is alphabetical).
      system.activationScripts.createProject = {
        deps = [ "users" ];
        text = ''
          mkdir -p /home/alice/project
          echo 'export SANDBOX_TEST=hello' > /home/alice/project/.envrc
          chown -R alice:users /home/alice/project
        ''
        # Prevent zsh's new-user-install wizard from blocking the inner shell
        + lib.optionalString (shell == "zsh") ''
          touch /home/alice/.zshrc
          chown alice:users /home/alice/.zshrc
        '';
      };
    };

  testScript = ''
    project = "/home/alice/project"
    shell = "${shell}"

    # Boot and login
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("getty@tty1.service")
    machine.wait_until_tty_matches("1", "login: ")
    machine.send_chars("alice\n")
    machine.wait_until_tty_matches("1", "Password: ")
    machine.send_chars("foobar\n")

    # Wait for shell to be ready via a marker file
    machine.execute("rm -f /tmp/login-ok")
    machine.send_chars("echo DONE > /tmp/login-ok\n")
    machine.wait_for_file("/tmp/login-ok")

    # Record initial SHLVL
    machine.execute("rm -f /tmp/shlvl-init")
    machine.send_chars("echo $SHLVL > /tmp/shlvl-init\n")
    machine.wait_until_succeeds("test -s /tmp/shlvl-init", timeout=5)
    initial_shlvl = int(machine.succeed("cat /tmp/shlvl-init").strip())
    machine.log(f"Initial SHLVL: {initial_shlvl}")

    # Allow the .envrc (from home dir, not the project dir)
    machine.execute("rm -f /tmp/allow-done")
    machine.send_chars("direnv allow ~/project; echo DONE > /tmp/allow-done\n")
    machine.wait_for_file("/tmp/allow-done")

    with subtest("sandbox entry on cd"):
        # We're in ~ (home dir). cd into project triggers PROMPT_COMMAND which
        # detects .envrc, verifies it's allowed, and launches bwrap -- bash.
        # Inside bwrap, bash sources .bashrc -> our hook (inner mode) -> direnv hook.
        # Direnv evaluates .envrc, exports SANDBOX_TEST=hello.
        # We then type a command to verify.
        machine.send_chars("cd ~/project\n")
        # The sandbox launches bwrap, which runs the shell, which sources
        # the hook script (inner mode) + direnv hook, then direnv loads .envrc.
        # Characters are buffered in the TTY until the inner shell is ready.
        machine.execute(f"rm -f {project}/env-check")
        machine.send_chars(f"echo $SANDBOX_TEST > {project}/env-check\n")
        machine.wait_until_succeeds(f"test -s {project}/env-check", timeout=10)
        env_val = machine.succeed(f"cat {project}/env-check").strip()
        machine.log(f"SANDBOX_TEST value: '{env_val}'")
        assert env_val == "hello", f"Expected SANDBOX_TEST=hello, got: {env_val!r}"

    with subtest("SHLVL increases inside sandbox"):
        machine.execute(f"rm -f {project}/shlvl-inside")
        machine.send_chars(f"echo $SHLVL > {project}/shlvl-inside\n")
        machine.wait_until_succeeds(f"test -s {project}/shlvl-inside", timeout=5)
        inside_shlvl = int(machine.succeed(f"cat {project}/shlvl-inside").strip())
        machine.log(f"Inside SHLVL: {inside_shlvl} (initial: {initial_shlvl})")
        assert inside_shlvl > initial_shlvl, \
            f"Expected SHLVL > {initial_shlvl} inside sandbox, got {inside_shlvl}"

    with subtest("sandbox exit on cd out"):
        # Trigger exit by navigating outside project tree
        machine.send_chars("cd /\n")

        machine.execute("rm -f /tmp/env-after")
        machine.send_chars("${checkUnsetCmd}\n")
        machine.wait_until_succeeds("test -s /tmp/env-after", timeout=15)
        env_after = machine.succeed("cat /tmp/env-after").strip()
        machine.log(f"SANDBOX_TEST after exit: '{env_after}'")
        assert env_after == "unset", \
            f"Expected SANDBOX_TEST to be unset, got: {env_after!r}"

    with subtest("SHLVL decreases after sandbox exit"):
        machine.execute("rm -f /tmp/shlvl-outside")
        machine.send_chars("echo $SHLVL > /tmp/shlvl-outside\n")
        machine.wait_until_succeeds("test -s /tmp/shlvl-outside", timeout=5)
        outside_shlvl = int(machine.succeed("cat /tmp/shlvl-outside").strip())
        machine.log(f"Outside SHLVL: {outside_shlvl} (initial: {initial_shlvl})")
        assert outside_shlvl == initial_shlvl, \
            f"Expected SHLVL == {initial_shlvl} after exit, got {outside_shlvl}"

    with subtest("re-entry works"):
        machine.send_chars("cd ~/project\n")
        machine.execute(f"rm -f {project}/reentry-check")
        machine.send_chars(f"echo $SANDBOX_TEST > {project}/reentry-check\n")
        machine.wait_until_succeeds(f"test -s {project}/reentry-check", timeout=10)
        reentry_val = machine.succeed(f"cat {project}/reentry-check").strip()
        machine.log(f"SANDBOX_TEST on re-entry: '{reentry_val}'")
        assert reentry_val == "hello", \
            f"Expected SANDBOX_TEST=hello on re-entry, got: {reentry_val!r}"
  '';
}
