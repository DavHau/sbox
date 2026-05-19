{ c, ... }:
{
  testScriptSnippets = [
    ''
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
    ''
  ];
}
