{ c, ... }:
{
  testScriptSnippets = [
    ''
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
    ''
  ];
}
