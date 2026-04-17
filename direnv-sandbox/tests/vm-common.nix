# Shared test infrastructure for direnv-sandbox VM tests.
# Both the NixOS module test (vm.nix) and the Home Manager module test (hm-vm.nix)
# call this with their respective node configuration.
{
  lib,
  testers,
  bash,
  zsh,
  fish,
  nushell,
  shell ? "bash",
  # Test name prefix, e.g. "direnv-sandbox" or "direnv-sandbox-hm"
  name,
  # NixOS module config for the test VM node (a function { pkgs, ... }: { ... })
  nodeConfig,
}:
let
  shellPkgs = {
    inherit bash zsh fish nushell;
  };

  # Per-shell command primitives used throughout the test script. Each entry
  # is the shell's encoding of one conceptual operation (write a file, read
  # an env var, capture stderr, ...). Keeps the Python test body single-source
  # across bash, zsh, fish, and nushell. Only the primitive encodings differ.
  c = let
    dispatch = attrs: attrs.${shell};
  in {
    # Login readiness marker. Written from the user's shell once it accepts
    # input; the harness polls for this file to know it can proceed.
    loginReady = dispatch {
      bash    = "echo DONE > /tmp/login-ok";
      zsh     = "echo DONE > /tmp/login-ok";
      fish    = "echo DONE > /tmp/login-ok";
      nushell = "'DONE' | save -f /tmp/login-ok";
    };

    # Write a literal token (no spaces or shell metacharacters) to a file.
    writeLiteral = literal: path: dispatch {
      bash    = "echo ${literal} > ${path}";
      zsh     = "echo ${literal} > ${path}";
      fish    = "echo ${literal} > ${path}";
      nushell = "'${literal}' | save -f ${path}";
    };

    # Write the value of env var $VAR to a file. When VAR is unset, POSIX
    # shells write an empty line and nushell writes the literal 'UNSET' — both
    # produce a deterministic, non-matching value that makes the assertion
    # fail cleanly with a readable diff rather than time out.
    writeEnv = v: p: dispatch {
      bash    = "echo \$${v} > ${p}";
      zsh     = "echo \$${v} > ${p}";
      fish    = "echo \$${v} > ${p}";
      nushell = "$env.${v}? | default 'UNSET' | save -f ${p}";
    };

    # Write $SHLVL to a file. Nushell does not auto-set SHLVL, hence default.
    writeShlvl = p: dispatch {
      bash    = "echo $SHLVL > ${p}";
      zsh     = "echo $SHLVL > ${p}";
      fish    = "echo $SHLVL > ${p}";
      nushell = "$env.SHLVL? | default '1' | save -f ${p}";
    };

    # Write $VAR or the literal string 'unset' to a file.
    writeEnvOrUnset = v: p: dispatch {
      bash    = "echo \${${v}:-unset} > ${p}";
      zsh     = "echo \${${v}:-unset} > ${p}";
      fish    = "set -q ${v}; and echo \$${v} > ${p}; or echo unset > ${p}";
      nushell = "$env.${v}? | default 'unset' | save -f ${p}";
    };

    # Read src into dst (one file → another file).
    readFile = src: dst: dispatch {
      bash    = "cat ${src} > ${dst}";
      zsh     = "cat ${src} > ${dst}";
      fish    = "cat ${src} > ${dst}";
      nushell = "open ${src} | save -f ${dst}";
    };

    # Run cmd and capture its stderr to a file. Used by tests that expect a
    # command to fail with a specific error message.
    #
    # Nushell quirks addressed here:
    # (1) Doubled braces — when the result is embedded in a Python f-string
    #     (which the test driver consumes) `{{` / `}}` render as literal
    #     `{` / `}`, i.e. nushell's block syntax, instead of being parsed as
    #     f-string placeholders.
    # (2) `^` prefix — forces external invocation. Nushell builtins (`touch`,
    #     `mkdir`, ...) raise structured errors that abort the pipeline before
    #     `complete` can capture them, so their stderr would never reach the
    #     output file. `^` routes through PATH and gives us POSIX stderr.
    captureStderr = cmd: p: dispatch {
      bash    = "${cmd} 2>${p}";
      zsh     = "${cmd} 2>${p}";
      fish    = "${cmd} 2>${p}";
      nushell = "do {{ ^${cmd} }} | complete | get stderr | save -f ${p}";
    };
  };

  # Common activation script to create test project directories.
  # The zshrcWorkaround parameter controls whether to create a dummy .zshrc
  # to prevent the new-user-install wizard (needed for NixOS module tests
  # where HM doesn't manage .zshrc).
  mkProjectActivationScript = { zshrcWorkaround ? false }: {
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

      mkdir -p /home/alice/.cache
      echo "bind-works" > /home/alice/.cache/bind-test-file
      chown -R alice:users /home/alice/.cache

      # Symlinked project: real dir is ~/synced/projects/symtest,
      # accessed via ~/projects-link/symtest
      mkdir -p /home/alice/synced/projects/symtest
      echo 'export SANDBOX_TEST_SYM=symlinked' > /home/alice/synced/projects/symtest/.envrc
      chown -R alice:users /home/alice/synced
      ln -sfn /home/alice/synced/projects /home/alice/projects-link
      chown -h alice:users /home/alice/projects-link
    ''
    # Prevent zsh's new-user-install wizard from blocking the inner shell.
    # Only needed when HM doesn't manage .zshrc (i.e. NixOS module tests).
    + lib.optionalString (zshrcWorkaround && shell == "zsh") ''
      touch /home/alice/.zshrc
      chown alice:users /home/alice/.zshrc
    '';
  };
