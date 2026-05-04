# RFC 0026 — Liveness Recovery Scanner

- Status: Draft
- Author: Vincent (vincent.dev@kidsnote.com)
- Date: 2026-05-04
- Issues: #12801, #12796
- Related RFCs:
  - RFC-0002 (Keeper State Machine) — terminal state semantics
  - RFC-0003 (Keeper Composite Lifecycle) — FSM observer
  - RFC-0022 (Cascade Attempt Liveness) — in-attempt liveness
- Related memory:
  - `project_keeper-reaction-chain-break-analysis-2026-05-04`
  - `feedback_no_timeout_as_bandaid_for_root_cause`

## 0. TL;DR

Once a Keeper enters Dead or Zombie phase, no event can revive it — the FSM
rejects all inputs at terminal states. Today `sweep_and_recover` detects
Dead/Zombie entries but only cleans up tombstones after TTL expiry; no recovery
path exists. This RFC introduces a Scanner→Recoverer→Verifier pipeline that
auto-recovers terminal-state keepers whose root cause has resolved.

Phase 1 (this RFC): Scanner-only — detect terminal keepers, emit structured
logs and Prometheus counters. No recovery logic.

## 1. Problem

### Terminal states are permanent

`keeper_state_machine.ml:272-274`:
```ocaml
| Stopped, _ -> false
| Dead, _ -> false
| Zombie, _ -> false
```

Once Dead or Zombie, the keeper stays there until:
1. Server restart (registry is in-memory)
2. Human operator re-registers the keeper

### Existing sweep does not recover

`sweep_and_recover` (keeper_supervisor.ml:988) handles terminal states:

```ocaml
| Dead | Zombie ->
    match entry.dead_since_ts with
    | Some dead_since when now -. dead_since >= dead_ttl_sec ->
        to_cleanup_dead := entry :: to_cleanup_dead
    | _ -> ()
```

It removes tombstones but never re-registers or restarts.

### Evidence (2026-04-25 fleet-wide silent crash)

8 keepers entered Dead state simultaneously (provider outage). All required
manual re-registration. Fleet was silent for ~2 hours.

## 2. Design

### 2.1 Phase 1: Scanner (this PR)

A periodic fiber that scans `Keeper_registry` for terminal-state entries:

```
fork_liveness_scanner ctx ~interval_sec:30.0
  └─ Every 30s:
     1. Keeper_registry.all ()
     2. Filter: phase = Dead | Zombie
     3. For each: log structured detection event
     4. Increment Prometheus counter
     5. NO recovery action
```

#### Prometheus metrics

```
masc_keeper_terminal_detected_total{keeper,phase,reason}
  — counter, incremented each scan tick for each terminal keeper
```

Note: `masc_keeper_terminal_dead_duration_seconds` gauge deferred to Phase 2
where it will be populated by the recoverer alongside recovery duration tracking.

#### Structured log

```
[WARN] liveness_scanner: terminal keeper detected \
  name=sangsu phase=dead dead_since=1714800000 \
  duration_s=3600 failure_reason="restart budget exhausted" \
  restart_count=5
```

#### Integration point

The scanner runs as a separate Eio fiber, forked from the keeper supervisor
startup path. It does NOT modify `sweep_and_recover`.

### 2.2 Phase 2: Recoverer (next PR)

**Open questions** (resolved before Phase 2 implementation):

1. **Recovery path**: `unregister` + fresh `register` (bypass FSM entirely)
   vs. add `Force_revive` event to state machine.

   Analysis: `unregister + register` is simpler and avoids FSM semantics
   change. The new entry gets fresh conditions with
   `restart_budget_remaining = true`. This matches how initial registration
   works. **Lean toward this option.**

2. **Root cause checker**: Before recovery, verify original failure cause
   is resolved:
   - Provider outage → check `Provider_health.is_available`
   - Credential issue → check `Credential_store.valid`
   - Context overflow → N/A (fresh context on re-register)

3. **Recovery budget**: Independent from restart budget. Each recovery attempt
   costs 1 from `recovery_budget` (default: 3). Budget resets on
   successful verification. Prevents infinite recovery loops for
   persistent failures.

4. **Concurrency control**: Recovery respects `max_concurrent_keepers`.
   At most 1 recovery per scan tick to avoid thundering herd.

### 2.3 Phase 3: Verifier (follow-up)

After recovery, verify the keeper reaches Running within `verification_timeout`
(default: 60s). If not, mark Dead again (does not consume recovery budget —
that was already spent on the attempt).

## 3. Implementation Scope

### Phase 1 (this PR, ~50 LOC)

| File | Change |
|------|--------|
| `lib/keeper/keeper_supervisor.ml` | Add `fork_liveness_scanner` fiber |
| `lib/keeper/keeper_supervisor.mli` | Expose `fork_liveness_scanner` |
| `lib/keeper/keeper_unified_metrics.ml` | Add `metric_keeper_terminal_detected_total` counter |
| `lib/keeper/keeper_unified_metrics.mli` | Expose metric |
| `lib/keeper/keeper_supervisor_loop.ml` | Fork scanner at startup |

### Phase 2 (next PR, ~150 LOC)

| File | Change |
|------|--------|
| `lib/keeper/keeper_supervisor.ml` | Add `recover_terminal_keeper` |
| `lib/keeper/keeper_registry.ml` | Add `reset_for_recovery` helper |
| `lib/keeper/keeper_lifecycle.ml` | Add `re_register_from_terminal` path |

### Phase 3 (follow-up, ~80 LOC)

| File | Change |
|------|--------|
| `lib/keeper/keeper_supervisor.ml` | Add verification timeout logic |

## 4. Testing

### Phase 1

- Unit test: `test_liveness_scanner_detects_dead_keeper`
  - Register a keeper, mark dead, run scanner, assert log output + counter

- Unit test: `test_liveness_scanner_ignores_running_keeper`
  - Register a running keeper, run scanner, assert no detection

### Phase 2

- Unit test: `test_recover_dead_keeper_unregisters_and_registers`
  - Verify unregister + register path

- Property test: `recovery_respects_max_concurrent_keepers`
  - Dead keepers + running keepers = max → recovery skips

## 5. TLA+ Verification (Phase 2)

```
LivenessRecovery ≜
  ∀ k ∈ Keeper :
    (state[k] = Dead ∨ state[k] = Zombie)
    ∧ root_cause_resolved[k]
    ∧ recovery_budget[k] > 0
    ◇→ state[k] = Running
```

Bug action: `RecoveryWithoutRootCauseCheck` — recover without verifying
root cause. Safety invariant should fail: `state[k] = Dead ∨ Running` (no
Zombie after failed recovery attempt — it should go back to Dead).

## 6. What This Does NOT Change

- Terminal state FSM semantics (Dead/Zombie still accept no events)
- `sweep_and_recover` behavior (continues unchanged)
- Restart budget (recovery uses separate budget)
- Test file timeout values (unrelated to this work)
