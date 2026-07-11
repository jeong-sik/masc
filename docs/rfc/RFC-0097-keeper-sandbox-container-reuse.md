---
rfc: "0097"
title: "Keeper sandbox container reuse (long-running sandbox per keeper)"
status: Active
created: 2026-05-17
updated: 2026-05-20
author: vincent
supersedes: []
superseded_by: null
related: ["0042", "0107"]
implementation_prs: [15991]
---

# RFC-0097 — Keeper sandbox container reuse

Status: In-progress (Phase E step 1 landed — skeleton + transport decision)
Author: jeong-sik (vincent)
Date: 2026-05-17
Related: PR #15678 (autonomy_exec pipe FD root fix), PR #15722 (docker spawn throttle — adjacent backpressure), RFC-0107 §3.4 (outbound HTTP stack — Docker UDS transport).

## Phase E step 1 — landing note (2026-05-17)

The first implementation increment landed alongside RFC-0107 Phase E step 1:

- `lib/sandbox/docker_api.{mli,ml}` — interface for the UDS HTTP client
  (`create`, `ping`, `container_create`, `container_start`,
  `container_exec`, `container_remove`). All function bodies currently
  `raise Failure` — type-correct skeleton, no production callers.
- `lib/worker_runtime_docker.ml` and `lib/keeper/keeper_sandbox_runtime.ml`
  carry an `(* RFC-0107 Phase E step 2 — branch on MASC_DOCKER_TRANSPORT
  env flag here *)` marker at the docker-spawn dispatch site. The
  legacy `docker run` / `docker exec` subprocess path stays as the
  default.

Step 2 (next) replaces the `Failure` stubs with an Eio + cohttp-eio
implementation over `/var/run/docker.sock` and flips this RFC to
`Active`. Open items deferred to step 2 (or follow-up RFC) below.

### Step 1 decisions recorded

- **Transport library**: `opam show docker-api` returns
  `ocaml-docker 0.2.2` with `ocaml < 5` — *incompatible* with our 5.4
  toolchain. We will not adopt it. The thin self-built wrapper above
  is the path.
- **HTTP framing**: `piaf` (the rest of RFC-0107's pool layer) has
  `Scheme.t = HTTP | HTTPS` only — no `Unix` scheme. UDS therefore
  stays *outside* `masc_http_pool`; step 2 layers HTTP/1.1 directly on
  `Eio.Net.connect`'d flow, using `cohttp-eio`'s parser where
  practical.
- **Scope**: only the five endpoints above. Image pull / build, volume
  mount surface, network management are *out of scope* and require an
  explicit follow-up RFC before they enter the interface.

## Summary

Replace the per-call `docker run --rm` model used by keeper sandbox
execution with a long-running container per keeper. Container lifetime
is bound to the keeper lifecycle. Per-turn commands run via
`docker exec` against the existing container.

This removes the spawn-rate variable that the 2026-05-16 ENFILE storm
saturated. The host FD ceiling becomes a function of *active keeper count*
(stable, ≤ 24) rather than *per-turn command count* (unbounded burst).

## Problem

Every keeper Execute sandbox call today goes through:

```
docker run --rm <flags> <image> bash -lc "<cmd>"
```

Cost per call (measured 2026-05-16):

- Host: process-group setup, 4+ pipes, daemon API socket.
- Docker daemon: container struct, cgroup, namespace, network namespace,
  veth pair, OCI runtime fork-exec.
- Wall-clock: 1–5 s startup before `bash -lc` even begins.

When the runtime-failure-storm at 2026-05-16 18:08-18:15 fired,
12+ keepers retried tier rotations in lockstep, each retry spawning
a fresh container. Host FD usage crossed `kern.maxfiles` (491_520),
ENFILE returned for `fstatat`/`execve`/`fork`, and unrelated
subsystems (cost emitter, OAS event bridge, keeper runtime manifest
appender, git worktree checks) all failed simultaneously. The system
took ~10 minutes to drain.

PR #15678 fixed one source (an autonomy_exec pipe leak via missing
`~cloexec:true`). PR #15722 added Layer A/B backpressure
(orchestrator semaphore + fd_pressure-aware serialization). These
are necessary but address the *rate*, not the *cost*.

## Goals

1. Remove container lifecycle from the per-call path.
2. Bound peak host FD consumption to `O(active_keepers)` rather than
   `O(active_keepers * inflight_calls)`.
3. Preserve current security envelope (`--cap-drop=ALL`, `--read-only`,
   `--pids-limit`, `--memory`, seccomp profile).
4. Preserve current identity envelope (per-keeper UID/GID, credential
   mounts, label set).
5. No regression in per-call latency P50; aim for ≥ 5× P50 improvement.

## Non-goals

- Removing Docker as the sandbox backend.
- Sharing containers across keepers.
- Changing the keeper-shell DSL or Bash semantics.
- Eliminating the per-call `Masc_exec.Exec_gate` typed approval pipeline
  (it still wraps every `docker exec`).

## Proposed design

### Lifecycle binding

