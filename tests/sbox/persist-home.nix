{ ... }:
{
  testScriptSnippets = [
    ''
      with subtest("--persist HOME: data survives across sessions"):
          sbox_run(
              "echo home-persist-ok > /home/alice/marker-in-home",
              "--persist /home/alice",
          )
          val = sbox_run(
              "cat /home/alice/marker-in-home",
              "--persist /home/alice",
          )
          assert val == "home-persist-ok", \
              f"Expected persisted HOME file to survive across sessions, got: {val!r}"

      with subtest("--persist HOME: sandbox writes do NOT leak to host HOME"):
          # Clean any stale host artefact.
          machine.succeed("rm -f /home/alice/leaked-from-sandbox")
          sbox_run(
              "echo from-sandbox > /home/alice/leaked-from-sandbox",
              "--persist /home/alice",
          )
          # File must not appear in the real host HOME.
          rc, _ = machine.execute("test -e /home/alice/leaked-from-sandbox")
          assert rc != 0, \
              "Sandbox-written file leaked into host HOME under --persist HOME"

      with subtest("--persist HOME: host HOME files are NOT visible inside sandbox"):
          # Create a file directly on the host HOME, outside the project dir.
          machine.succeed("su - alice -c 'echo host-only > /home/alice/host-only-file'")
          rc, out = machine.execute(
              "su - alice -c 'cd \"" + project + "\" && "
              "sbox --persist /home/alice -- test -e /home/alice/host-only-file'"
          )
          assert rc != 0, \
              f"Host HOME file leaked into sandbox under --persist HOME (rc={rc}, out={out!r})"

      with subtest("--persist HOME: project dir remains accessible inside sandbox"):
          val = sbox_run(
              "echo project-write-ok > result-in-project && cat result-in-project",
              "--persist /home/alice",
          )
          assert val == "project-write-ok", \
              f"Project dir should stay read-write when --persist HOME is active, got: {val!r}"
    ''
  ];
}
