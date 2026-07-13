---
rfc: "0101"
title: "FD accountant — observation across process resource classes"
status: Active
created: 2026-05-17
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: null
related: ["0098", "0099", "0100", "0137"]
implementation_prs: [15727, 15816]
---

# RFC-0101 — FD accountant: observation across process resource classes

## Current decision (2026-07-13)

`Fd_accountant` is an observation boundary, not an admission controller.
It records the dynamic extent of FD-consuming operations and exports a
point-in-time snapshot. It never delays, rejects, ranks, or serializes a Keeper
operation.

The previous design used per-kind concurrency caps plus a process-wide pressure
gate. That design was removed because a local resource signal could stall an
unrelated Keeper lane before the real operation was attempted. It also made a
configured cap look like an objective safety fact even though the correct
capacity belongs to the operating system, Docker, or provider runtime.

The historical motivation remains valid: a 2026-05 FD exhaustion incident
showed that Docker subprocesses, provider connections, sandbox commands, and
log writers all need shared observability. The correction is to observe these
operations and surface their actual failures, not to impose a MASC-owned
pre-admission hierarchy.

## Boundary

- `Fd_accountant` owns exact in-flight observations and process FD snapshots.
- Docker/provider/sandbox operations start without an accountant-owned wait.
- The operation owner returns its actual typed result or explicit process
  status. Observation must not replace that result.
- `Keeper_fd_pressure` and host-pressure probes may expose health evidence, but
  `Fd_accountant` does not consume that evidence to block work.
- The legacy Docker-only throttle module and its concurrency override are
  removed. Docker call sites use `Fd_accountant.observe` directly.
- Lifetime observations return an idempotent release callback and must be
  released when the observed resource is actually closed.

This keeps the dependency direction simple: product code emits facts to the
observer; the observer does not decide product behavior.

## API

```ocaml
type kind =
  | Docker_spawn
  | Provider_http
  | Provider_cli
  | Sandbox_exec
  | Log_writer

val observe : kind:kind -> (unit -> 'a) -> 'a

val acquire_lifetime_observation :
  kind:kind -> unit -> (unit -> unit)

val fd_snapshot : unit -> snapshot

and snapshot = {
  per_kind : (kind * int) list;
  resource_errors : (kind * resource_error * int) list;
  fd_open : int;
  fd_limit : int;
}
```

`observe` increments the selected kind before calling the callback and restores
the observation in every return, exception, and cancellation path. It performs
no semaphore acquisition and has no capacity result.

## Docker wiring

Every real Docker subprocess dynamic extent is observed at its owning call
site, including:

- one-shot `docker run` and cleanup;
- managed sandbox container start;
- read-only sandbox commands;
- turn-container start, exec, inspect, stop, and removal.

Docker spawn/run failures remain explicit. The Docker layer records the exact
status and output, updates Keeper error observability, and returns the failure
without replaying it under a pressure heuristic.

## Telemetry

The active surface is descriptive:

```text
masc_fd_open
masc_fd_limit
masc_fd_in_flight{kind="docker_spawn"}
masc_fd_in_flight{kind="provider_http"}
masc_fd_in_flight{kind="provider_cli"}
masc_fd_in_flight{kind="sandbox_exec"}
masc_fd_in_flight{kind="log_writer"}
masc_fd_resource_errors_total{kind="...",error="..."}
```

Host/keeper pressure is a separate observation surface. It is not a concurrency
mode or permission decision in this accountant.

## Verification

- Every `kind` round-trips through its typed codec.
- `observe` restores the in-flight observation after normal return, exception,
  and cancellation.
- Lifetime release is idempotent and returns the observation to zero.
- `fd_snapshot` is safe from the dashboard worker domain.
- Docker tests prove a daemon-unavailable result is returned after one attempt;
  no pressure-specific replay occurs.
- Source search contains no Docker-only throttle API or Docker spawn-cap knob.

## Decision history

- 2026-05-17: the first implementation introduced Docker-only and later
  multi-kind pre-admission limits to mitigate an FD exhaustion incident.
- 2026-07-13: the pre-admission mechanism was removed. The valuable part of the
  work—typed kinds, exact lifetime accounting, FD snapshots, and telemetry—was
  retained as an observation-only boundary.

## References

- PR #15727 — original Docker FD mitigation.
- PR #15816 — multi-kind accountant.
- Issue #13642 — loopback refusal symptom under FD exhaustion.
- RFC-0097 — Keeper sandbox container reuse.
- RFC-0137 — host FD pressure observation and retired Keeper-pause proposal.