in
{
  inherit shellPkgs mkProjectActivationScript;

  test = testers.runNixOSTest {
    name = "${name}-${shell}";

    nodes.machine = nodeConfig;

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
              time.sleep(0.3)
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

      # Wait for shell to be ready
      machine.execute("rm -f /tmp/login-ok")
      machine.send_chars("${c.loginReady}\n")
      machine.wait_for_file("/tmp/login-ok")

      # Record initial SHLVL
      machine.execute("rm -f /tmp/shlvl-init")
      machine.send_chars("${c.writeShlvl "/tmp/shlvl-init"}\n")
      machine.wait_until_succeeds("test -s /tmp/shlvl-init", timeout=5)
      initial_shlvl = int(machine.succeed("cat /tmp/shlvl-init").strip())

      machine.send_chars("direnv allow ~/project\n")
      machine.send_chars("direnv deny ~/project-denied\n")

      with subtest("no sandbox for denied envrc"):
          machine.send_chars("cd ~/project-denied\n")
          machine.execute("rm -f /tmp/denied-shlvl")
          machine.send_chars("${c.writeShlvl "/tmp/denied-shlvl"}\n")
          machine.wait_until_succeeds("test -s /tmp/denied-shlvl", timeout=10)
          denied_shlvl = int(machine.succeed("cat /tmp/denied-shlvl").strip())
          assert denied_shlvl == initial_shlvl, \
              f"Expected SHLVL == {initial_shlvl} (no sandbox for denied dir), got {denied_shlvl}"

          machine.execute("rm -f /tmp/denied-env")
          machine.send_chars("${c.writeEnvOrUnset "SANDBOX_TEST_DENIED" "/tmp/denied-env"}\n")
          machine.wait_until_succeeds("test -s /tmp/denied-env", timeout=5)
          val = machine.succeed("cat /tmp/denied-env").strip()
          assert val == "unset", \
              f"Expected SANDBOX_TEST_DENIED to be unset in denied dir, got: {val!r}"

      with subtest("no sandbox for not-allowed envrc"):
          machine.send_chars("cd ~/project-notallowed\n")
          machine.execute("rm -f /tmp/notallowed-shlvl")
          machine.send_chars("${c.writeShlvl "/tmp/notallowed-shlvl"}\n")
          machine.wait_until_succeeds("test -s /tmp/notallowed-shlvl", timeout=10)
          notallowed_shlvl = int(machine.succeed("cat /tmp/notallowed-shlvl").strip())
          assert notallowed_shlvl == initial_shlvl, \
              f"Expected SHLVL == {initial_shlvl} (no sandbox for not-allowed dir), got {notallowed_shlvl}"

      with subtest("sandbox works for symlinked project directory"):
          symtest_dir = "/home/alice/synced/projects/symtest"
          machine.send_chars("direnv allow ~/synced/projects/symtest\n")
          machine.send_chars("cd ~/projects-link/symtest\n")
          machine.execute(f"rm -f {symtest_dir}/sym-env")
          machine.send_chars(f"${c.writeEnv "SANDBOX_TEST_SYM" "{symtest_dir}/sym-env"}\n")
          machine.wait_until_succeeds(f"test -s {symtest_dir}/sym-env", timeout=10)
          val = machine.succeed(f"cat {symtest_dir}/sym-env").strip()
          assert val == "symlinked", \
              f"Expected SANDBOX_TEST_SYM=symlinked via symlink path, got: {val!r}"

      with subtest("sandbox entry on cd"):
          machine.send_chars("cd /\n")
          machine.send_chars("cd ~/project\n")
          machine.execute(f"rm -f {project}/env-check")
          machine.send_chars(f"${c.writeEnv "SANDBOX_TEST" "{project}/env-check"}\n")
          machine.wait_until_succeeds(f"test -s {project}/env-check", timeout=15)
          val = machine.succeed(f"cat {project}/env-check").strip()
          assert val == "hello", f"Expected SANDBOX_TEST=hello, got: {val!r}"

      with subtest("SHLVL increases inside sandbox"):
          machine.execute(f"rm -f {project}/shlvl-inside")
          machine.send_chars(f"${c.writeShlvl "{project}/shlvl-inside"}\n")
          machine.wait_until_succeeds(f"test -s {project}/shlvl-inside", timeout=5)
          inside_shlvl = int(machine.succeed(f"cat {project}/shlvl-inside").strip())
          assert inside_shlvl > initial_shlvl, \
              f"Expected SHLVL > {initial_shlvl} inside sandbox, got {inside_shlvl}"

      with subtest("bind mount is accessible inside sandbox"):
          machine.execute(f"rm -f {project}/bind-read-check")
          machine.send_chars(f"${c.readFile "/home/alice/.cache/bind-test-file" "{project}/bind-read-check"}\n")
          machine.wait_until_succeeds(f"test -s {project}/bind-read-check", timeout=10)
          val = machine.succeed(f"cat {project}/bind-read-check").strip()
          assert val == "bind-works", \
              f"Expected 'bind-works' from bind-mounted $HOME/.cache, got: {val!r}"

          machine.send_chars("${c.writeLiteral "written-from-sandbox" "/home/alice/.cache/sandbox-wrote"}\n")
          machine.wait_until_succeeds("test -s /home/alice/.cache/sandbox-wrote", timeout=10)
          val = machine.succeed("cat /home/alice/.cache/sandbox-wrote").strip()
          assert val == "written-from-sandbox", \
              f"Expected 'written-from-sandbox' through bind mount, got: {val!r}"

      with subtest("sandbox exit on cd out"):
          machine.send_chars("cd /\n")
          machine.execute("rm -f /tmp/env-after")
          machine.send_chars("${c.writeEnvOrUnset "SANDBOX_TEST" "/tmp/env-after"}\n")
          machine.wait_until_succeeds("test -s /tmp/env-after", timeout=15)
          val = machine.succeed("cat /tmp/env-after").strip()
          assert val == "unset", \
              f"Expected SANDBOX_TEST to be unset after exit, got: {val!r}"

      with subtest("SHLVL decreases after sandbox exit"):
          machine.execute("rm -f /tmp/shlvl-outside")
          machine.send_chars("${c.writeShlvl "/tmp/shlvl-outside"}\n")
          machine.wait_until_succeeds("test -s /tmp/shlvl-outside", timeout=5)
          outside_shlvl = int(machine.succeed("cat /tmp/shlvl-outside").strip())
          assert outside_shlvl == initial_shlvl, \
              f"Expected SHLVL == {initial_shlvl} after exit, got {outside_shlvl}"

      with subtest("re-entry works"):
          machine.send_chars("cd ~/project\n")
          machine.execute(f"rm -f {project}/reentry-check")
          machine.send_chars(f"${c.writeEnv "SANDBOX_TEST" "{project}/reentry-check"}\n")
          machine.wait_until_succeeds(f"test -s {project}/reentry-check", timeout=10)
          val = machine.succeed(f"cat {project}/reentry-check").strip()
          assert val == "hello", \
              f"Expected SANDBOX_TEST=hello on re-entry, got: {val!r}"

      with subtest("sandbox entry on cd into subdirectory"):
          machine.send_chars("cd /\n")
          machine.send_chars("cd ~/project/subdir\n")
          machine.execute(f"rm -f {project}/subdir-check")
          machine.send_chars(f"${c.writeEnv "SANDBOX_TEST" "{project}/subdir-check"}\n")
          machine.wait_until_succeeds(f"test -s {project}/subdir-check", timeout=15)
          val = machine.succeed(f"cat {project}/subdir-check").strip()
          assert val == "hello", \
              f"Expected SANDBOX_TEST=hello in subdir, got: {val!r}"

      with subtest("sandbox activates after direnv allow from within project"):
          machine.send_chars("cd /\n")
          machine.send_chars("cd ~/project2\n")
          machine.send_chars("direnv allow .\n")
          machine.execute("rm -f /home/alice/project2/allow-check")
          machine.send_chars("${c.writeEnv "SANDBOX_TEST2" "/home/alice/project2/allow-check"}\n")
          machine.wait_until_succeeds("test -s /home/alice/project2/allow-check", timeout=15)
          val = machine.succeed("cat /home/alice/project2/allow-check").strip()
          assert val == "world", \
              f"Expected SANDBOX_TEST2=world after direnv allow, got: {val!r}"

      # --- direnv-sandbox off/on tests ---

      with subtest("direnv-sandbox off disables sandbox"):
          machine.send_chars("cd /\n")
          machine.send_chars("direnv-sandbox off ~/project\n")
          machine.send_chars("cd ~/project\n")
          machine.execute("rm -f /tmp/nosandbox-env")
          machine.send_chars("${c.writeEnv "SANDBOX_TEST" "/tmp/nosandbox-env"}\n")
          machine.wait_until_succeeds("test -s /tmp/nosandbox-env", timeout=10)
          val = machine.succeed("cat /tmp/nosandbox-env").strip()
          assert val == "hello", \
              f"Expected SANDBOX_TEST=hello (unsandboxed), got: {val!r}"

          machine.execute("rm -f /tmp/sandbox-var")
          machine.send_chars("${c.writeEnvOrUnset "SANDBOX" "/tmp/sandbox-var"}\n")
          machine.wait_until_succeeds("test -s /tmp/sandbox-var", timeout=5)
          val = machine.succeed("cat /tmp/sandbox-var").strip()
          assert val == "unset", \
              f"Expected SANDBOX to be unset (no sandbox), got: {val!r}"

      with subtest("direnv unloads when leaving disabled-sandbox dir"):
          machine.send_chars("cd /\n")
          machine.execute("rm -f /tmp/unload-check")
          machine.send_chars("${c.writeEnvOrUnset "SANDBOX_TEST" "/tmp/unload-check"}\n")
          machine.wait_until_succeeds("test -s /tmp/unload-check", timeout=10)
          val = machine.succeed("cat /tmp/unload-check").strip()
          assert val == "unset", \
              f"Expected SANDBOX_TEST to be unset after leaving, got: {val!r}"

      with subtest("direnv-sandbox on re-enables sandbox"):
          machine.send_chars("direnv-sandbox on ~/project\n")
          machine.send_chars("cd ~/project\n")
          machine.execute(f"rm -f {project}/sandbox-back")
          machine.send_chars(f"${c.writeEnv "SANDBOX_TEST" "{project}/sandbox-back"}\n")
          machine.wait_until_succeeds(f"test -s {project}/sandbox-back", timeout=10)
          val = machine.succeed(f"cat {project}/sandbox-back").strip()
          assert val == "hello", \
              f"Expected SANDBOX_TEST=hello after re-enable, got: {val!r}"

          machine.execute(f"rm -f {project}/shlvl-reenabled")
          machine.send_chars(f"${c.writeShlvl "{project}/shlvl-reenabled"}\n")
          machine.wait_until_succeeds(f"test -s {project}/shlvl-reenabled", timeout=5)
          reenabled_shlvl = int(machine.succeed(f"cat {project}/shlvl-reenabled").strip())
          assert reenabled_shlvl > initial_shlvl, \
              f"Expected SHLVL > {initial_shlvl} after re-enable, got {reenabled_shlvl}"

      with subtest("direnv-sandbox on activates sandbox when already in project dir"):
          machine.send_chars("cd ~\n")
          machine.send_chars("direnv allow ~/project\n")
          machine.send_chars("direnv-sandbox off ~/project\n")
          machine.send_chars("cd ~/project\n")
          machine.send_chars("direnv-sandbox on ~/project\n")
          machine.execute(f"rm -f {project}/on-inside-sandbox")
          machine.send_chars(f"${c.writeEnv "SANDBOX" "{project}/on-inside-sandbox"}\n")
          machine.wait_until_succeeds(f"test -s {project}/on-inside-sandbox", timeout=15)
          val = machine.succeed(f"cat {project}/on-inside-sandbox").strip()
          assert val == "1", \
              f"Expected SANDBOX=1 after re-enable from inside project dir, got: {val!r}"

      with subtest("direnv-sandbox off refuses to run inside sandbox"):
          machine.execute(f"rm -f {project}/off-inside")
          machine.send_chars(f"${c.captureStderr "direnv-sandbox off" "{project}/off-inside"}\n")
          machine.wait_until_succeeds(f"test -s {project}/off-inside", timeout=5)
          output = machine.succeed(f"cat {project}/off-inside").strip()
          assert "cannot" in output and "sandbox" in output, \
              f"Expected sandbox error when running off inside sandbox, got: {output!r}"
          assert f"direnv-sandbox off {project}" in output, \
              f"Expected hint with full command, got: {output!r}"

      with subtest("disabled dir is read-only inside sandbox"):
          machine.execute(f"rm -f {project}/ro-check")
          machine.send_chars(f"${c.captureStderr "touch /home/alice/.local/share/direnv-sandbox/disabled/fakehash" "{project}/ro-check"}\n")
          machine.wait_until_succeeds(f"test -s {project}/ro-check", timeout=5)
          output = machine.succeed(f"cat {project}/ro-check").strip()
          assert "Read-only" in output or "Permission denied" in output or "read-only" in output, \
              f"Expected filesystem error writing to disabled dir, got: {output!r}"
    '';
  };
}
