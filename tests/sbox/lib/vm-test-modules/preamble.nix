# Shared testScript preamble for sbox VM tests.
#
# Provides the parts of the test script that are independent of which sbox
# package is under test: the fast_retry monkey-patch, the `project` var,
# `wait_for_unit("multi-user.target")`, and the `sbox_run` helper.
#
# Imported by both base.nix (bare sbox package) and wrapped-base.nix
# (module-wrapped sbox package) so the helper lives in exactly one place.
{ lib, ... }:
{
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
              time.sleep(0.1)
          elapsed = time.monotonic() - start_time
          if not fn(True):
              raise RequestedAssertionFailed(
                  f"action timed out after {elapsed:.2f} seconds (timeout={timeout_seconds})"
              )

      test_driver.machine.retry = fast_retry

      project = "/home/alice/my project"

      machine.wait_for_unit("multi-user.target")

      def sbox_run(cmd, args=""):
          """Run a command inside sbox and return its stdout."""
          import base64
          result_file = f"{project}/result"
          cmd_file = f"{project}/_cmd.sh"
          machine.execute(f"rm -f '{result_file}'")
          # Write inner command to a script inside the project dir (visible in sandbox).
          inner = f"({cmd}) > '{result_file}'\n"
          machine.succeed(f"echo '{base64.b64encode(inner.encode()).decode()}' | base64 -d > '{cmd_file}'")
          # Write the sbox invocation to a host script to avoid nested quoting issues.
          outer = f'cd "{project}" && sbox {args} bash "{cmd_file}"\n'
          machine.succeed(f"echo '{base64.b64encode(outer.encode()).decode()}' | base64 -d > /tmp/sbox-run.sh")
          machine.succeed("su - alice -c 'bash /tmp/sbox-run.sh'")
          return machine.succeed(f"cat '{result_file}'").strip()
    ''
  ];
}
