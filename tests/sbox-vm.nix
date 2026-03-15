# VM tests for sbox (the bubblewrap sandbox wrapper) independent of direnv.
# Tests: basic sandboxing, --host-port, --sandbox-port, --network host.
{ pkgs, lib, self }:
let
  sbox = self.packages.${pkgs.system}.sbox;
  pythonWithPkgs = pkgs.python3.withPackages (ps: [ ps.requests ]);
in
pkgs.testers.runNixOSTest {
  name = "sbox";

  nodes.machine =
    { pkgs, ... }:
    {
      # No networking needed — sbox creates its own isolated namespace.
      networking.useDHCP = false;

      users.users.alice = {
        isNormalUser = true;
        password = "foobar";
        shell = pkgs.bashInteractive;
      };

      environment.systemPackages = [
        sbox
        pythonWithPkgs
        pkgs.socat
        pkgs.curl
        pkgs.netcat.nc
      ];

      system.activationScripts.createProject = {
        deps = [ "users" ];
        text = ''
          mkdir -p /home/alice/project
          chown -R alice:users /home/alice/project
        '';
      };
    };

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
            time.sleep(0.1)
        elapsed = time.monotonic() - start_time
        if not fn(True):
            raise RequestedAssertionFailed(
                f"action timed out after {elapsed:.2f} seconds (timeout={timeout_seconds})"
            )

    test_driver.machine.retry = fast_retry

    project = "/home/alice/project"

    machine.wait_for_unit("multi-user.target")

    def sbox_run(cmd, args=""):
        """Run a command inside sbox and return its stdout."""
        marker = "/tmp/sbox-result"
        machine.execute(f"rm -f {marker}")
        machine.succeed(
            f"su - alice -c 'cd {project} && sbox {args} {project} -- bash -c \"({cmd}) > {project}/result\"'"
        )
        return machine.succeed(f"cat {project}/result").strip()

    with subtest("basic sandbox: SANDBOX=1 is set"):
        val = sbox_run("echo \$SANDBOX")
        assert val == "1", f"Expected SANDBOX=1, got: {val!r}"

    with subtest("basic sandbox: project dir is writable"):
        sbox_run(f"touch {project}/write-test")
        machine.succeed(f"test -f {project}/write-test")

    with subtest("basic sandbox: /tmp is isolated"):
        machine.succeed("su - alice -c 'echo host-secret > /tmp/host-file'")
        val = sbox_run("cat /tmp/host-file 2>&1 || echo MISSING")
        assert "MISSING" in val or "No such file" in val, \
            f"Expected /tmp to be isolated, got: {val!r}"

    with subtest("basic sandbox: /nix is available"):
        val = sbox_run("test -d /nix/store && echo yes")
        assert val == "yes", f"Expected /nix/store to exist, got: {val!r}"

    with subtest("basic sandbox: DNS resolution works"):
        val = sbox_run("cat /etc/resolv.conf")
        assert "10.0.2.3" in val, \
            f"Expected slirp4netns DNS resolver in resolv.conf, got: {val!r}"

    with subtest("allow-port: sandbox can reach host service"):
        # Start a TCP server on the host
        machine.succeed(
            "su - alice -c 'echo host-hello | nc -l 127.0.0.1 7777 &' >&2"
        )

        val = sbox_run(
            "nc -w 1 127.0.0.1 7777 || echo FAIL",
            "--allow-port 7777",
        )
        assert "host-hello" in val, \
            f"Expected 'host-hello' from host service via --allow-port, got: {val!r}"

    with subtest("expose-port: host can reach sandbox service"):
        # Run a TCP server inside the sandbox on port 8888,
        # then verify the host can reach it via 127.0.0.1:8888.
        machine.succeed(
            f"su - alice -c '"
            f"sbox --expose-port 8888 {project} -- bash -c \""
            f"echo sandbox-hello | nc -l 0.0.0.0 8888 &"
            f"sleep 1; "
            f"echo LISTENING > {project}/sandbox-ready; "
            f"sleep 30"
            f"\" &' >&2"
        )

        machine.wait_until_succeeds(f"test -s {project}/sandbox-ready", timeout=30)
        val = machine.wait_until_succeeds("nc -w 1 127.0.0.1 8888", timeout=15).strip()
        assert "sandbox-hello" in val, \
            f"Expected 'sandbox-hello' from sandbox service via --expose-port, got: {val!r}"

    with subtest("basic sandbox: uid and gid are preserved"):
        host_id = machine.succeed("su - alice -c 'id -u'").strip()
        host_gid = machine.succeed("su - alice -c 'id -g'").strip()
        sandbox_id = sbox_run("id -u")
        sandbox_gid = sbox_run("id -g")
        assert sandbox_id == host_id, \
            f"Expected UID {host_id} inside sandbox, got: {sandbox_id!r}"
        assert sandbox_gid == host_gid, \
            f"Expected GID {host_gid} inside sandbox, got: {sandbox_gid!r}"

    with subtest("network host: sandbox shares host network"):
        val = sbox_run(
            "ip link show lo >/dev/null 2>&1 && echo has-lo || echo no-lo",
            "--network host",
        )
        assert val == "has-lo", \
            f"Expected host loopback in --network host mode, got: {val!r}"

        # Verify there is no tap0 (slirp4netns device) in host-network mode
        val = sbox_run(
            "ip link show tap0 2>&1 && echo has-tap || echo no-tap",
            "--network host",
        )
        assert "no-tap" in val, \
            f"Expected no tap0 in --network host mode, got: {val!r}"
  '';
}
