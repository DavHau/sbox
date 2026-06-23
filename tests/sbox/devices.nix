# Device passthrough: default /dev/kfd mount and the --dev-bind CLI flag.
#
# The VM has no real GPU, so device nodes are faked with a character device
# cloning /dev/zero (major 1, minor 5). If a bind grants device *access*
# (bwrap --dev-bind, not a plain nodev --bind), opening the node succeeds and
# reads yield NUL bytes; otherwise open() fails with EACCES on the nodev mount.
{
  testScriptSnippets = [
    ''
      with subtest("devices: /dev/kfd is mounted by default with device access"):
          # /dev/kfd is the AMD KFD (ROCm/HIP) compute node, mounted by default
          # when present. Fake it, then confirm it is readable inside the sandbox.
          machine.succeed("rm -f /dev/kfd && mknod /dev/kfd c 1 5 && chmod 666 /dev/kfd")
          val = sbox_run(
              "if head -c 4 /dev/kfd >/dev/null 2>&1; then echo READABLE; else echo UNREADABLE; fi"
          )
          assert val == "READABLE", \
              f"Expected /dev/kfd readable (device access) inside sandbox, got: {val!r}"
          machine.succeed("rm -f /dev/kfd")

      with subtest("devices: /dev/kvm is mounted by default with device access"):
          # /dev/kvm is the KVM virtualization node, mounted by default when
          # present. Fake it, then confirm it is readable inside the sandbox.
          machine.succeed("rm -f /dev/kvm && mknod /dev/kvm c 1 5 && chmod 666 /dev/kvm")
          val = sbox_run(
              "if head -c 4 /dev/kvm >/dev/null 2>&1; then echo READABLE; else echo UNREADABLE; fi"
          )
          assert val == "READABLE", \
              f"Expected /dev/kvm readable (device access) inside sandbox, got: {val!r}"
          machine.succeed("rm -f /dev/kvm")

      with subtest("devices: --dev-bind exposes an extra device node with access"):
          machine.succeed("rm -f /dev/sboxdev && mknod /dev/sboxdev c 1 5 && chmod 666 /dev/sboxdev")
          val = sbox_run(
              "if head -c 4 /dev/sboxdev >/dev/null 2>&1; then echo READABLE; else echo UNREADABLE; fi",
              args="--dev-bind /dev/sboxdev",
          )
          assert val == "READABLE", \
              f"Expected --dev-bind device readable inside sandbox, got: {val!r}"
          machine.succeed("rm -f /dev/sboxdev")

      with subtest("devices: --dev-bind-try silently skips a missing source"):
          # Should not error even though the source does not exist.
          val = sbox_run(
              "echo ok",
              args="--dev-bind-try /dev/does-not-exist",
          )
          assert val == "ok", \
              f"Expected --dev-bind-try to skip missing source, got: {val!r}"

      with subtest("devices: plain --bind does NOT grant device access (nodev)"):
          # Demonstrates why --dev-bind is required: a normal bind mounts the
          # node nodev, so opening the device fails even though the node appears.
          machine.succeed("rm -f /dev/sboxdev2 && mknod /dev/sboxdev2 c 1 5 && chmod 666 /dev/sboxdev2")
          val = sbox_run(
              "if head -c 4 /dev/sboxdev2 >/dev/null 2>&1; then echo READABLE; else echo UNREADABLE; fi",
              args="--bind /dev/sboxdev2 /dev/sboxdev2",
          )
          assert val == "UNREADABLE", \
              f"Expected plain --bind to deny device access (nodev), got: {val!r}"
          machine.succeed("rm -f /dev/sboxdev2")
    ''
  ];
}
