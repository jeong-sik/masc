---
status: reference
last_verified: 2026-06-05
code_refs:
  - lib/keeper/keeper_turn_fsm.ml
  - lib/keeper/keeper_unified_turn.ml
  - lib/keeper_metrics/keeper_metrics.ml
  - lib/keeper_metrics.ml
  - lib/otel_metric_store/otel_metric_store_core.ml
  - bin/masc_trace.ml
---

# Keeper Turn FSM Observability

How to read the typed turn-FSM counter and log line that the keeper emits on every state transition, and how to pull the per-turn timeline back out with `bin/masc-trace`.

Companion doc: `docs/keeper-turn-lifecycle.md` (sequence + state diagram, source vocabulary).

## Background

Step 4 of the bloodflow restoration plan (Phase 7 of the parent plan) wired `Keeper_turn_fsm.emit_transition` at every state edge in `run_keeper_cycle`. Before that step, a turn that died before dispatch left no `turn_id`-correlated row anywhere — receipts existed but log lines and tool_calls didn't carry the same id, so an operator couldn't reconstruct the path.

After Step 4 every dispatched turn produces a chain like:

```
[fsm:transition] - -> phase_gating
[fsm:transition] phase_gating -> runtime_routing
[fsm:transition] runtime_routing -> awaiting_provider
[fsm:transition] awaiting_provider -> streaming
[fsm:transition] streaming -> completing
[fsm:transition] completing -> done
```

Every line carries the same `keeper_name` and `turn_id` as the receipt and the tool_call rows for that turn, so cross-source joining is a labelled lookup, not a substring search.

## Counter — `masc_keeper_turn_fsm_transitions_total`

Bumped exactly once per `Keeper_turn_fsm.emit_transition` call.

| Label | Values |
|-------|--------|
| `from` | `idle`, `phase_gating`, `runtime_routing`, `awaiting_provider`, `streaming`, `awaiting_tool`, `completing`, plus `-` when no `?prev` was supplied |
| `to` | one of `turn_state_label` outputs: `idle`, `phase_gating`, `runtime_routing`, `awaiting_provider`, `streaming`, `awaiting_tool`, `completing`, `done`, `failed:<reason>`, `cancelled:<reason>` |
| `keeper` | keeper name (e.g. `nick0cave`, `alice`) |

`failed:` reasons (`failure_reason_label`):
- `runtime_unavailable` — ollama saturation, more generally runtime had no resolvable provider
- `provider_error` — sdk error from a CLI subprocess or HTTP call (Step 4f redirect)
- `completion_contract_violation`
- `receipt_lost` — Step 3 (RISKY) will surface this once enabled
- `turn_livelock_blocked` — Step 4f variant; livelock guard rejected the turn pre-dispatch
- `runtime_error` — typed catch-all for operational failures that don't fit the above
- `unexpected_exception`

`cancelled:` reasons (`cancel_reason_label`):
- `supervisor_stop`
- `phase_gate_close`
- `provider_timeout`
- `fleet_shutdown`

### Cardinality

`from × to × keeper` = ≤ 10 prev × 10 next × ~16 keepers = 1600 series upper bound. Reachable subset is much smaller; today's wired sites produce ~6 distinct (from, to) pairs per keeper.

### Distinct from `masc_keeper_fsm_edge_transitions_total`

The older counter encodes **cross sub-FSM** edges (`ksm_to_kcl_routing`, `kmc_to_ksm_compact_completed`, etc.) used by `docs/keeper-fsm-graph.dot`. It is a different abstraction level — sub-FSM coupling vs. typed turn-state ADT. Both counters live alongside; backend query filters should pick the one whose vocabulary matches the question.

## Backend Query Examples

```text
# Phase-gate skip rate per keeper (5m window).
rate(masc_keeper_turn_fsm_transitions_total{
  from="phase_gating", to="done"
}[5m])

# Total failure rate by reason.
sum by (to) (
  rate(masc_keeper_turn_fsm_transitions_total{to=~"failed:.*"}[5m])
)

# Per-keeper completion ratio over 1h.
  sum by (keeper) (rate(masc_keeper_turn_fsm_transitions_total{to="done"}[1h]))
/
  sum by (keeper) (rate(masc_keeper_turn_fsm_transitions_total{from="completing"}[1h]))

# Livelock incidence — separate from runtime_error after Step 4f.
rate(masc_keeper_turn_fsm_transitions_total{to="failed:turn_livelock_blocked"}[5m])
```

## Log line — `[fsm:transition]`

Format:

```
[fsm:transition] <prev_label> -> <state_label>
```

