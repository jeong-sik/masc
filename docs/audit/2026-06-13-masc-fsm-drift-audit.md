---
status: reference
last_verified: 2026-06-13
code_refs:
  - lib/keeper/keeper_unified_turn.ml
  - lib/keeper/keeper_unified_turn_success.ml
  - lib/keeper/keeper_agent_run_turn_helpers.ml
  - lib/keeper/keeper_turn.ml
  - lib/keeper/keeper_agent_run.ml
  - lib/keeper/keeper_execution_receipt.ml
  - lib/turn_fsm/turn_fsm.mli
  - specs/keeper-turn-fsm/KeeperTurnFSM.tla
  - test/test_keeper_turn_fsm_wired_sites.ml
---

# MASC Turn FSM Drift / SSOT Gap Audit

> Date: 2026-06-13
> Scope: keeper turn lifecycle FSM implementation vs. `specs/keeper-turn-fsm/KeeperTurnFSM.tla` and `docs/spec/04-turn-lifecycle.md`
> Method: read-only code/TLA/test survey + manual cross-reference
> Status: findings documented; remediation deferred to follow-up work

---

## Summary

MASC has a typed turn FSM (`lib/turn_fsm/turn_fsm.mli`), a keeper-side emitter (`lib/keeper/keeper_turn_fsm.ml`), TLA+ spec (`specs/keeper-turn-fsm/KeeperTurnFSM.tla`), and parity/wiring tests. This audit found **8 concrete drift points or SSOT gaps** between the formal model, the documented lifecycle, and the runtime implementation. None are immediately crash-inducing, but several weaken the guarantee that FSM telemetry, receipts, and TLA invariants stay aligned.

| # | Finding | Severity | TLA invariant at risk |
|---|---------|----------|----------------------|
| 1 | Duplicate `Streaming → Completing → Done` emission on success path | Medium | `ReceiptIsAuthoritative` (telemetry noise) |
| 2 | `StreamYieldsTool` / `ToolReturned` transitions emitted only when `yield_on_tool` is enabled | Medium | `TypeOK` coverage |
| 3 | Direct `masc_keeper_msg` turns bypass the typed FSM entirely | Medium | `TypeOK` coverage |
| 4 | `Cancelled_fleet_shutdown` variant is dead code | Low | — |
| 5 | `safe_emit_turn_end` catch-all can swallow `Cancelled_*` exceptions | High | `StopSignalRespected`, `ReceiptIsAuthoritative` |
| 6 | `ContractViolation` FSM transition has no explicit emission site | Low-Medium | `ReceiptMatchesState` |
| 7 | `test_keeper_turn_fsm_wired_sites` only counts emit calls, not transition correctness | Low | all invariants |
| 8 | No runtime assertion that receipt outcome matches FSM terminal state | Medium | `ReceiptMatchesState`, `ReceiptIsAuthoritative`, `EveryTurnHasTerminalReceipt` |

---

## 1. Duplicate FSM transition emission on success path

**Severity**: Medium

**Evidence**:
- `lib/keeper/keeper_unified_turn.ml:903-912` emits:
  ```ocaml
  Keeper_turn_fsm.emit_transition ~prev:Streaming Completing;
  Keeper_turn_fsm.emit_transition ~prev:Completing Done;
  ```
  then calls `Keeper_unified_turn_success.handle`.
- `lib/keeper/keeper_unified_turn_success.ml:544-554` emits the **same two transitions again** inside `handle`.

**Impact**: `masc_keeper_turn_fsm_transitions_total`, `Keeper_transition_audit` WAL, and `bin/masc-trace` timelines see each success edge twice. Transition-rate dashboards and automated SLO calculations based on `Done` counts will be off by 2x unless the duplicate is filtered at query time.

**Recommended action**: Emit `Streaming → Completing → Done` exactly once. Either remove the emission from `Keeper_unified_turn_success.handle` (after confirming no other caller relies on it) or remove it from `keeper_unified_turn.ml` and keep it inside `handle`.

**Related open question**: `OQ-TURN-002` in `docs/spec/04-turn-lifecycle.md`.

---

## 2. Tool-wait transitions are conditional on `yield_on_tool`

**Severity**: Medium

**Evidence**:
- `lib/keeper/keeper_agent_run_turn_helpers.ml:236-268` installs `on_yield` / `on_resume` hooks that emit `Streaming ⇄ Awaiting_tool_result` **only if** `Env_config.Slot.yield_enabled ()` returns true.
- TLA `KeeperTurnFSM.tla` models `StreamYieldsTool` and `ToolReturned` unconditionally for every tool call.

**Impact**: When `yield_on_tool=false` (default or production config), the FSM telemetry never enters `Awaiting_tool_result`, even though OAS internally blocks waiting for tool results. The formal model and the runtime telemetry diverge.

**Recommended action**: Wire `StreamYieldsTool` / `ToolReturned` transitions unconditionally, e.g. by observing the OAS Event_bus `ToolCalled` / `ToolCompleted` events instead of relying on the optional yield hook.

**Related open question**: `OQ-TURN-002` in `docs/spec/04-turn-lifecycle.md`.

---

## 3. Direct `masc_keeper_msg` bypasses the typed FSM

**Severity**: Medium

**Evidence**:
- `lib/keeper/keeper_turn.ml:183` (`run_keeper_msg_turn_admitted`) calls `Keeper_agent_run.run_turn` directly, without entering `Keeper_unified_turn.run_keeper_cycle`.
- No `Idle → Phase_gating → Runtime_routing → Awaiting_provider → Streaming` transitions are emitted.