Each keeper has, at most, one long-running sandbox container, named
`masc-keeper-<keeper-name>-persistent`. The container's lifetime is
bound to the keeper lifecycle (`Keeper_supervisor` start/stop). It is
created lazily on the first sandbox call and removed when the keeper
transitions to `Terminated` / `Compacted_out`.

```
Keeper_supervisor.start keeper:
  on first Bash call → ensure_sandbox_container keeper
  on subsequent calls → docker exec <container> bash -lc "<cmd>"
Keeper_supervisor.stop keeper:
  → docker rm -f <container>  (idempotent, best-effort)
```

### Persistent container shape

```
docker run -d                              # detached
  --name masc-keeper-<keeper>-persistent
  --label masc.mcp.component=keeper-sandbox
  --label masc.mcp.keeper=<keeper>
  --label masc.mcp.kind=persistent         # (vs. existing kind=oneshot)
  --user <uid>:<gid>
  --read-only --tmpfs /tmp:rw,nosuid,nodev,noexec,size=256m
  --cap-drop=ALL --security-opt no-new-privileges
  --pids-limit <cfg>  --memory <cfg>
  --network <host|none>
  -v /Users/dancer/me/.masc/playground/docker/<keeper>:/home/keeper/...:rw
  -v <credential mounts>:ro
  <image> sleep infinity
```

Per-call execution:

```
docker exec -i <container> bash -lc "<cmd>"
```

### Failure modes and recovery

| Failure | Detection | Recovery |
|---|---|---|
| Container missing (host restart, OOM kill, manual `docker rm`) | `docker exec` returns "No such container" | Re-create container, re-execute call |
| Container unresponsive (frozen, network partition) | `docker exec` timeout | `docker kill` + recreate |
| Image upgrade | image digest changes | Recreate container at next call |
| Credential rotation | mount path changes | Recreate container at next call |
| `--read-only` violation needing `-v` change | spec hash changes | Recreate container at next call |

The lazy-recreate path uses the same `ensure_sandbox_container`
helper, so recovery is the steady-state path under failure rather than
a separate code branch.

### Backpressure interaction

The Layer A throttle (`Docker_spawn_throttle`) shipped in PR #15722
caps the spawn rate. Under this RFC the spawn count drops by 10×–100×
(one `docker run` per keeper lifetime instead of per call), so the
semaphore effectively becomes a no-op. We keep it as a guardrail for
container-creation bursts (24 keepers starting simultaneously after a
server restart).

`docker exec` is *not* wrapped by the throttle. Per-keeper-serialization
of `exec` is enforced naturally because each keeper turn is single-threaded
inside `Keeper_unified_turn`; multiple `exec` calls to the same
container do not race.

### Configuration

| Env | Default | Purpose |
|---|---|---|
| `MASC_KEEPER_SANDBOX_MODE` | `oneshot` (phase 0) → `persistent` (phase 2) | Feature-flag the migration |
| `MASC_KEEPER_SANDBOX_PERSISTENT_TTL_SEC` | 3600 | Idle TTL before container is recycled |
| `MASC_KEEPER_SANDBOX_RECREATE_ON_IMAGE_CHANGE` | true | Auto-recreate on image digest change |

## Migration plan

| Phase | Scope | Default | Risk |
|---|---|---|---|
| 0 (this RFC) | Spec only | n/a | None |
| 1 | Implementation gated behind `MASC_KEEPER_SANDBOX_MODE=persistent` env opt-in; CI exercises both paths | `oneshot` | Low — opt-in |
| 2 | Default flips to `persistent`; `oneshot` still selectable | `persistent` | Medium — operational risk |
| 3 | `oneshot` code path removed | `persistent` | Low — once phase 2 stable for 2 weeks |

## Alternatives considered

### A. Keep oneshot, increase concurrency cap

Already shipped (PR #15722). Buys headroom but does not change the
relationship `FD_cost ∝ call_rate`. Storm still possible at sufficient
fan-in.

### B. Container reuse pool (shared across keepers)

Eliminates per-keeper isolation. Cap-drop / cred-mount sets differ
per keeper. Rejected — security envelope incompatible.

### C. Replace Docker with chroot+namespaces directly

Lower overhead, but loses macOS portability (Docker Desktop's
Linux VM abstracts the namespace stack). macOS is the primary dev
target. Rejected — host-platform incompatible.

### D. Replace Docker with Linux user containers via runc

Same problem as C. Rejected — same reason.

### E. Replace Docker with microVM (Firecracker / Apple Virtualization Framework / exec-sandbox)

Pattern adopted by OpenHands proposal #13203 (QEMU microVM via
exec-sandbox). Startup measured at 1-2 ms warm and ~100 ms cold via
L1 snapshot. Hardware-level isolation rather than namespace-level.

Rejected for this RFC because:

1. macOS development would require Apple Virtualization Framework
   (newer, less battle-tested than HVF QEMU) or HVF directly — neither
   has the operator familiarity that Docker has accumulated over the
   masc history.
2. Image tooling — our keeper images are Docker images. Switching to
   microVM image format requires a parallel build pipeline (rootfs
   assembly, kernel pinning, init system selection).
