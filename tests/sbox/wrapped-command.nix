# Regression test: appending a command to the *module-wrapped* sbox must run
# that command, not silently drop into an interactive shell.
#
# The wrapper (wrappers.lib.wrapPackage) prepends module-configured args. If it
# fails to forward "$@", the user's command is discarded and sbox starts a
# shell — exactly what `sbox false` did after the wrappers bump. The bare
# sbox.nix package forwards "$@" in its own argv loop, so only the wrapped
# package can catch this.
#
# Every invocation redirects stdin from /dev/null and is bounded by `timeout`,
# so the regression (a dropped command falling into an interactive shell) fails
# fast on EOF instead of hanging the test.
{
  testScriptSnippets = [
    ''
      def wrapped_sbox(argv):
          return machine.execute(
              f"su - alice -c 'cd \"{project}\" && timeout 60 sbox {argv} < /dev/null'"
          )

      with subtest("wrapped sbox: appended command runs (not dropped for a shell)"):
          exit_code, output = wrapped_sbox("echo wrapped-hello")
          assert exit_code == 0, \
              f"Expected 'sbox echo' to exit 0, got exit_code={exit_code}, output={output!r}"
          assert "wrapped-hello" in output, \
              f"Expected wrapped sbox to run the appended command, got: {output!r}"

      with subtest("wrapped sbox: command exit status propagates (sbox false)"):
          # A dropped command would start a shell that reads EOF and exits 0.
          exit_code, output = wrapped_sbox("false")
          assert exit_code == 1, \
              f"Expected 'sbox false' to exit 1, got exit_code={exit_code}, output={output!r}"

      with subtest("wrapped sbox: args after the command reach the command, not sbox"):
          exit_code, output = wrapped_sbox("echo nested --flag")
          assert exit_code == 0, \
              f"Expected 'sbox echo nested --flag' to exit 0, got exit_code={exit_code}, output={output!r}"
          assert "nested --flag" in output, \
              f"Expected 'nested --flag' echoed back, got: {output!r}"
          assert "Usage: sbox" not in output, \
              f"Expected command output, not sbox usage, got: {output!r}"
    ''
  ];
}
