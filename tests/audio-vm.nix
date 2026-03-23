# VM test for sbox --audio flag.
# Verifies that audio actually flows through PipeWire from inside the sandbox
# via native PipeWire, PulseAudio, and ALSA APIs by playing a tone and
# recording it back, then checking for non-silence.
{ pkgs, lib, self }:
let
  sbox = self.packages.${pkgs.system}.sbox;
in
pkgs.testers.runNixOSTest {
  name = "sbox-audio";

  nodes.machine =
    { pkgs, ... }:
    {
      networking.useDHCP = false;

      users.users.alice = {
        isNormalUser = true;
        password = "foobar";
        shell = pkgs.bashInteractive;
      };

      services.pipewire = {
        enable = true;
        pulse.enable = true;
        alsa.enable = true;
      };
      security.rtkit.enable = true;

      environment.systemPackages = [
        sbox
        pkgs.pipewire
        pkgs.pulseaudio  # for paplay
        pkgs.alsa-utils  # for aplay
        pkgs.sox
      ];

      system.activationScripts.createProject = {
        deps = [ "users" ];
        text = ''
          mkdir -p /home/alice/project
          chown -R alice:users /home/alice/project
        '';
      };
    };

  testScript = ''
    import base64
    import time

    project = "/home/alice/project"

    machine.wait_for_unit("multi-user.target")

    # Log in as alice so systemd --user and PipeWire start
    machine.wait_for_unit("getty@tty1.service")
    machine.wait_until_tty_matches("1", "login: ")
    machine.send_chars("alice\n")
    machine.wait_until_tty_matches("1", "Password: ")
    machine.send_chars("foobar\n")
    machine.execute("rm -f /tmp/login-ok")
    machine.send_chars("echo DONE > /tmp/login-ok\n")
    machine.wait_for_file("/tmp/login-ok")

    # Wait for PipeWire to be ready
    machine.wait_until_succeeds(
        "su - alice -c 'XDG_RUNTIME_DIR=/run/user/$(id -u alice) pw-cli info 0'",
        timeout=30,
    )

    # Create a virtual sink so playback has somewhere to go without real hardware.
    machine.succeed(
        "su - alice -c '"
        "export XDG_RUNTIME_DIR=/run/user/$(id -u); "
        "pw-cli create-node adapter "
        "\"{ factory.name=support.null-audio-sink "
        "node.name=test-sink "
        "media.class=Audio/Sink "
        "audio.position=[FL FR] "
        "object.linger=true }\""
        "'"
    )

    # Set test-sink as the default so paplay and aplay use it automatically
    machine.succeed(
        "su - alice -c '"
        "export XDG_RUNTIME_DIR=/run/user/$(id -u); "
        "pw-metadata 0 default.audio.sink "
        "\"{ \\\"name\\\": \\\"test-sink\\\" }\""
        "'"
    )

    # Generate a 1-second 440Hz test tone (16-bit PCM WAV for max compat)
    machine.succeed(
        "su - alice -c 'sox -n -b 16 " + project + "/test-tone.wav synth 1 sine 440 gain -3'"
    )

    def record_and_get_rms(duration_sec=2):
        """Start pw-record for duration_sec, return RMS amplitude of captured audio."""
        machine.execute("rm -f " + project + "/captured.wav")
        machine.succeed(
            "su - alice -c '"
            "export XDG_RUNTIME_DIR=/run/user/$(id -u); "
            "timeout " + str(duration_sec) + " "
            "pw-record "
            "--target=test-sink "
            "" + project + "/captured.wav; true"
            "'"
        )
        machine.succeed("test -f " + project + "/captured.wav")
        stat_output = machine.succeed(
            "su - alice -c 'sox " + project + "/captured.wav -n stat 2>&1'"
        )
        machine.log("sox stat output: " + stat_output)
        rms_line = [l for l in stat_output.splitlines() if "RMS" in l and "amplitude" in l]
        assert len(rms_line) > 0, (
            "Could not find RMS amplitude in sox stat output: " + repr(stat_output)
        )
        return float(rms_line[0].split()[-1])

    def sandbox_play_and_verify(play_cmd, label):
        """Play audio inside sandbox, record on host, assert non-silence."""
        machine.execute("rm -f " + project + "/captured.wav")

        # Start recorder in background
        machine.succeed(
            "su - alice -c '"
            "export XDG_RUNTIME_DIR=/run/user/$(id -u); "
            "nohup pw-record "
            "--target=test-sink "
            "" + project + "/captured.wav "
            "> /dev/null 2>&1 & "
            "echo $! > /tmp/recorder-pid"
            "'"
        )
        time.sleep(1)

        # Play from inside the sandbox
        inner = (
            "export XDG_RUNTIME_DIR=/run/user/$(id -u); "
            + play_cmd + "\n"
        )
        encoded = base64.b64encode(inner.encode()).decode()
        machine.succeed("echo '" + encoded + "' | base64 -d > " + project + "/_play.sh")
        outer = (
            "export XDG_RUNTIME_DIR=/run/user/$(id -u) && "
            "cd " + project + " && "
            "sbox --audio " + project + " -- bash " + project + "/_play.sh\n"
        )
        encoded = base64.b64encode(outer.encode()).decode()
        machine.succeed("echo '" + encoded + "' | base64 -d > /tmp/sbox-play.sh")
        machine.succeed("su - alice -c 'bash /tmp/sbox-play.sh'")

        # Stop recorder
        machine.succeed(
            "kill $(cat /tmp/recorder-pid) 2>/dev/null; sleep 0.5; true"
        )

        # Verify non-silence
        machine.succeed("test -f " + project + "/captured.wav")
        stat_output = machine.succeed(
            "su - alice -c 'sox " + project + "/captured.wav -n stat 2>&1'"
        )
        machine.log(label + " sox stat: " + stat_output)
        rms_line = [l for l in stat_output.splitlines() if "RMS" in l and "amplitude" in l]
        assert len(rms_line) > 0, (
            label + ": could not find RMS in sox output: " + repr(stat_output)
        )
        rms = float(rms_line[0].split()[-1])
        assert rms > 0.001, (
            label + ": expected non-silent audio (RMS > 0.001), got RMS=" + str(rms)
        )

    with subtest("sanity: recording without playback produces silence"):
        rms = record_and_get_rms(duration_sec=1)
        assert rms < 0.001, (
            "Expected silence when nothing is played, got RMS=" + str(rms)
        )

    with subtest("audio via PipeWire native (pw-play)"):
        sandbox_play_and_verify(
            "pw-play --target=test-sink " + project + "/test-tone.wav",
            "pw-play",
        )

    with subtest("audio via PulseAudio (paplay)"):
        sandbox_play_and_verify(
            "paplay " + project + "/test-tone.wav",
            "paplay",
        )

    with subtest("audio via ALSA (aplay)"):
        sandbox_play_and_verify(
            "aplay " + project + "/test-tone.wav",
            "aplay",
        )

    with subtest("no audio: PipeWire socket is not accessible without --audio"):
        inner = (
            "export XDG_RUNTIME_DIR=/run/user/$(id -u); "
            "pw-cli info 0 2>&1 && echo PW_OK || echo PW_FAIL\n"
        )
        encoded = base64.b64encode(inner.encode()).decode()
        machine.succeed("echo '" + encoded + "' | base64 -d > " + project + "/_check.sh")
        machine.succeed("rm -f " + project + "/result")
        outer = (
            "export XDG_RUNTIME_DIR=/run/user/$(id -u) && "
            "cd " + project + " && "
            "sbox " + project + " -- bash -c '(bash " + project + "/_check.sh) > " + project + "/result'\n"
        )
        encoded = base64.b64encode(outer.encode()).decode()
        machine.succeed("echo '" + encoded + "' | base64 -d > /tmp/sbox-noaudio.sh")
        machine.succeed("su - alice -c 'bash /tmp/sbox-noaudio.sh'")
        val = machine.succeed("cat " + project + "/result").strip()
        assert "PW_FAIL" in val, (
            "Expected PipeWire to be unreachable without --audio, got: " + repr(val)
        )
  '';
}