3. Scope explosion — microVM migration is multi-quarter. RFC-0097's
   four-phase plan ships within one sprint cycle.

Re-evaluate in two quarters once RFC-0097 reaches phase 2 (default
`persistent`) and we have production data on per-keeper container FD
and memory cost. If `docker exec`-heavy load reveals daemon FD or
memory regressions we did not project, microVM is the next step —
OpenHands is moving in this direction, and our motivation overlaps
(host FD pressure, macOS Docker Desktop friction).

### F. Replace Docker with OS-level sandbox (bubblewrap / seatbelt)

Pattern adopted by Provider-A (bubblewrap on Linux,
seatbelt on macOS). Near-zero overhead, no container daemon, no
spawn-rate variable at all.

Rejected for the keeper use case because:

1. Keeper sessions need persistent process state (long-lived shell,
   environment, working directory). OS-level sandboxes are
   per-process; a persistent shell would need a separate state layer.
2. `cap-drop` / `pids-limit` / memory cgroup enforcement is uniform
   across distributions with Docker; hand-assembled bubblewrap
   profiles fragment per-host.
3. Image-based reproducibility — Docker images can be pinned per
   keeper version. OS-level sandbox has no equivalent (the keeper
   runs against whatever is on the host).

This is the opposite end of the design space from E (microVM).
Provider-A optimized for startup cost on a per-command CLI shell;
masc keepers are the opposite shape (long-lived, stateful), so
the trade-off does not invert in our favor.

## Workaround rejection bar (self-check)

- [x] Not telemetry-as-fix — removes the FD cost source
- [x] Not string/substring classifier
- [x] Not N-of-M — single migration path, all per-call sites move together
- [x] No catch-all
- [x] No cap/cooldown/dedup/repair — repair path (recreate-on-missing) is
      not a workaround but the natural lazy-init pattern

## Cost / risk

- Implementation: estimated 2-3 sprint-weeks (lifecycle binding, exec
  wrapper, recovery path, two-mode CI matrix).
- Operational risk: phase-2 default-flip requires a rollback path
  (env flag). Production telemetry must distinguish per-mode failure rates
  before phase 3.
- FD savings (projection from 05-16 incident): peak FD usage drops from
  ~491k (storm) to <50k (24 active keepers × ~2k FDs/container). Headroom
  10× the system ceiling.

## Open questions

1. **Container freeze under idle** — should `MASC_KEEPER_SANDBOX_PERSISTENT_TTL_SEC`
   apply or do we keep containers alive indefinitely? Bias toward indefinite,
   since recreation cost is what we're amortizing.
2. **Container exec timeout enforcement** — `docker exec` has no built-in
   wall-clock timeout. Continue using `Process_eio` timeout wrapper around
   the exec call, same as today.
3. **macOS Docker Desktop FD accounting under exec-heavy load** — needs
   measurement during phase 1 to confirm host FD usage actually drops as
   projected.
4. **macOS Docker Desktop license — commercial-use scope, not
   production-only** — Docker Desktop requires a paid Pro/Team/Business
   subscription for any commercial use inside organizations with >250
   employees OR >$10M annual revenue (cited as motivation by OpenHands
   proposal #13203). Scope is *commercial use*, not deployment tier, so
   phase 1 (macOS developer machines) is also affected once the
   organization crosses either threshold. Action: confirm subscription
   status before phase 1 macOS rollout in such organizations; evaluate
   Colima / Rancher Desktop / docker-cli + remote daemon as fallbacks
   for both phases. Phase 2 default flip on macOS production hosts
   remains a hard block until license or alternative is resolved.

## Evidence

- Incident: `<base-path>/.masc/logs/system_log_2026-05-16.jsonl` 18:08-18:15Z
  (53 ENFILE entries, 12+ affected keepers).
- Detection module: `lib/keeper_fd_pressure.ml:36-46 is_fd_exhaustion_text`.
- Throttle (Layer A/B): `lib/docker_spawn_throttle.ml` (PR #15722).
- Spawn sites today: `lib/worker_runtime_docker.ml:394 run_worker_spec`,
  plus the sandbox Execute runner's `docker run --rm` path.

## References

- AGENT-LLM-A.md `<workaround_rejection_bar>` — symptom suppression vs. structural fix.
- RFC-0042 — closed-sum-types as the prevention pattern for catch-all
  classifiers (this RFC is the analogous pattern for spawn-cost).
- `~/me/knowledge/research/2026-05-17-agent-sandbox-deep-dive.md` —
  external cross-check of five agent sandbox systems
  (CLI-Tool-A, OpenHands, SWE-ReX, Devin, Docker Sandboxes) against
  this RFC; source of the E (microVM) and F (bubblewrap/seatbelt)
  alternatives analysis.
- Provider-A sandboxing — https://code.claude.com/docs/en/sandboxing
  (basis for option F).
- OpenHands microVM proposal — https://github.com/OpenHands/OpenHands/issues/13203
  (basis for option E and Open question 4).
