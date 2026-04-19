{
  testScriptSnippets = [
    ''
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

      with subtest("basic sandbox: uid and gid are preserved"):
          host_id = machine.succeed("su - alice -c 'id -u'").strip()
          host_gid = machine.succeed("su - alice -c 'id -g'").strip()
          sandbox_id = sbox_run("id -u")
          sandbox_gid = sbox_run("id -g")
          assert sandbox_id == host_id, \
              f"Expected UID {host_id} inside sandbox, got: {sandbox_id!r}"
          assert sandbox_gid == host_gid, \
              f"Expected GID {host_gid} inside sandbox, got: {sandbox_gid!r}"
    ''
  ];
}
