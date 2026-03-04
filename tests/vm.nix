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

  checkDeniedUnsetCmd = {
    bash = "echo \${SANDBOX_TEST_DENIED:-unset} > /tmp/denied-env";
    zsh = "echo \${SANDBOX_TEST_DENIED:-unset} > /tmp/denied-env";
    fish = "set -q SANDBOX_TEST_DENIED; and echo set > /tmp/denied-env; or echo unset > /tmp/denied-env";
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
          mkdir -p /home/alice/project/subdir
          echo 'export SANDBOX_TEST=hello' > /home/alice/project/.envrc
          chown -R alice:users /home/alice/project

          mkdir -p /home/alice/project2
          echo 'export SANDBOX_TEST2=world' > /home/alice/project2/.envrc
          chown -R alice:users /home/alice/project2

          mkdir -p /home/alice/project-denied
          echo 'export SANDBOX_TEST_DENIED=evil' > /home/alice/project-denied/.envrc
          chown -R alice:users /home/alice/project-denied

          mkdir -p /home/alice/project-notallowed
          echo 'export SANDBOX_TEST_NOTALLOWED=nope' > /home/alice/project-notallowed/.envrc
          chown -R alice:users /home/alice/project-notallowed

          # Symlinked project: real dir is ~/synced/projects/symtest,
          # accessed via ~/projects-link/symtest
          mkdir -p /home/alice/synced/projects/symtest
          echo 'export SANDBOX_TEST_SYM=symlinked' > /home/alice/synced/projects/symtest/.envrc
          chown -R alice:users /home/alice/synced
          ln -sfn /home/alice/synced/projects /home/alice/projects-link
          chown -h alice:users /home/alice/projects-link
        ''
        # Prevent zsh's new-user-install wizard from blocking the inner shell
        + lib.optionalString (shell == "zsh") ''
          touch /home/alice/.zshrc
          chown alice:users /home/alice/.zshrc
        '';
      };
    };

  testScript = ''
    import test_driver.machine

    _orig_retry = test_driver.machine.retry

    def fast_retry(fn, timeout_seconds=900):
        import time
        from test_driver.errors import RequestedAssertionFailed

        start_time = time.monotonic()
        while time.monotonic() - start_time < timeout_seconds:
            if fn(False):
                return
            time.sleep(0.1)
        elapsed = time.monotonic() - start_time
        if not fn(True):
            raise RequestedAssertionFailed(
                f"action timed out after {elapsed:.2f} seconds (timeout={timeout_seconds})"
            )

    test_driver.machine.retry = fast_retry

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

    # Deny the project-denied .envrc
    machine.execute("rm -f /tmp/deny-done")
    machine.send_chars("direnv deny ~/project-denied; echo DONE > /tmp/deny-done\n")
    machine.wait_until_succeeds("test -s /tmp/deny-done", timeout=5)

    with subtest("no sandbox for denied envrc"):
        machine.send_chars("cd ~/project-denied\n")
        # If a sandbox launched, SHLVL would increase and we'd be stuck inside.
        # Verify we're still in the outer shell at the same SHLVL.
        machine.execute("rm -f /tmp/denied-shlvl")
        machine.send_chars("echo $SHLVL > /tmp/denied-shlvl\n")
        machine.wait_until_succeeds("test -s /tmp/denied-shlvl", timeout=10)
        denied_shlvl = int(machine.succeed("cat /tmp/denied-shlvl").strip())
        machine.log(f"SHLVL in denied dir: {denied_shlvl} (initial: {initial_shlvl})")
        assert denied_shlvl == initial_shlvl, \
            f"Expected SHLVL == {initial_shlvl} (no sandbox for denied dir), got {denied_shlvl}"

        # Also verify SANDBOX_TEST_DENIED is NOT set (direnv didn't load it)
        machine.execute("rm -f /tmp/denied-env")
        machine.send_chars("${checkDeniedUnsetCmd}\n")
        machine.wait_until_succeeds("test -s /tmp/denied-env", timeout=5)
        val = machine.succeed("cat /tmp/denied-env").strip()
        machine.log(f"SANDBOX_TEST_DENIED: '{val}'")
        assert val == "unset", \
            f"Expected SANDBOX_TEST_DENIED to be unset in denied dir, got: {val!r}"

    # Go back home before the next test
    machine.send_chars("cd ~\n")
    machine.execute("rm -f /tmp/back-home")
    machine.send_chars("echo DONE > /tmp/back-home\n")
    machine.wait_until_succeeds("test -s /tmp/back-home", timeout=5)

    with subtest("no sandbox for not-allowed envrc"):
        # project-notallowed has an .envrc that was never direnv-allowed.
        # The sandbox must NOT launch.
        machine.send_chars("cd ~/project-notallowed\n")
        machine.execute("rm -f /tmp/notallowed-shlvl")
        machine.send_chars("echo $SHLVL > /tmp/notallowed-shlvl\n")
        machine.wait_until_succeeds("test -s /tmp/notallowed-shlvl", timeout=10)
        notallowed_shlvl = int(machine.succeed("cat /tmp/notallowed-shlvl").strip())
        machine.log(f"SHLVL in not-allowed dir: {notallowed_shlvl} (initial: {initial_shlvl})")
        assert notallowed_shlvl == initial_shlvl, \
            f"Expected SHLVL == {initial_shlvl} (no sandbox for not-allowed dir), got {notallowed_shlvl}"

    # Go back home before the next test
    machine.send_chars("cd ~\n")
    machine.execute("rm -f /tmp/back-home2")
    machine.send_chars("echo DONE > /tmp/back-home2\n")
    machine.wait_until_succeeds("test -s /tmp/back-home2", timeout=5)

    with subtest("sandbox works for symlinked project directory"):
        # Allow the envrc via the REAL path
        machine.execute("rm -f /tmp/allow-sym")
        machine.send_chars("direnv allow ~/synced/projects/symtest; echo DONE > /tmp/allow-sym\n")
        machine.wait_until_succeeds("test -s /tmp/allow-sym", timeout=5)

        # Enter via the SYMLINK path — the sandbox should launch and
        # direnv should load the envrc successfully (not "blocked").
        machine.send_chars("cd ~/projects-link/symtest\n")
        symtest_dir = "/home/alice/synced/projects/symtest"
        machine.execute(f"rm -f {symtest_dir}/sym-env")
        machine.send_chars(f"echo $SANDBOX_TEST_SYM > {symtest_dir}/sym-env\n")
        machine.wait_until_succeeds(f"test -s {symtest_dir}/sym-env", timeout=10)
        val = machine.succeed(f"cat {symtest_dir}/sym-env").strip()
        machine.log(f"SANDBOX_TEST_SYM via symlink: '{val}'")
        assert val == "symlinked", \
            f"Expected SANDBOX_TEST_SYM=symlinked via symlink path, got: {val!r}"

    # Exit sandbox
    machine.send_chars("cd /\n")
    machine.execute("rm -f /tmp/exited-sym")
    machine.send_chars("echo DONE > /tmp/exited-sym\n")
    machine.wait_until_succeeds("test -s /tmp/exited-sym", timeout=15)

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

    # Exit sandbox before testing subdir entry
    machine.send_chars("cd /\n")
    machine.execute("rm -f /tmp/exited")
    machine.send_chars("echo DONE > /tmp/exited\n")
    machine.wait_for_file("/tmp/exited")

    with subtest("sandbox entry on cd into subdirectory"):
        machine.send_chars("cd ~/project/subdir\n")
        machine.execute(f"rm -f {project}/subdir-check")
        machine.send_chars(f"echo $SANDBOX_TEST > {project}/subdir-check\n")
        machine.wait_until_succeeds(f"test -s {project}/subdir-check", timeout=10)
        subdir_val = machine.succeed(f"cat {project}/subdir-check").strip()
        machine.log(f"SANDBOX_TEST in subdir: '{subdir_val}'")
        assert subdir_val == "hello", \
            f"Expected SANDBOX_TEST=hello in subdir, got: {subdir_val!r}"

    # Exit sandbox before testing direnv-allow-while-in-dir
    machine.send_chars("cd /\n")
    machine.execute("rm -f /tmp/exited2")
    machine.send_chars("echo DONE > /tmp/exited2\n")
    machine.wait_for_file("/tmp/exited2")

    with subtest("sandbox activates after direnv allow from within project"):
        # cd into project2 whose .envrc is NOT yet allowed — no sandbox should launch
        machine.send_chars("cd ~/project2\n")
        machine.execute("rm -f /tmp/cd-done")
        machine.send_chars("echo DONE > /tmp/cd-done\n")
        machine.wait_for_file("/tmp/cd-done")

        # Now allow the .envrc while already inside the directory.
        # The sandbox should activate without needing to cd out and back in.
        machine.send_chars("direnv allow .\n")
        machine.execute("rm -f /home/alice/project2/allow-check")
        machine.send_chars("echo $SANDBOX_TEST2 > ~/project2/allow-check\n")
        machine.wait_until_succeeds("test -s /home/alice/project2/allow-check", timeout=10)
        val = machine.succeed("cat /home/alice/project2/allow-check").strip()
        machine.log(f"SANDBOX_TEST2 after allow: '{val}'")
        assert val == "world", \
            f"Expected SANDBOX_TEST2=world after direnv allow, got: {val!r}"

    # Exit sandbox before testing direnv-sandbox off
    machine.send_chars("cd /\n")
    machine.execute("rm -f /tmp/exited3")
    machine.send_chars("echo DONE > /tmp/exited3\n")
    machine.wait_until_succeeds("test -s /tmp/exited3", timeout=15)

    # --- direnv-sandbox off/on tests (bash only) ---
    if shell == "bash":

        with subtest("direnv-sandbox off disables sandbox"):
            # Disable sandbox for project from OUTSIDE (using path argument)
            # so we don't trigger the sandbox by cd'ing in first.
            machine.execute("rm -f /tmp/off-done")
            machine.send_chars("direnv-sandbox off ~/project; echo DONE > /tmp/off-done\n")
            machine.wait_until_succeeds("test -s /tmp/off-done", timeout=10)

            # cd into project — should NOT launch a sandbox
            machine.send_chars("cd ~/project\n")
            # Wait for the next prompt (direnv export runs in PROMPT_COMMAND)
            # Use a two-step marker: first trigger a prompt, then check env
            machine.execute("rm -f /tmp/nosandbox-env")
            machine.send_chars("echo $SANDBOX_TEST > /tmp/nosandbox-env\n")
            machine.wait_until_succeeds("test -s /tmp/nosandbox-env", timeout=10)
            val = machine.succeed("cat /tmp/nosandbox-env").strip()
            machine.log(f"SANDBOX_TEST with sandbox disabled: '{val}'")
            assert val == "hello", \
                f"Expected SANDBOX_TEST=hello (unsandboxed), got: {val!r}"

            # Verify SHLVL did NOT increase (no subshell)
            machine.execute("rm -f /tmp/shlvl-nosandbox")
            machine.send_chars("echo $SHLVL > /tmp/shlvl-nosandbox\n")
            machine.wait_until_succeeds("test -s /tmp/shlvl-nosandbox", timeout=5)
            nosandbox_shlvl = int(machine.succeed("cat /tmp/shlvl-nosandbox").strip())
            machine.log(f"SHLVL with sandbox disabled: {nosandbox_shlvl} (initial: {initial_shlvl})")
            assert nosandbox_shlvl == initial_shlvl, \
                f"Expected SHLVL == {initial_shlvl} (no sandbox), got {nosandbox_shlvl}"

            # Verify SANDBOX env var is NOT set (not inside bwrap)
            machine.execute("rm -f /tmp/sandbox-var")
            machine.send_chars("echo ''${SANDBOX:-unset} > /tmp/sandbox-var\n")
            machine.wait_until_succeeds("test -s /tmp/sandbox-var", timeout=5)
            sandbox_var = machine.succeed("cat /tmp/sandbox-var").strip()
            assert sandbox_var == "unset", \
                f"Expected SANDBOX to be unset, got: {sandbox_var!r}"

        with subtest("direnv unloads when leaving disabled-sandbox dir"):
            machine.send_chars("cd /\n")
            machine.execute("rm -f /tmp/unload-check")
            machine.send_chars("echo ''${SANDBOX_TEST:-unset} > /tmp/unload-check\n")
            machine.wait_until_succeeds("test -s /tmp/unload-check", timeout=10)
            val = machine.succeed("cat /tmp/unload-check").strip()
            machine.log(f"SANDBOX_TEST after leaving disabled dir: '{val}'")
            assert val == "unset", \
                f"Expected SANDBOX_TEST to be unset after leaving, got: {val!r}"

        with subtest("direnv-sandbox on re-enables sandbox"):
            # Re-enable sandbox from outside (using path argument)
            machine.execute("rm -f /tmp/on-done")
            machine.send_chars("direnv-sandbox on ~/project; echo DONE > /tmp/on-done\n")
            machine.wait_until_succeeds("test -s /tmp/on-done", timeout=10)

            # cd into project — sandbox should activate again
            machine.send_chars("cd ~/project\n")
            machine.execute(f"rm -f {project}/sandbox-back")
            machine.send_chars(f"echo $SANDBOX_TEST > {project}/sandbox-back\n")
            machine.wait_until_succeeds(f"test -s {project}/sandbox-back", timeout=10)
            val = machine.succeed(f"cat {project}/sandbox-back").strip()
            machine.log(f"SANDBOX_TEST after re-enable: '{val}'")
            assert val == "hello", \
                f"Expected SANDBOX_TEST=hello after re-enable, got: {val!r}"

            # Verify SHLVL increased again (sandbox subshell)
            machine.execute(f"rm -f {project}/shlvl-reenabled")
            machine.send_chars(f"echo $SHLVL > {project}/shlvl-reenabled\n")
            machine.wait_until_succeeds(f"test -s {project}/shlvl-reenabled", timeout=5)
            reenabled_shlvl = int(machine.succeed(f"cat {project}/shlvl-reenabled").strip())
            machine.log(f"SHLVL after re-enable: {reenabled_shlvl} (initial: {initial_shlvl})")
            assert reenabled_shlvl > initial_shlvl, \
                f"Expected SHLVL > {initial_shlvl} after re-enable, got {reenabled_shlvl}"

        with subtest("direnv-sandbox off refuses to run inside sandbox"):
            # We're inside the sandbox from the previous test.
            # This is security-critical: a malicious .envrc must not be able to
            # disable the sandbox for its own directory, otherwise next time the
            # user cd's in it would run unsandboxed.
            machine.execute(f"rm -f {project}/off-inside")
            machine.send_chars(f"direnv-sandbox off 2>{project}/off-inside; echo DONE >> {project}/off-inside\n")
            machine.wait_until_succeeds(f"test -s {project}/off-inside", timeout=5)
            output = machine.succeed(f"cat {project}/off-inside").strip()
            machine.log(f"direnv-sandbox off inside sandbox: '{output}'")
            assert "cannot" in output and "sandbox" in output, \
                f"Expected sandbox error when running direnv-sandbox off inside sandbox, got: {output!r}"
            # Must suggest the exact command the user needs to run
            assert f"direnv-sandbox off {project}" in output, \
                f"Expected hint with full command 'direnv-sandbox off {project}', got: {output!r}"

        with subtest("disabled dir is read-only inside sandbox"):
            # Even if a malicious .envrc bypasses the CLI check, the filesystem
            # itself must prevent writes to the disabled directory.
            # Try to create a symlink directly, simulating what direnv-sandbox off does.
            machine.execute(f"rm -f {project}/ro-check")
            machine.send_chars(f"mkdir -p ~/.local/share/direnv-sandbox/disabled 2>{project}/ro-check && ln -sfn {project} ~/.local/share/direnv-sandbox/disabled/fakehash 2>>{project}/ro-check; echo DONE >> {project}/ro-check\n")
            machine.wait_until_succeeds(f"test -s {project}/ro-check", timeout=5)
            output = machine.succeed(f"cat {project}/ro-check").strip()
            machine.log(f"Direct write to disabled dir inside sandbox: '{output}'")
            assert "DONE" in output, f"Command did not complete: {output!r}"
            assert "Read-only" in output or "Permission denied" in output, \
                f"Expected filesystem error writing to disabled dir, got: {output!r}"
  '';
}
