{
  testScriptSnippets = [
    ''
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
    ''
  ];
}
