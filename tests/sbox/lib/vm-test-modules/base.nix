# Base module for sbox VM tests: node config + preamble.
#
# Provides:
#   - `machine` with alice user, sbox + common packages, and /home/alice/my project
#   - testScript preamble: fast_retry monkey-patch, `project` var,
#     `wait_for_unit("multi-user.target")`, and the `sbox_run` helper.
{ sbox, pythonWithPkgs }:
{ pkgs, lib, ... }:
{
  nodes.machine = {
    # No networking needed — sbox creates its own isolated namespace.
    networking.useDHCP = false;

    users.users.alice = {
      isNormalUser = true;
      password = "foobar";
      shell = pkgs.bash;
    };

    environment.systemPackages = [
      sbox
      pythonWithPkgs
      pkgs.socat
      pkgs.curl
      pkgs.netcat.nc
      pkgs.iproute2
      pkgs.iputils
      pkgs.zsh
      pkgs.fish
    ];

    system.activationScripts.createProject = {
      deps = [ "users" ];
      text = ''
        mkdir -p "/home/alice/my project"
        chown -R alice:users "/home/alice/my project"
      '';
    };
  };

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
