# Shell-aware base module for direnv-sandbox VM tests.
#
# Provides:
#   - Preamble snippet: fast_retry monkey-patch, boot + TTY login, initial
#     SHLVL capture, direnv allow/deny for project dirs.
#   - `c` (shell command encodings) and `shell` exposed to all imported test
#     modules via `_module.args`.
{ shell }:
{ lib, ... }:
let
  c = import ../shell-commands.nix { inherit shell; };
in
{
  _module.args.c = c;
  _module.args.shell = shell;

  testScriptSnippets = lib.mkBefore [
    ''
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
    ''
  ];
}
