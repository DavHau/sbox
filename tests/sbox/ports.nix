{
  testScriptSnippets = [
    ''
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
    ''
  ];
}