**Impact**: Direct-message turns are invisible to the typed FSM telemetry. Dashboards and operators cannot reason about direct turns using the same state machine as autonomous turns.

**Recommended action**: Add a lightweight direct-turn wrapper that emits the same FSM transitions as the autonomous path (or document that direct turns intentionally use a separate observation model).

**Related open question**: `OQ-TURN-003` in `docs/spec/04-turn-lifecycle.md`.

---

## 4. `Cancelled_fleet_shutdown` variant is dead code

**Severity**: Low

**Evidence**:
- `lib/turn_fsm/turn_fsm.mli:19` defines `Cancelled_fleet_shutdown`.
- Grep across `lib/` shows **no emission site** for this variant.
- Fleet shutdown is handled generically as `Cancelled_supervisor_stop` or through `safe_emit_turn_end`.

**Impact**: The type promises a cancellation reason that cannot appear in telemetry, creating a minor specification/implementation mismatch.

**Recommended action**: Either remove the variant or add an explicit fleet-shutdown emission site in the server shutdown path.

---

## 5. `safe_emit_turn_end` catch-all can swallow cancellations

**Severity**: High

**Evidence**:
- `lib/keeper/keeper_agent_run.ml:148-171` defines `safe_emit_turn_end`, a `Fun.protect`-style finally block that emits a turn-end observation.
- The catch-all logs non-`Cancelled` exceptions but re-raises `Eio.Cancel.Cancelled`; however, the observation is emitted as `phase="completed"` regardless of whether the turn was cancelled.
- TLA `KeeperTurnFSM.tla:242-247` explicitly models this as the bug action `StopSignalSwallowedAsDone`, which violates `StopSignalRespected`.

**Impact**: A turn cancelled mid-stream may leave a receipt/observation that says `completed` while the FSM terminal is `Cancelled`. This breaks `ReceiptIsAuthoritative` and makes operator forensics unreliable.

**Recommended action**: Replace the catch-all with `Switch.on_release` cooperative cancellation (address `OQ-TURN-001`) so that `Cancelled_*` reaches the FSM and receipt layer with the correct terminal state.

**Related open question**: `OQ-TURN-001` in `docs/spec/04-turn-lifecycle.md` (marked RISKY).

---

## 6. `ContractViolation` FSM transition has no explicit emission site

**Severity**: Low-Medium

**Evidence**:
- TLA `KeeperTurnFSM.tla:198-203` defines `ContractViolation` action: `completing → failed` with `receipt_failed`.
- OCaml has `Failure_completion_contract_violation` in `turn_fsm.mli`.
- No `emit_transition` to `Failed (Failure_completion_contract_violation ...)` was found in the surveyed execution paths.

**Impact**: Contract violations may be recorded as generic `Failure_provider_error` or handled only in receipt operator disposition, leaving a gap between the FSM model and runtime telemetry.

**Recommended action**: Audit `Keeper_contract_classifier` / completion contract handling and add an explicit FSM transition when a contract violation is detected.

---

## 7. Wired-sites test only counts emit calls

**Severity**: Low

**Evidence**:
- `test/test_keeper_turn_fsm_wired_sites.ml:62-103` asserts that `Keeper_turn_fsm.emit_transition` appears at least 15 times in `keeper_unified_turn.ml`.

**Impact**: The test prevents accidental deletion of emit sites but cannot detect:
- duplicate emissions (finding #1),
- missing transitions (findings #2, #3),
- wrong `~prev` state,
- transitions to disallowed states.

**Recommended action**: Add a transition-graph coverage test that asserts every TLA `Next` action has a corresponding code path, or add a regression test that records a synthetic turn trace and asserts no duplicate transition pairs.

---

## 8. No runtime receipt-authority assertion

**Severity**: Medium

**Evidence**:
- TLA invariants `ReceiptMatchesState`, `ReceiptIsAuthoritative`, and `EveryTurnHasTerminalReceipt` constrain the relationship between terminal state and receipt outcome.
- `lib/keeper/keeper_execution_receipt_types.mli:16-18` exposes `assert_receipt_authoritative`, but it is **not wired into the hot path**.
- Receipts are written in multiple places (`record_pre_dispatch_terminal_observation`, `Keeper_execution_receipt.append`) without verifying that the FSM terminal and receipt outcome agree.

**Impact**: A bug that writes `outcome=done` while the FSM terminal is `Failed` or `Cancelled` would not be caught at runtime, even though the TLA spec forbids it.

**Recommended action**: Call `assert_receipt_authoritative` (or equivalent) at every receipt-write site, at least in debug/CI builds, and surface violations as structured warnings/metrics.

---

## Appendix A: TLA invariant mapping

| TLA invariant | Findings that threaten it |
|---------------|---------------------------|
| `EveryTurnHasTerminalReceipt` | #5, #8 |
| `ReceiptMatchesState` | #5, #6, #8 |
| `StopSignalRespected` | #5 |
| `ReceiptIsAuthoritative` | #1, #5, #8 |
| `TypeOK` | #2, #3, #4 |

## Appendix B: Existing documentation references

- `docs/spec/04-turn-lifecycle.md` — SSOT for turn lifecycle; Open Questions table references #1/#2 (`OQ-TURN-001`, `OQ-TURN-002`) and #3 (`OQ-TURN-003`).
- `docs/keeper-turn-lifecycle.md` — historical state table and open-work table.
- `docs/observability/keeper-turn-fsm-metrics.md` — wiring sites table (referenced by `test_keeper_turn_fsm_wired_sites`).
- `specs/keeper-turn-fsm/KeeperTurnFSM.tla` — formal model including bug actions.
