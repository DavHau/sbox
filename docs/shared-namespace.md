# Shared Namespace Across Multiple `sbox` Invocations

## Problem

Today, every `sbox` invocation creates its own user/mount/pid/net/ipc/uts/cgroup
namespaces via `unshare` + `bubblewrap`. Two terminals running `sbox` in the
same project directory get two **independent** sandboxes — no shared `/tmp`,
no shared processes, two separate `slirp4netns` instances, two different
network views.

Goal: when a second `sbox` is launched in a project directory that already has
a running `sbox`, attach to the existing namespaces instead of creating new
ones. Effectively: "tmux for sandboxes" — first invocation = leader, later
invocations = joiners.

## Feasibility on Linux

Possible. Linux exposes namespaces as fds at `/proc/PID/ns/{user,mnt,pid,net,
ipc,uts,cgroup}`. A second process with sufficient privilege can `setns(2)`
into them via `nsenter(1)` or `bwrap --userns/--userns2/--pidns FD`
(bwrap ≥ 0.4).

## Blockers

1. **Non-dumpable child.** `bwrap` calls `prctl(PR_SET_DUMPABLE, 0)` during
   sandbox setup. Side effect: `/proc/PID/ns/*` becomes owned by `root:root`
   instead of the invoking user. A same-uid joiner cannot `open()` the ns
   files, so `setns()` fails with `EACCES`. This is the same reason the
   existing code splits orchestration across `outerScript` (creates netns,
   starts slirp4netns) and `innerScript` (runs bwrap).

   **Fix.** Insert a tiny init binary between `bwrap` and the user shell that
   calls `prctl(PR_SET_DUMPABLE, 1)` and then `exec`s the shell. Same-uid is
   allowed to flip its own dumpable flag. After `exec`, the kernel additionally
   resets dumpable to `suid_dumpable` (1) for non-setuid binaries — so this
   may already happen incidentally for the shell, but relying on incidental
   kernel behavior is fragile. Explicit init is correct.

2. **Mount namespace is frozen at join time.** Once the leader's `bwrap`
   finishes setting up mounts, joiners enter a fully populated mnt ns. They
   cannot add per-invocation `--bind` mounts without `CAP_SYS_ADMIN` in the
   target user ns — which a joiner does have, but adding mounts post-hoc
   defeats the point of a sealed sandbox and complicates teardown.

   **Decision.** Joiners ignore mount-affecting flags (`--bind`, `--ro-bind`,
   `--persist`, `--allow-parent`, `--audio`, `--history`). If a joiner passes
   any such flag, fail loudly: leader config wins, divergent join is rejected.

3. **PID 1 semantics.** The leader's shell becomes pid 1 in the pidns. When
   it exits the entire pidns is torn down → all joiner shells receive SIGKILL.
   Acceptable as initial behavior, but it means the user must not `exit` the
   leader terminal expecting joiners to survive.

   **Future option.** Run a dedicated init (the dumpable-flipping helper from
   blocker 1) as pid 1 with proper child reaping; refcount active sessions;
   tear down only when the last session exits. Keeps joiners alive across
   leader exit.

4. **Network.** `slirp4netns` is per-netns and already attached to the
   leader's netns. Joiners inherit it for free. Existing port-forwarding
   socats run inside the netns (host-side and sandbox-side) — they continue
   to work for joiners with no changes.

5. **TTY/stdio.** `setns()` does not transport fds. Joiners keep their own
   tty fds and pass them through naturally — `nsenter -t PID -a -- bash`
   does the right thing because the new shell inherits the joiner's stdio.

6. **Cgroup namespace.** Joiner inherits leader's cgroup ns. Resource limits
   set at leader launch apply transparently.

## Architecture options

### A. Leader-as-supervisor (tmux-shaped)

- Leader spawns a supervisor inside the sandbox; supervisor listens on a
  unix socket bound at a host-visible coordination path.
- Joiner connects, sends tty fds via `SCM_RIGHTS`, supervisor forks a shell
  with those fds.
