{ c, ... }:
{
  testScriptSnippets = [
    ''
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
    ''
  ];
}
