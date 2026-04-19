{
  testScriptSnippets = [
    ''
      with subtest("command syntax: first non-option arg is the command"):
          # sbox echo hello → should run 'echo hello' inside the sandbox
          val = machine.succeed(
              f"su - alice -c 'cd \"{project}\" && sbox echo hello'"
          ).strip()
          assert "hello" in val, \
              f"Expected 'hello' from 'sbox echo hello', got: {val!r}"

      with subtest("command syntax: --flag after command is passed to command, not sbox"):
          # sbox echo --help → should print '--help', not sbox's help text
          val = machine.succeed(
              f"su - alice -c 'cd \"{project}\" && sbox echo --help'"
          ).strip()
          assert "--help" in val, \
              f"Expected '--help' echoed back, got: {val!r}"
          assert "Usage: sbox" not in val, \
              f"Expected command's --help, not sbox usage, got: {val!r}"

      with subtest("command syntax: unknown --flag is rejected, not treated as command"):
          # sbox --bogus should error, not try to execute '--bogus'
          exit_code, output = machine.execute(
              f"su - alice -c 'cd \"{project}\" && sbox --bogus 2>&1'"
          )
          assert exit_code != 0, \
              f"Expected non-zero exit for unknown flag --bogus, got exit_code={exit_code}"
          assert "unknown" in output.lower() or "unrecognized" in output.lower(), \
              f"Expected error message about unknown option, got: {output!r}"

      with subtest("command syntax: --chdir sets the project directory"):
          # Run sbox from /tmp with --chdir pointing to the project.
          # Without proper --chdir, PROJECT_DIR would be /tmp and the
          # project dir would NOT be bind-mounted rw → write would fail.
          machine.succeed(f"rm -f '{project}/chdir-test'")
          machine.succeed(
              f"su - alice -c 'cd /tmp && sbox --chdir \"{project}\" bash -c \"touch \\\"{project}/chdir-test\\\"\"'"
          )
          machine.succeed(f"test -f '{project}/chdir-test'")
    ''
  ];
}
