---
rfc: "0137"
title: "Host FD pressure → Keeper pause (safety-net for Docker VM FD accumulation)"
status: Draft
created: 2026-05-19
updated: 2026-05-19
author: jeong-sik
supersedes: []
superseded_by: null
related: ["0097", "0101"]
implementation_prs: []
---

# RFC-0137 — Host FD pressure → Keeper pause

Status: Draft
Author: jeong-sik (vincent)
Date: 2026-05-19
Related: RFC-0097 (keeper sandbox container reuse — root fix in progress),
RFC-0101 (FD slot accountant — process-internal pressure).

## 1. Problem

On 2026-05-19 the macOS host suffered a kernel panic at 10:28:27 KST
(`initproc exited`, `panic-full-2026-05-19-102827.0002.panic`). The
proximate cause was *system-wide* FD table exhaustion driven by the
single process
`com.apple.Virtualization.VirtualMachine.xpc` (Apple Virtualization
framework — Docker Desktop's VM backend). Same-day reproduction at
22:02:26 KST captured a natural CRIT event
(`fd=75%`, 368K / 491K `kern.maxfiles`) before user mitigation.

### 1.1 Measurement evidence (same-day)

| timestamp | system fd | pct | VM XPC fd | drift |
|---|---|---|---|---|
| 21:41 | 114,547 | 23% | 103,293 (pid 68615) | — |
| 21:44 | 118,645 | 24% | 107,598 | +23 fd/sec |
| 22:02 | ~368K | **75%** | (estimated 350K+) | **+51%p / 18min** |
| 22:04 | — | — | — | `bash mkdir` returns ENFILE |
| 22:05 (after user `killall -9 com.apple.Virtualization.VirtualMachine`) | 129,641 | 26% | XPC GONE | −239K recovered |

Single XPC process owned **>90%** of the system FD table immediately
before the CRIT. FD type breakdown at 21:41:
`97,549 REG + 10,030 DIR + 13 misc`. Path sample (from earlier 7905-fd
keeper task-318 audit) confirmed >99% live under
`/Users/dancer/me/.worktrees/keeper-*/` — i.e. keeper-per-task worktree
mounts shared into the Docker VM that the VM's filehandle cache never
evicts under bookkeeping pressure.

### 1.2 Why the existing layers do not catch this

| layer | observes | acts | gap |
|---|---|---|---|
| `Keeper_fd_pressure` (RFC-0101) | process `nofile` + a probe of `kern.num_files` at error sites | trips a per-process circuit breaker | **probe is reactive at error sites only**; nothing polls the host budget while quiet, so a 1-hour drift to 75% triggers nothing until a syscall fails |
| `Fd_accountant` (5-kind FD slot semaphore) | per-kind FD slots inside the masc-mcp process | rejects new spawns once the masc-mcp process budget is exhausted | observes *masc-mcp*, not the *host*. Apple VM XPC owns the FDs, not masc-mcp |
| `Docker_spawn_throttle` (RFC-0097 adjacent, PR #15727) | concurrent docker spawns | per-kind semaphore | reduces *spawn rate*; does not reduce *cumulative* mount accumulation |
| `sysmon-fd-oom-disk.sh` (out-of-process, `.tmp/`) | `kern.num_files / kern.maxfiles` every 60s | macOS notification + terminal bell | observer-only — masc-mcp keeper loop is not informed, so keepers keep adding work |

The 2026-05-19 incident proves this gap empirically: sysmon emitted a
WARN at 15:35 and a CRIT at 22:02; the keeper fleet kept scheduling
turns the entire interval.

### 1.3 Why this is *not* a counter-as-fix (RFC-0088)

A naive read of this RFC could classify it as "make data loss visible"
(RFC-0088 §counter-as-fix). It is not:

- The drift is **not** a counter we plan to emit and walk away from.
  The pressure signal triggers an **action** (keeper pause) before the
  failure manifests.
- The root fix (Apple VM cache lifecycle, Docker bind mount lifecycle,
  keeper worktree-per-task) is **out-of-process** for masc-mcp.
  RFC-0097 is the in-process root fix (container reuse). This RFC is
  the safety net while RFC-0097 lands and reaches steady state.
- The action (pause) is **degraded operation**, not a workaround that
  hides failures.

PR body for any implementation PR will carry the explicit deprecation
target: *"Sunset when RFC-0097 reaches steady state and 24h cumulative
VM XPC FD does not exceed 30K under fleet load."*

## 2. Design

Single-direction signal flow:

```
sysmon (.tmp/sysmon-fd-oom-disk.sh, already deployed)
   │ emits  /tmp/masc-host-pressure.state  (atomic write)
   │   {"level": "WARN"|"CRIT", "kinds": "...", "summary": "...", "ts": "...", "pid": ...}
   ▼
masc-mcp server polling loop (NEW)
   │ reads /tmp/masc-host-pressure.state every 1s
   │ on level change: invokes
   ▼
Keeper_fd_pressure.engage_external ~reason ~level  (NEW)
   │ trips the existing cooldown atomic with longer expiry
   ▼
existing keeper scheduling
   │ already consults Keeper_fd_pressure.active in pre-spawn / pre-turn gates
   ▼
keepers pause for cooldown_sec (WARN: 600s, CRIT: 1800s)
```

### 2.1 Signal contract

`/tmp/masc-host-pressure.state` is **already produced** by
`sysmon-fd-oom-disk.sh` (atomic temp-then-rename). Schema is JSON one-line:

```json
{"level":"OK|WARN|CRIT","kinds":"fd_total|fd_proc|vm_pressure|swap|disk","summary":"...","ts":"2026-05-19T22:02:26+0900","pid":66754}
```

`OK` is represented by **file absence**, not an `OK` line — this is the
existing sysmon behaviour. The polling loop treats missing-file as
`OK`.

### 2.2 API surface

`lib/keeper_fd_pressure.mli` adds:

```ocaml
type external_level = External_warn | External_crit

val engage_external :
  reason:string ->
  level:external_level ->
  ts:float ->
  unit
(** Trip the FD-pressure cooldown from an out-of-process source
    (host kernel pressure detected by sysmon). [reason] is for
    telemetry; [level] sets cooldown duration (WARN: 600s, CRIT:
    1800s); [ts] is the source event timestamp.

    Concurrency: monotonic CAS on [cooldown_until]; concurrent
    invocations with stale [ts] are no-ops. *)
```

No existing call sites need to change — they already consult
`Keeper_fd_pressure.active`.

### 2.3 Polling loop

New file: `lib/server/host_fd_pressure_poller.ml`.

- Eio fiber, started from `Server_bootstrap_loops.start`.
- Cadence: 1s. Cost: 1 `stat(2)` call per second.
- On file present + parse success + new `(level, ts)`: invokes
  `engage_external`.
- On file absent (or stale ts > 120s): no-op. Cooldown expires on its own.
- Telemetry: emits `host_fd_pressure_engage{level=warn|crit}` counter,
  logs the engage event with `reason` truncated to 200 chars.
- Failures (file partial write, malformed JSON): single WARN log per
  hour, no crash.

### 2.4 Cooldown durations

| level | cooldown | rationale |
|---|---|---|
| WARN (≥30%) | 600s (10min) | give keepers room to drain in-flight turns; resume if pressure clears |
| CRIT (≥75%) | 1800s (30min) | panic is imminent; sysmon's own macOS notification advises user restart in parallel |

Durations are env-overrideable: `MASC_HOST_PRESSURE_COOLDOWN_WARN_SEC`,
`MASC_HOST_PRESSURE_COOLDOWN_CRIT_SEC`.

## 3. Implementation plan

| PR | scope | LoC est | depends on |
|---|---|---|---|
| PR-1 | `keeper_fd_pressure.{ml,mli}` add `engage_external` + tests | ~60 | none |
| PR-2 | `host_fd_pressure_poller.{ml,mli}` new module + wiring in `server_bootstrap_loops.ml` + tests | ~120 | PR-1 |
| PR-3 (optional) | Prometheus metric `host_fd_pressure_*` registration | ~30 | PR-2 |

Each PR is Draft, follows `workflow-pr.md` (RFC-WAIVED line not needed;
this RFC itself is the citation).

## 4. Verification

### 4.1 Unit

- `engage_external ~level:CRIT` with `ts` newer than current cooldown:
  `active () = true`, `remaining_sec () ≈ 1800`.
- `engage_external ~level:WARN` with `ts` older than current cooldown:
  no-op.
- Two concurrent fibers calling `engage_external` with same `level` —
  one CAS wins, projection consistent.

### 4.2 Integration (host required)

Manual harness in `test/host_fd_pressure_integration_test.ml`:

1. Write `{"level":"WARN",...}` to `/tmp/masc-host-pressure.state`.
2. Assert: within 2s, `Keeper_fd_pressure.active ()` returns `true`.
3. `rm` the file.
4. Assert: after cooldown expiry, `active ()` returns `false`.

### 4.3 Field validation

Re-run the 2026-05-19 incident scenario:

1. Pre: 16 keepers active, drift ~13 FD/sec.
2. Wait for sysmon CRIT (≥75%).
3. Expected: within 1-2s of CRIT event, all keeper proactive cycles
   pause. Existing in-flight turns drain. New spawn requests rejected
   with `host_fd_pressure_engaged` reason.
4. User manual Docker restart resolves underlying issue; sysmon state
   file goes absent; cooldown expires; keepers resume.

Success criterion: **no `initproc exited` panic in the 24h following
PR-2 deploy under the same workload that produced 2026-05-19 02:28 KST
panic and 22:02 KST natural CRIT**.

## 5. Rollback

Single env flag `MASC_HOST_FD_PRESSURE_POLLER_DISABLED=1` short-circuits
the poller at fiber start. `engage_external` becomes unreachable; no
behaviour change beyond pre-PR-2 state.

## 6. Migration

Zero migration. The signal source (`sysmon-fd-oom-disk.sh`) is already
running in `.tmp/` on the affected host. Other hosts without sysmon
deployed: poller harmlessly observes file absent; no-op every 1s.

## 7. Open questions

1. **Should WARN-level engage cancel a running turn?** Current design:
   no — only blocks new turns. CRIT optionally cancels (deferred to PR-2
   review; default no until field data).
2. **Should the poller log keeper-by-keeper engagement?** No — a single
   broadcast log per state transition is enough. Per-keeper pause is
   implicit via `Keeper_fd_pressure.active` check.
3. **Other host pressure kinds (`vm_pressure`, `swap`, `disk`)?** Out of
   scope for RFC-0137. FD is the panic-proximate cause. Future RFC may
   generalize.

## 8. Related work

- **RFC-0097** (sandbox container reuse): the in-process root fix.
  When RFC-0097 reaches steady state (24h cumulative VM XPC FD ≤ 30K),
  RFC-0137 sunsets to a low-cardinality monitor — the poller stays as
  defense-in-depth but should rarely fire.
- **RFC-0101** (FD slot accountant): process-internal pressure. RFC-0137
  is its host-external analog. Same cooldown atomic, different signal.
- **RFC-0088** (counter-as-fix umbrella): RFC-0137 is *not* a workaround
  in that taxonomy because it triggers a behaviour change (pause), not
  a counter. PR body must reaffirm the sunset target.

## 9. Sunset criteria

This RFC sunsets when **all three** hold for a continuous 7-day window:

1. RFC-0097 implementation steady state (no `keeper_sandbox_container_*`
   error/restart counters over 7 days).
2. Sysmon `host_fd_pressure_engage_warn_total` counter stays at 0 over
   the same window.
3. macOS kernel panic count = 0 attributable to FD exhaustion.

When satisfied: sunset PR removes the poller and `engage_external`,
keeping the `engage_external` interface stub guarded by `assert false`
for one release cycle before deletion.
