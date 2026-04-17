# VM tests for sbox (the bubblewrap sandbox wrapper) independent of direnv.
# Tests: basic sandboxing, --host-port, --sandbox-port, --network host.
{ sboxPackage }:
{ lib, testers, python3, socat, curl, netcat, callPackage, ... }:
let
  sbox = callPackage sboxPackage { };
  pythonWithPkgs = python3.withPackages (ps: [ ps.requests ]);
in
testers.runNixOSTest {
  name = "sbox";

  nodes.machine =
    { pkgs, ... }:
    {
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

    with subtest("basic sandbox: SANDBOX=1 is set"):
        val = sbox_run("echo $SANDBOX")
        assert val == "1", f"Expected SANDBOX=1, got: {val!r}"

    with subtest("basic sandbox: project dir is writable"):
        sbox_run(f"touch '{project}/write-test'")
        machine.succeed(f"test -f '{project}/write-test'")

    with subtest("basic sandbox: /tmp is isolated"):
        machine.succeed("su - alice -c 'echo host-secret > /tmp/host-file'")
        val = sbox_run("cat /tmp/host-file 2>&1 || echo MISSING")
        assert "MISSING" in val or "No such file" in val, \
            f"Expected /tmp to be isolated, got: {val!r}"

    with subtest("basic sandbox: bash PS1 is prefixed with [sandbox]"):
        # Write a helper script to avoid quoting issues
        machine.succeed(f"echo 'echo \"$PS1\" > \"{project}/ps1-out\"' > \"{project}/check-ps1.sh\"")
        machine.succeed(f"chmod +x \"{project}/check-ps1.sh\"")
        machine.succeed(
            f"su - alice -c 'cd \"{project}\" && sbox bash -i \"{project}/check-ps1.sh\"'"
        )
        val = machine.succeed(f"cat \"{project}/ps1-out\"").strip()
        assert val.startswith("[sandbox]"), \
            f"Expected bash PS1 to start with '[sandbox]', got: {val!r}"

    with subtest("basic sandbox: zsh prompt is prefixed with [sandbox]"):
        machine.succeed(
            f"echo 'print -P \"$PROMPT\" > \"{project}/zsh-prompt-out\"' > \"{project}/check-zsh-prompt.zsh\""
        )
        machine.succeed(f"chmod +x \"{project}/check-zsh-prompt.zsh\"")
        machine.succeed(
            f"su - alice -c 'cd \"{project}\" && sbox zsh -i \"{project}/check-zsh-prompt.zsh\"'"
        )
        val = machine.succeed(f"cat \"{project}/zsh-prompt-out\"").strip()
        assert "[sandbox]" in val, \
            f"Expected zsh prompt to contain '[sandbox]', got: {val!r}"

    with subtest("basic sandbox: fish prompt is prefixed with [sandbox]"):
        machine.succeed(
            f"echo 'fish_prompt > \"{project}/fish-prompt-out\"' > \"{project}/check-fish-prompt.fish\""
        )
        machine.succeed(f"chmod +x \"{project}/check-fish-prompt.fish\"")
        machine.succeed(
            f"su - alice -c 'cd \"{project}\" && sbox fish \"{project}/check-fish-prompt.fish\"'"
        )
        val = machine.succeed(f"cat \"{project}/fish-prompt-out\"").strip()
        assert "[sandbox]" in val, \
            f"Expected fish prompt to contain '[sandbox]', got: {val!r}"

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
        # Run a TCP server inside the sandbox on port 8888 bound to
        # localhost — the socat bridge connects via 127.0.0.1 so this works
        # even though there is no routable guest IP.
        machine.succeed(
            f"su - alice -c '"
            f"cd \"{project}\" && sbox --expose-port 8888 bash -c \""
            f"echo sandbox-hello | nc -l 127.0.0.1 8888 &"
            f"sleep 1; "
            f"echo LISTENING > \\\"{project}/sandbox-ready\\\"; "
            f"sleep 30"
            f"\" &' >&2"
        )

        machine.wait_until_succeeds(f"test -s \"{project}/sandbox-ready\"", timeout=30)
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

    with subtest("persist: data survives across sessions"):
        # First session: write a file into the persisted path (path with space)
        sbox_run(
            "mkdir -p '/home/alice/my state' && echo persist-ok > '/home/alice/my state/marker'",
            "'--persist' '/home/alice/my state'",
        )
        # Second session: verify the file is still there
        val = sbox_run(
            "cat '/home/alice/my state/marker'",
            "'--persist' '/home/alice/my state'",
        )
        assert val == "persist-ok", \
            f"Expected persisted data to survive across sessions, got: {val!r}"

    with subtest("persist: backing dir is created in XDG state dir"):
        project_hash = machine.succeed(
            f"printf '%s\\n' '{project}' | sha256sum | cut -d' ' -f1"
        ).strip()
        machine.succeed(
            f"test -d '/home/alice/.local/state/sbox/{project_hash}/home/alice/my state'"
        )

    with subtest("persist: multiple paths work"):
        sbox_run(
            "echo a > /home/alice/.state1/f1 && echo b > /home/alice/.state2/f2",
            "--persist /home/alice/.state1 --persist /home/alice/.state2",
        )
        val1 = sbox_run("cat /home/alice/.state1/f1", "--persist /home/alice/.state1")
        val2 = sbox_run("cat /home/alice/.state2/f2", "--persist /home/alice/.state2")
        assert val1 == "a", f"Expected 'a' from first persist path, got: {val1!r}"
        assert val2 == "b", f"Expected 'b' from second persist path, got: {val2!r}"

    with subtest("persist: ro-bind inside persisted dir overlays correctly"):
        # Create a host file that should appear read-only inside the persisted dir (path with space)
        machine.succeed("su - alice -c 'mkdir -p \"/home/alice/host state\" && echo host-secret > \"/home/alice/host state/creds\"'")
        # Persist the dir, but ro-bind a file from the host on top of a subpath
        val = sbox_run(
            "cat '/home/alice/test overlay/creds'",
            "'--persist' '/home/alice/test overlay' '--ro-bind' '/home/alice/host state/creds' '/home/alice/test overlay/creds'",
        )
        assert val == "host-secret", \
            f"Expected host file visible inside persisted dir, got: {val!r}"
        # Verify the rest of the persisted dir is still writable
        sbox_run(
            "echo writable > '/home/alice/test overlay/newfile'",
            "'--persist' '/home/alice/test overlay' '--ro-bind' '/home/alice/host state/creds' '/home/alice/test overlay/creds'",
        )
        val = sbox_run(
            "cat '/home/alice/test overlay/newfile'",
            "'--persist' '/home/alice/test overlay'",
        )
        assert val == "writable", \
            f"Expected persisted write to survive, got: {val!r}"

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

    with subtest("share-history: host history files are writable by default"):
        # Create empty history files on the host for all supported paths
        machine.succeed("su - alice -c 'touch /home/alice/.bash_history'")
        machine.succeed("su - alice -c 'touch /home/alice/.zsh_history'")
        machine.succeed("su - alice -c 'mkdir -p /home/alice/.local/share/zsh && touch /home/alice/.local/share/zsh/history'")
        machine.succeed("su - alice -c 'mkdir -p /home/alice/.local/share/fish && touch /home/alice/.local/share/fish/fish_history'")

        # Write from inside the sandbox, verify on the host
        sbox_run("echo sandbox-cmd >> /home/alice/.bash_history")
        val = machine.succeed("cat /home/alice/.bash_history").strip()
        assert "sandbox-cmd" in val, \
            f"Expected sandbox to write to bash history, got: {val!r}"
        sbox_run("echo sandbox-cmd >> /home/alice/.zsh_history")
        val = machine.succeed("cat /home/alice/.zsh_history").strip()
        assert "sandbox-cmd" in val, \
            f"Expected sandbox to write to zsh history, got: {val!r}"
        sbox_run("echo sandbox-cmd >> /home/alice/.local/share/zsh/history")
        val = machine.succeed("cat /home/alice/.local/share/zsh/history").strip()
        assert "sandbox-cmd" in val, \
            f"Expected sandbox to write to zsh XDG history, got: {val!r}"
        sbox_run("echo sandbox-cmd >> /home/alice/.local/share/fish/fish_history")
        val = machine.succeed("cat /home/alice/.local/share/fish/fish_history").strip()
        assert "sandbox-cmd" in val, \
            f"Expected sandbox to write to fish history, got: {val!r}"

    with subtest("history project: history is persisted per-project, not shared with host"):
        # Write something to host history — it should NOT appear in the sandbox
        machine.succeed("su - alice -c 'echo secret-host-cmd > /home/alice/.bash_history'")
        val = sbox_run("cat /home/alice/.bash_history 2>&1 || echo EMPTY", "--history project")
        assert "secret-host-cmd" not in val, \
            f"Expected host history to be isolated from sandbox, got: {val!r}"

        # Write inside the sandbox — it should persist across sessions
        sbox_run("echo sandbox-only-cmd > /home/alice/.bash_history", "--history project")
        val = sbox_run("cat /home/alice/.bash_history", "--history project")
        assert val == "sandbox-only-cmd", \
            f"Expected per-project history to persist across sessions, got: {val!r}"

        # Host history should be untouched
        val = machine.succeed("cat /home/alice/.bash_history").strip()
        assert val == "secret-host-cmd", \
            f"Expected host history to be unchanged, got: {val!r}"

    with subtest("history off: no history persistence across sessions"):
        sbox_run("echo ephemeral-cmd > /home/alice/.bash_history", "--history off")
        val = sbox_run("cat /home/alice/.bash_history 2>&1 || echo EMPTY", "--history off")
        assert "ephemeral-cmd" not in val, \
            f"Expected no history persistence with --history off, got: {val!r}"

    with subtest("jj config: sbox works when ~/.config/jj exists but repos subdir does not"):
        # Reproduces bug: bwrap fails with
        #   "Can't mkdir /home/alice/.config/jj/repos: Read-only file system"
        # because the script ro-binds ~/.config/jj then tries to tmpfs-mount
        # ~/.config/jj/repos on top of the read-only mount.
        machine.succeed("su - alice -c 'rm -rf /home/alice/.config/jj'")
        machine.succeed("su - alice -c 'mkdir -p /home/alice/.config/jj && echo x > /home/alice/.config/jj/config.toml'")
        val = sbox_run("echo jj-ok")
        assert val == "jj-ok", \
            f"Expected sandbox to start with jj config dir present, got: {val!r}"

    # --- --network blocked tests ---

    with subtest("network blocked: no tap0 interface"):
        val = sbox_run(
            "ip link show tap0 2>&1 && echo has-tap || echo no-tap",
            "--network blocked",
        )
        assert "no-tap" in val, \
            f"Expected no tap0 in --network blocked mode, got: {val!r}"

    with subtest("network blocked: loopback is available"):
        val = sbox_run(
            "ip link show lo >/dev/null 2>&1 && echo has-lo || echo no-lo",
            "--network blocked",
        )
        assert val == "has-lo", \
            f"Expected loopback in --network blocked mode, got: {val!r}"

    with subtest("network blocked: cannot reach external network"):
        # 10.0.2.2 is the slirp4netns gateway in normal mode — should be unreachable
        val = sbox_run(
            "ping -c 1 -W 1 10.0.2.2 2>&1 && echo REACHABLE || echo UNREACHABLE",
            "--network blocked",
        )
        assert "UNREACHABLE" in val, \
            f"Expected external network to be unreachable, got: {val!r}"

    with subtest("network blocked: DNS resolution fails"):
        val = sbox_run(
            "cat /etc/resolv.conf",
            "--network blocked",
        )
        assert "10.0.2.3" not in val, \
            f"Expected no slirp4netns DNS in resolv.conf, got: {val!r}"

    with subtest("network blocked: allow-port still works"):
        # Start a TCP server on the host
        machine.succeed(
            "su - alice -c 'echo blocked-host-hello | nc -l 127.0.0.1 7778 &' >&2"
        )

        val = sbox_run(
            "nc -w 1 127.0.0.1 7778 || echo FAIL",
            "--network blocked --allow-port 7778",
        )
        assert "blocked-host-hello" in val, \
            f"Expected 'blocked-host-hello' from host service via --allow-port in blocked mode, got: {val!r}"

    with subtest("network blocked: expose-port still works"):
        # Run a TCP server inside the sandbox on port 8889,
        # then verify the host can reach it via 127.0.0.1:8889.
        machine.succeed(
            f"su - alice -c '"
            f"cd \"{project}\" && sbox --network blocked --expose-port 8889 bash -c \""
            f"echo blocked-sandbox-hello | nc -l 0.0.0.0 8889 &"
            f"sleep 1; "
            f"echo LISTENING > \\\"{project}/blocked-sandbox-ready\\\"; "
            f"sleep 30"
            f"\" &' >&2"
        )

        machine.wait_until_succeeds(f"test -s \"{project}/blocked-sandbox-ready\"", timeout=30)
        val = machine.wait_until_succeeds("nc -w 1 127.0.0.1 8889", timeout=15).strip()
        assert "blocked-sandbox-hello" in val, \
            f"Expected 'blocked-sandbox-hello' from sandbox service via --expose-port in blocked mode, got: {val!r}"

    with subtest("nix-path-skip: PATH entries under /nix but outside /nix/store do not break bwrap"):
        # /nix is already mounted via --ro-bind /nix /nix.
        # If the PATH loop only skips /nix/store/* (not all /nix/*),
        # a PATH entry like /nix/var/nix/profiles/default/bin causes bwrap
        # to attempt a redundant bind-mount onto a symlink destination that
        # lives under the already-mounted /nix, which fails.
        #
        # Reproduce by creating a symlink under /nix/ (mimicking a NixOS
        # profile) whose target has a bin/ directory, then putting that
        # bin/ in PATH.
        machine.succeed(
            "mkdir -p /tmp/fake-profile/bin && "
            "ln -sfn /tmp/fake-profile /nix/var/nix/profiles/sbox-test-profile"
        )
        val = machine.succeed(
            f"su - alice -c 'export PATH=\"/nix/var/nix/profiles/sbox-test-profile/bin:$PATH\"; cd \"{project}\" && sbox echo nix-path-ok'"
        ).strip()
        assert "nix-path-ok" in val, \
            f"Expected sbox to handle /nix/var/... in PATH, got: {val!r}"
  '';
}