- **Pros.** No setns from outside — sidesteps the dumpable issue entirely.
- **Cons.** Need a supervisor binary, fd-passing protocol, lifecycle
  management. Higher implementation cost.

### B. setns join (no supervisor)

- Leader runs an init that flips dumpable=1.
- Joiner reads `/proc/<leader-init>/ns/*` and either calls `nsenter -a` or
  `bwrap --userns ... --pidns ...` to enter.
- **Pros.** Each joiner is an ordinary process; no IPC.
- **Cons.** Must solve dumpable. Joiner's bwrap would try to set up its own
  mnt ns which we don't want — so use raw `nsenter` instead of bwrap on
  the join path.

### C. Hybrid — chosen

- Leader runs init that flips dumpable, then `exec`s the configured shell.
- Coordination dir at `$XDG_RUNTIME_DIR/sbox/<key>/` contains: leader pid
  (host-visible), lockfile, leader's pgid, leader's UID, original config
  digest.
- Joiner detects coord dir, validates liveness, runs:
  ```
  nsenter -t <pid> -U -m -p -n -i -u --preserve-credentials -- <shell>
  ```
- Skip `bwrap` and `slirp4netns` entirely on the join path.

## Coordination

**Key.** `sha256(realpath(cwd) || '\0' || uid)`. Realpath collapses symlinks
so two paths that resolve to the same project share a sandbox. Uid scoping
prevents cross-user collisions on shared boxes.

**Location.** `$XDG_RUNTIME_DIR/sbox/<key>/` (tmpfs, per-user, auto-cleaned
on logout). Fall back to `/tmp/sbox-<uid>-<key>/` if `XDG_RUNTIME_DIR` is
unset.

**Files.**
- `lock` — `flock`'d during leader-vs-joiner decision; first writer wins.
- `leader.pid` — host-visible pid of the leader's init (pid 1 inside).
- `config.digest` — sha256 of mount-affecting flags. Joiner with
  divergent digest is rejected.
- `network` — leader's network mode (`isolated` / `blocked` / `host`).
  Joiner mismatch → reject.

**Liveness.** `kill -0 <leader.pid>` before joining. Stale dir → joiner
takes over leadership.

## Edge cases

- **Race on launch.** Two `sbox` calls start simultaneously. `flock` on
  `lock`: first to acquire writes coord files and proceeds as leader,
  the other waits, re-reads coord files, joins.
- **Leader crash with stale dir.** Liveness check via `kill -0`. If pid is
  dead or recycled (verify via `/proc/<pid>/comm` matches `sbox-init`),
  remove coord dir, retry as leader.
- **Different flags on second invocation.** Compare digest of:
  `--network`, `--allow-parent`, `--audio`, `--bind*`, `--ro-bind*`,
  `--persist`, `--history`, `--allow-port`, `--expose-port`. Mismatch →
  print actionable error: "leader was launched with `--network blocked`;
  rerun without conflicting flags or terminate the leader".
- **Nested sbox.** Inside an existing sbox (env `SANDBOX=1`), a second
  `sbox` already inside the same namespaces — current behavior is to
  spawn another nested sandbox. Out of scope for this feature; keep
  current behavior or short-circuit to plain shell.
- **`--allow-parent` differing.** Mount layout difference → reject via
  digest check.
- **Audio / Wayland / GPU / Path bind mounts.** All set up by leader;
  joiner inherits read-only.
- **Env vars.** Joiner needs its own `EDITOR`, `TERM`, `SSH_AUTH_SOCK`,
  etc. `nsenter` preserves the joiner's env by default — correct behavior.
- **cwd inside sandbox.** Use `nsenter --wd=$PWD` or have the joiner shell
  `cd` post-exec. Project dir is bind-mounted same path host-side and
  inside, so `--wd` works.
- **Signals.** Ctrl-C in joiner shell must not kill leader. `nsenter` puts
  the new shell in its own process group; ensure `setsid` semantics if
  needed. Default `nsenter -F` (no fork) keeps joiner shell as a child of
  leader's init — fine for signal isolation since each tty has its own
  pgrp.
- **Joiner exit.** Joiner's shell exits → joiner process exits → leader
  unaffected.