Emitted via `Log.Keeper.info` with the `keeper_name` and `turn_id` structured fields wired in Step 0a (#11154 / #11156 / #11159). A missing `?prev` renders as `-`.

The line text is stable and pinned by the `test_keeper_turn_fsm_emit` marker — a label rename or signature drift fails the build.

`emit_transition` also classifies every `(prev, next)` pair against the
runtime image of `KeeperTurnFSM.tla` `Next`. An edge outside the contract
increments `masc_fsm_guard_violation_total{action="KeeperTurnFSM.Next", ...}`
and re-raises `Assert_failure`. `MASC_FSM_GUARD_ASSERT=0` no longer enables
counter-only mode.

## Pulling a single turn back out

`bin/masc-trace` (Step 10 + 4k + 4l) prints all three artefacts of a (keeper, turn_id):

```
$ masc-trace ~/me alice 42
2026-04-28T... [receipt 04-28.jsonl] runtime=keeper-default outcome=skipped reason=...
2026-04-28T... [fsm] alice: [fsm:transition] - -> phase_gating
2026-04-28T... [fsm] alice: [fsm:transition] phase_gating -> done
1777248791.071 [tool keeper_tasks_list] ok duration_ms=372
```

Sources scanned (in order):
1. `.masc/keepers/<keeper>/execution-receipts/*.jsonl`
2. `.masc/logs/system_log_*.jsonl` (filtered to lines containing `[fsm:transition]`)
3. `.masc/tool_calls/<YYYY-MM>/<DD>.jsonl` (matched on `runtime_contract.keeper_turn_id`)

## Wiring sites

Source-of-truth cross-reference (after Step 4 caller adoption):

| Transition | File:line | PR |
|------------|-----------|-----|
| `Idle → Phase_gating` (entry) | `keeper_unified_turn.ml:96` | #11288 |
| `Phase_gating → Phase_gating` (SupervisorRequestsStop at entry) | `keeper_unified_turn.ml:116` | fix |
| `Phase_gating → Cancelled supervisor_stop` (HonorStopSignal at entry) | `keeper_unified_turn.ml:133` | fix |
| `Phase_gating → Done` (phase skip) | `keeper_unified_turn.ml:161` | #11269 |
| `Phase_gating → Runtime_routing` | `keeper_unified_turn.ml:169` | #11347 |
| `Runtime_routing → Failed runtime_unavailable` (ollama) | `keeper_unified_turn.ml:298` | #11269 |
| `Runtime_routing → Failed provider_error` (runtime build) | `keeper_unified_turn.ml:395` | #11340 (variant) + #11269 (site) |
| `Runtime_routing → Awaiting_provider` | `keeper_unified_turn.ml:449` | #11347 |
| `Runtime_routing → Failed turn_livelock_blocked` | `keeper_unified_turn.ml:441` | #11340 |
| `Awaiting_provider → Streaming` | `keeper_unified_turn.ml:803` (pre-`run_turn`) | #11358 |
| `Streaming → Streaming` (SupervisorRequestsStop in Eio.Cancel handler) | `keeper_unified_turn.ml:867` | fix |
| `Streaming → Failed provider_error` (retry exhausted) | `keeper_unified_turn.ml:1446` | #11363 |
| `Streaming → Completing` | `keeper_unified_turn.ml:2092` (stop_reason) | #11308 |
| `Streaming → Cancelled supervisor_stop` (HonorStopSignal, Eio.Cancel) | `keeper_unified_turn.ml:884` | Cycle 1b-iv |
| `Completing → Done` (success exit) | `keeper_unified_turn.ml:2119` | #11288 |

Pending edges (require `keeper_agent_run.ml run_turn` adoption — volume risk):
- `Streaming ⇄ Awaiting_tool_result` per tool call

Pending RISKY edges (require feature-flag / dual-emit infrastructure):
- `Completing → Failed receipt_lost` (Step 3 — receipt authoritative)
- `Streaming → Failed completion_contract_violation` (Step 6b-2 — typed classifier replacing string match)

## See also

- `docs/keeper-turn-lifecycle.md` — sequence + state diagram (source vocabulary)
- `docs/keeper-fsm-graph.dot` — cross sub-FSM edges (different metric)
- `lib/keeper/keeper_turn_fsm.mli` — ADT + `emit_transition` signature
- `specs/keeper-turn-fsm/KeeperTurnFSM.tla` — TLA+ spec (turn_state abstraction level)
- `planning/claude-plans/me-workspace-yousleepwhen-masc-hashed-pretzel.md` — parent plan, Phase 4 onward
