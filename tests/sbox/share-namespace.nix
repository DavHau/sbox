{
  testScriptSnippets = [
    ''
      def write_alice_script(host_path, body):
          import base64
          machine.succeed(
              f"echo '{base64.b64encode(body.encode()).decode()}' | base64 -d > '{host_path}'"
          )
          machine.succeed(f"chmod +x '{host_path}'")
          machine.succeed(f"chown alice:users '{host_path}'")

      with subtest("share-namespace: second sbox in same cwd joins existing namespace"):
          # Leader writes a tmpfs marker, signals readiness on a project-dir
          # file (bind-mounted, visible to host), then sleeps with a unique
          # argv. A joiner that truly shares the leader's mount + pid
          # namespaces will:
          #   1) read /tmp/leader-marker  (mount ns shared)
          #   2) see the leader's sleep process via ps  (pid ns shared)
          machine.succeed(
              f"rm -f '{project}/leader.ready' '{project}/joiner-saw-marker' '{project}/joiner-saw-ps'"
          )

          # Inner scripts live under the project dir so the sandbox can read
          # them (host /tmp is not bind-mounted into the sbox).
          leader_body = (
              "#!/usr/bin/env bash\n"
              "set -e\n"
              "echo leader-tmpfs-secret > /tmp/leader-marker\n"
              f"touch '{project}/leader.ready'\n"
              "exec -a SBOX_LEADER_SENTINEL bash -c 'while :; do sleep 60; done'\n"
          )
          write_alice_script(f"{project}/_leader-inner.sh", leader_body)

          launcher_body = (
              "#!/usr/bin/env bash\n"
              f"cd '{project}'\n"
              f"exec sbox --share bash '{project}/_leader-inner.sh'\n"
          )
          write_alice_script("/tmp/leader-launch.sh", launcher_body)

          machine.succeed(
              "su - alice -c 'setsid nohup /tmp/leader-launch.sh </dev/null >/tmp/leader.log 2>&1 &'"
          )
          machine.wait_until_succeeds(f"test -f \"{project}/leader.ready\"", timeout=30)

          joiner_body = (
              "#!/usr/bin/env bash\n"
              "set -e\n"
              "cat /tmp/leader-marker > /tmp/joiner-saw-marker || echo MISSING > /tmp/joiner-saw-marker\n"
              "(ps -ef | grep SBOX_LEADER_SENTINEL | grep -v grep) > /tmp/joiner-saw-ps || echo NOPS > /tmp/joiner-saw-ps\n"
              f"cp /tmp/joiner-saw-marker '{project}/joiner-saw-marker'\n"
              f"cp /tmp/joiner-saw-ps '{project}/joiner-saw-ps'\n"
          )
          write_alice_script(f"{project}/_joiner-inner.sh", joiner_body)
          joiner_launch = (
              "#!/usr/bin/env bash\n"
              f"cd '{project}'\n"
              f"exec sbox --share bash '{project}/_joiner-inner.sh'\n"
          )
          write_alice_script("/tmp/joiner-launch.sh", joiner_launch)

          machine.succeed("su - alice -c '/tmp/joiner-launch.sh'")

          marker = machine.succeed(f"cat '{project}/joiner-saw-marker'").strip()
          assert marker == "leader-tmpfs-secret", \
              f"Joiner did not see leader's tmpfs file. Got: {marker!r}"

          ps_out = machine.succeed(f"cat '{project}/joiner-saw-ps'").strip()
          assert "SBOX_LEADER_SENTINEL" in ps_out, \
              f"Joiner did not see leader's sleep process via ps. Got: {ps_out!r}"

          machine.execute("pkill -9 -f SBOX_LEADER_SENTINEL || true")
          machine.execute("pkill -9 -f leader-launch.sh || true")
          machine.execute("pkill -9 -f _leader-inner.sh || true")

      with subtest("share-namespace: joiner in different cwd does NOT join"):
          # A joiner started from a *different* directory must get its own
          # fresh namespace — verified by absence of the leader marker in
          # /tmp.
          machine.succeed(f"rm -f '{project}/leader.ready'")
          machine.succeed("mkdir -p /home/alice/other && chown alice:users /home/alice/other")

          machine.succeed(
              "su - alice -c 'setsid nohup /tmp/leader-launch.sh </dev/null >/tmp/leader.log 2>&1 &'"
          )
          machine.wait_until_succeeds(f"test -f \"{project}/leader.ready\"", timeout=30)

          other_inner = (
              "#!/usr/bin/env bash\n"
              "cat /tmp/leader-marker 2>&1 || echo MISSING\n"
          )
          write_alice_script("/home/alice/other/_inner.sh", other_inner)
          other_launch = (
              "#!/usr/bin/env bash\n"
              "cd /home/alice/other\n"
              "exec sbox --share bash /home/alice/other/_inner.sh\n"
          )
          write_alice_script("/tmp/other-launch.sh", other_launch)

          val = machine.succeed("su - alice -c '/tmp/other-launch.sh'").strip()
          assert "MISSING" in val or "No such file" in val, \
              f"Sandbox in different cwd unexpectedly joined leader. Got: {val!r}"

          machine.execute("pkill -9 -f SBOX_LEADER_SENTINEL || true")
          machine.execute("pkill -9 -f leader-launch.sh || true")
          machine.execute("pkill -9 -f _leader-inner.sh || true")
    ''
  ];
}
