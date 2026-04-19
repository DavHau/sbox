{
  testScriptSnippets = [
    ''
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
    ''
  ];
}
