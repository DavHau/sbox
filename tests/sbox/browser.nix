# Browser-in-sandbox VM test.
#
# omp's browser tool drives headless Chromium and waits for the page's network
# to go idle (Puppeteer `networkidle2`). Inside sbox this used to fail with
# "Navigation timeout of 30000 ms exceeded" because slirp4netns was started with
# `-6` (experimental IPv6): a few seconds after the sandbox starts, slirp's
# Router Advertisement gives tap0 a global IPv6 address + default v6 route.
# Chromium then trusts IPv6 and prefers it (Happy Eyeballs) for dual-stack
# hosts, but slirp's experimental v6 path stalls, so the navigation never
# settles. curl survives (single request, no network-idle wait).
#
# The VM has no internet, so a local dual-stack `webhost` stands in for a real
# site: an IPv4 nginx that serves the page, and an IPv6 listener that accepts
# the connection then stalls (modelling slirp's lossy v6). With `-6`, Chromium
# wins the v6 race to the staller and hangs; with IPv4-only networking it falls
# back to the nginx and loads. The test asserts both the invariant (no global
# v6 / no default v6 route in the default sandbox) and the end-to-end browser
# load.
{ pkgs, lib, ... }:
{
  nodes.machine = {
    environment.systemPackages = [ pkgs.chromium ];

    boot.kernelModules = [ "dummy" ];
    # The sandbox netns inherits these; accept_ra lets slirp's RA configure v6
    # and accept_dad=0 removes the DAD delay so the (bad) v6 state appears
    # deterministically within a couple of seconds.
    boot.kernel.sysctl = {
      "net.ipv6.conf.default.disable_ipv6" = 0;
      "net.ipv6.conf.all.disable_ipv6" = 0;
      "net.ipv6.conf.default.accept_ra" = 2;
      "net.ipv6.conf.default.accept_dad" = 0;
      "net.ipv6.conf.all.accept_dad" = 0;
    };

    networking.useDHCP = false;
    networking.firewall.enable = false;
    # Dual-stack `webhost`: 10.99.0.1 (nginx, serves the page) and
    # 2001:db8:1::2 (a stalling v6 listener). Reachable from the sandbox via
    # slirp4netns NAT.
    networking.localCommands = ''
      ip link add dummy0 type dummy 2>/dev/null || true
      ip addr add 10.99.0.1/24 dev dummy0 2>/dev/null || true
      ip -6 addr add 2001:db8:1::2/64 dev dummy0 2>/dev/null || true
      ip link set dummy0 up
    '';

    services.nginx = {
      enable = true;
      virtualHosts.default = {
        default = true;
        # IPv4 only; the v6 port is owned by the staller below.
        listen = [ { addr = "0.0.0.0"; port = 80; } ];
        root = pkgs.writeTextDir "index.html" "<!doctype html><html><body><h1>SBOX_OK</h1></body></html>";
      };
    };

    # Accept the v6 connection then go silent — models slirp's experimental v6
    # establishing a connection that never delivers a response.
    systemd.services.v6-staller = {
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.socat}/bin/socat TCP6-LISTEN:80,ipv6only=1,reuseaddr,fork EXEC:'${pkgs.coreutils}/bin/sleep 120'";
        Restart = "always";
      };
    };
  };

  testScriptSnippets = [
    ''
      with subtest("browser in sandbox: IPv4-only network + Chromium loads"):
          machine.wait_for_unit("nginx.service")
          machine.wait_for_unit("v6-staller.service")

          # Dual-stack hosts file visible inside the sandbox project dir.
          machine.succeed(
              "su - alice -c '"
              "printf \"10.99.0.1 webhost\\n2001:db8:1::2 webhost\\n\" "
              f"> \"{project}/test-hosts\"'"
          )
          hosts_bind = f'--ro-bind "{project}/test-hosts" /etc/hosts'

          # Invariant: a long-lived default sandbox must stay IPv4-only. Wait for
          # slirp's RA to (not) configure v6, then require no global address and
          # no default v6 route. This is the exact bad state `-6` introduced.
          v6_global = sbox_run("sleep 3; ip -6 addr show dev tap0 scope global | grep inet6 || true")
          print(f"sandbox global IPv6: {v6_global!r}")
          assert v6_global.strip() == "", \
              f"sandbox acquired a global IPv6 address (broken slirp4netns -6): {v6_global!r}"

          v6_route = sbox_run("sleep 3; ip -6 route show default | grep default || true")
          print(f"sandbox default IPv6 route: {v6_route!r}")
          assert v6_route.strip() == "", \
              f"sandbox has a default IPv6 route (broken slirp4netns -6): {v6_route!r}"

          # End-to-end: Chromium (as omp uses it) must load the dual-stack page.
          # With `-6` it prefers the stalling v6 listener and times out; IPv4-only
          # it reaches nginx. Wait first so any v6 state has settled.
          flags = (
              "--headless --no-sandbox --disable-setuid-sandbox --disable-gpu "
              "--no-first-run --no-default-browser-check "
              "--user-data-dir=\"$PWD/cd\" --timeout=20000 --dump-dom http://webhost/"
          )
          dom = sbox_run("sleep 3; timeout 40 chromium " + flags + " 2>/dev/null; echo \"__exit=$?\"", hosts_bind)
          print(f"chromium dom tail: {dom[-600:]!r}")
          assert "SBOX_OK" in dom, \
              f"Chromium failed to load the IPv4 page inside sbox (v6 stall?): {dom[-1500:]!r}"
    ''
  ];
}
