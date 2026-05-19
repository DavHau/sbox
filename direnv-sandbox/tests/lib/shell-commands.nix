# Per-shell command primitives used throughout the direnv-sandbox tests.
#
# Each entry is the shell's encoding of one conceptual operation (write a file,
# read an env var, capture stderr, ...). Keeps the Python test body single-source
# across bash, zsh, fish, and nushell. Only the primitive encodings differ.
{ shell }:
let
  dispatch = attrs: attrs.${shell};
in
{
  # Login readiness marker. Written from the user's shell once it accepts
  # input; the harness polls for this file to know it can proceed.
  loginReady = dispatch {
    bash    = "echo DONE > /tmp/login-ok";
    zsh     = "echo DONE > /tmp/login-ok";
    fish    = "echo DONE > /tmp/login-ok";
    nushell = "'DONE' | save -f /tmp/login-ok";
  };

  # Write a literal token (no spaces or shell metacharacters) to a file.
  writeLiteral = literal: path: dispatch {
    bash    = "echo ${literal} > ${path}";
    zsh     = "echo ${literal} > ${path}";
    fish    = "echo ${literal} > ${path}";
    nushell = "'${literal}' | save -f ${path}";
  };

  # Write the value of env var $VAR to a file. When VAR is unset, POSIX
  # shells write an empty line and nushell writes the literal 'UNSET' — both
  # produce a deterministic, non-matching value that makes the assertion
  # fail cleanly with a readable diff rather than time out.
  writeEnv = v: p: dispatch {
    bash    = "echo \$${v} > ${p}";
    zsh     = "echo \$${v} > ${p}";
    fish    = "echo \$${v} > ${p}";
    nushell = "$env.${v}? | default 'UNSET' | save -f ${p}";
  };

  # Write $SHLVL to a file. Nushell does not auto-set SHLVL, hence default.
  writeShlvl = p: dispatch {
    bash    = "echo $SHLVL > ${p}";
    zsh     = "echo $SHLVL > ${p}";
    fish    = "echo $SHLVL > ${p}";
    nushell = "$env.SHLVL? | default '1' | save -f ${p}";
  };

  # Write $VAR or the literal string 'unset' to a file.
  writeEnvOrUnset = v: p: dispatch {
    bash    = "echo \${${v}:-unset} > ${p}";
    zsh     = "echo \${${v}:-unset} > ${p}";
    fish    = "set -q ${v}; and echo \$${v} > ${p}; or echo unset > ${p}";
    nushell = "$env.${v}? | default 'unset' | save -f ${p}";
  };

  # Read src into dst (one file → another file).
  readFile = src: dst: dispatch {
    bash    = "cat ${src} > ${dst}";
    zsh     = "cat ${src} > ${dst}";
    fish    = "cat ${src} > ${dst}";
    nushell = "open ${src} | save -f ${dst}";
  };

  # Run cmd and capture its stderr to a file. Used by tests that expect a
  # command to fail with a specific error message.
  #
  # Nushell quirks addressed here:
  # (1) Doubled braces — when the result is embedded in a Python f-string
  #     (which the test driver consumes) `{{` / `}}` render as literal
  #     `{` / `}`, i.e. nushell's block syntax, instead of being parsed as
  #     f-string placeholders.
  # (2) `^` prefix — forces external invocation. Nushell builtins (`touch`,
  #     `mkdir`, ...) raise structured errors that abort the pipeline before
  #     `complete` can capture them, so their stderr would never reach the
  #     output file. `^` routes through PATH and gives us POSIX stderr.
  captureStderr = cmd: p: dispatch {
    bash    = "${cmd} 2>${p}";
    zsh     = "${cmd} 2>${p}";
    fish    = "${cmd} 2>${p}";
    nushell = "do {{ ^${cmd} }} | complete | get stderr | save -f ${p}";
  };
}
