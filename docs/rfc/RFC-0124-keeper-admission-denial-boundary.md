---
rfc: "0124"
title: "Keeper Admission Denial Boundary"
status: Draft
created: 2026-05-17
updated: 2026-05-17
author: vincent
supersedes: []
superseded_by: null
related: ["0026", "0088", "0097", "0101", "0106"]
implementation_prs: []
---

# RFC-0124: Keeper Admission Denial Boundary

## 1. Problem

Keeper launch and turn admission failures can look like a stopped keeper even
when no keeper fiber ever started. Before this RFC, the launch choke point was a
boolean:

```ocaml
Keeper_registry.spawn_slots_available : unit -> bool
```

When the result was `false`, `keeper_supervisor` skipped launch silently and
`keeper_keepalive` only wrote a local info log. The operator surface could not
distinguish:

- FD pressure cooldown
- disk pressure cooldown
- FD admission rejection
- disk probe or free-space admission rejection
- max-active-keeper cap

The same issue existed inside admission probes. `keeper_fd_pressure` could
collapse failed nofile/open-fd/system-fd probes to `None`, and
`keeper_disk_pressure` explicitly admitted on `Probe_error`. A telemetry-only
gauge would violate RFC-0088: it would make the failure visible but still allow
the unsafe admission path to continue.

## 2. Decision

Admission denial is a typed runtime boundary, not a counter-only signal.

This RFC introduces two rules:

1. Launch admission must return a closed reason:
   `Fd_pressure_active | Disk_pressure_active | Fd_admission_blocked |
   Disk_admission_blocked | Max_active_keepers`.
2. Probe-unknown is fail-closed at the admission boundary:
   failed FD and disk probes block launch/turn admission and surface the typed
   reason in runtime JSON.

Metrics and lifecycle events are allowed only as effects of that typed decision.
They are not the root fix.

## 3. Design

### 3.1 Registry API

`Keeper_registry.spawn_slots_decision` replaces the boolean-only check:

```ocaml
type spawn_slot_denial_reason =
  | Fd_pressure_active
  | Disk_pressure_active
  | Fd_admission_blocked
  | Disk_admission_blocked
  | Max_active_keepers of { running_count : int; max_keepers : int }

val spawn_slots_decision :
  ?base_path:string -> unit -> (unit, spawn_slot_denial_reason) result
```

`spawn_slots_available` remains as a compatibility wrapper. New runtime callers
use the typed decision.

`base_path` enables disk admission probing against the target runtime root.
Callers without a runtime root keep the old compatibility behavior and do not
perform disk probing.

### 3.2 Lifecycle Surface

Denied launch attempts emit:

- lifecycle custom event: `admission_denied`
- phase projection: `Offline`
- Prometheus counter:
  `masc_keeper_spawn_slot_denied_total{keeper,surface,reason}`
- WARN log with the stable reason label and human detail

This makes the "never started" state visible on the same lifecycle surface as
started, stopped, crashed, and recovered keepers.

### 3.3 FD Admission

`keeper_fd_pressure.admission_decision` blocks on unknown primary probes:

| Missing probe | Block kind |
|---|---|
| nofile soft limit | `process_nofile_soft_limit_probe_unknown` |
| process open fd count | `process_open_fds_probe_unknown` |
| host/system fd snapshot | `system_fd_probe_unknown` |

The runtime JSON exposes the same reason via `reason`,
`admission_decision.block.kind`, and `admission_blocked=true`.

### 3.4 Disk Admission

`keeper_disk_pressure.admission_decision_of_snapshot` no longer treats
`Probe_error _` as `Admit`.

It returns:

```ocaml
Block (Disk_probe_error { detail })
```

and the JSON block carries:

```json
{ "tag": "disk_probe_error", "detail": "..." }
```

### 3.5 Test-only Bypass

Some unit tests run in environments where host fd probes are denied by the
sandbox. The production API must stay strict, so tests use
`Keeper_registry.For_testing.spawn_slots_decision` to inject admission booleans.

This bypass is not exported to runtime code.

## 4. Migration

1. Add the typed denial reason and compatibility wrapper.
2. Convert supervisor and keepalive launch gates to `spawn_slots_decision`.
3. Add `admission_denied` lifecycle event and dashboard cache patcher support.
4. Register `masc_keeper_spawn_slot_denied_total`.
5. Flip FD and disk probe-unknown admission from admit to block.
6. Add focused tests for reason labels, metric increment, lifecycle SSOT,
   FD probe-unknown blocks, disk probe-error blocks, and deterministic registry
   test hooks.

## 5. Compatibility

`spawn_slots_available` is retained for any out-of-tree boolean callers.

The fail-closed probe behavior is intentionally stricter. If a deployment cannot
support a host-level system-fd probe, that deployment should fix the probe
surface or explicitly opt into a future documented degraded mode. It should not
silently admit new keepers under an unknown resource budget.

## 6. Verification

Focused gates for the implementation PR:

```bash
scripts/dune-local.sh build test/test_keeper_registry.exe test/test_types.exe
./_build/default/test/test_keeper_registry.exe
./_build/default/test/test_types.exe
git diff --check
```

Expected coverage:

- `test_keeper_registry`: FD admission, disk admission, spawn denial reason
  labels, metric increment, registry deterministic bypass.
- `test_types`: lifecycle event SSOT and dashboard lifecycle patcher coverage.

## 7. Acceptance

- [x] Launch denial is represented as a closed sum, not a boolean-only skip.
- [x] Supervisor launch denial emits a durable lifecycle event and metric.
- [x] Keepalive launch denial emits a durable lifecycle event and metric.
- [x] FD probe unknown blocks admission and surfaces a typed reason.
- [x] Disk probe error blocks admission and surfaces a typed reason.
- [x] Runtime tests cover the new denial and probe-unknown cases.
- [ ] The implementation PR is merged and this RFC is updated with PR number.

## 8. References

- RFC-0026: work-conserving keeper admission.
- RFC-0088: counter-as-fix rejection bar.
- RFC-0097: keeper sandbox container reuse.
- RFC-0101: FD accountant.
- RFC-0106: cancel-safe probe discipline.
- `reports/keeper-stop-analysis-20260517.html`: P0 launch/admission and
  probe-unknown findings.
