{ c, ... }:
{
  testScriptSnippets = [
    ''
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
    ''
  ];
}
