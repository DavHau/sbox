{
  testScriptSnippets = [
    ''
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
    ''
  ];
}