- **Leader exit (initial behavior).** Pidns torn down → all joiners
  SIGKILL'd. Document; revisit when implementing supervised init.
- **Coord dir cleanup.** Leader removes its own coord dir on exit (trap).
- **Different shells.** Joiner with `SHELL=fish` joining a leader started
  with `SHELL=bash` works — joiner exec's its own shell inside the shared
  namespaces. Each session gets its own shell process.
- **Persist-only files in `$HOME`.** Already mounted by leader; joiner
  shares them transparently.
- **Read-only bind args from joiner.** Reject (see digest check).
- **`--chdir`.** If joiner's `--chdir` resolves to the same project as
  leader, join. Different project → start independent leader (different
  coord key).

## Out of scope (future work)

- Supervisor mode with proper init + refcounted sessions (lets leader exit
  without dropping joiners).
- Live re-bind via leader-side RPC (add a mount post-launch).
- Cross-machine sharing (would need a different abstraction entirely).
- `tmux`-style attach/detach with persistent leader across logins.

## Implementation (current state)

**Opt-in via `--share`.** Auto-detection breaks the common pattern of running
`sbox CMD` twice in the same project dir back-to-back, because between the two
invocations the leader's coord state is racy and PID recycling makes liveness
checks unreliable. Until that is hardened, sharing is gated behind an explicit
flag: only `sbox --share` participates in coordination. Without `--share`,
behavior is unchanged.

1. **No init binary needed.** Empirically, the user shell exec'd by `bwrap`
   has `dumpable=1` after the kernel reset on `execve` for a non-setuid binary,
   so `/proc/<pid>/ns/*` is accessible to a same-uid joiner via `nsenter`. The
   README's non-dumpable note applies to bwrap's setup process, not the post-
   exec user command.
2. **Two-stage coordination files.**
   - `owner-pid`: written by the leader's outer script immediately after
     winning the `flock` race. Marks the coord dir as owned by a live leader.
   - `leader-pid`: written by a background helper after `bwrap` forks. Holds
     the host-visible PID of bwrap's first child (the pid-1-in-pidns process)
     — the actual `nsenter` target.
3. **Outer script flow when `--share` is set.**
   - Compute coord key (sha256 of realpath(cwd)+uid).
   - `flock` the coord dir.
   - If `owner-pid` is live, release the lock and poll up to 60s for
     `leader-pid`, then `exec nsenter -t <pid> -U -m -p -n -i -u`
     `--preserve-credentials --wd=<project> -- <cmd>`. Skip bwrap entirely.
   - Otherwise become leader: write `owner-pid`, install an `EXIT` trap to
     clean coord state, fork the helper, fall through to the existing
     unshare/slirp4netns/bwrap pipeline.
4. **Inner script change.** Right before `exec bwrap`, write `$$` to
   `$__SANDBOX_COORD_DIR/bwrap-pid`. The leader's helper polls that file,
   then reads `/proc/<bwrap-pid>/task/<bwrap-pid>/children` for bwrap's
   forked init child, and publishes that PID as `leader-pid`.

## Known limitations

- **Divergent flags ignored, not rejected.** A joiner that passes
  `--bind`/`--persist`/`--allow-port`/etc currently inherits the leader's
  layout and silently discards its own. Future: hash and compare flag set,
  fail loudly on mismatch.
- **Leader exit kills joiners.** When the leader's outer process exits, its
  pidns is torn down and joiner shells receive SIGKILL. Future: dedicated
  init pid 1 with refcounted sessions.
- **Stale leader-pid race.** If the helper writes `leader-pid` after the
  trap has already cleaned coord state, the file may persist briefly. Mitigated
  by joiner re-checking `owner-pid` liveness, but not eliminated.

## Test plan (current)

Covered by `tests/sbox/share-namespace.nix`:

- Joiner with `--share` in the same cwd as a leader sees the leader's `/tmp`
  contents (mount ns shared) and the leader's process via `ps -ef` (pid ns
  shared).
- A `sbox --share` started in a different cwd does **not** join the leader
  and gets its own fresh sandbox.
