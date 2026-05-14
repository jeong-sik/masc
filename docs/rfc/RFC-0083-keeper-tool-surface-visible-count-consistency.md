---
rfc: RFC-0083
title: Keeper tool surface `visible_tool_count` consistency (receipt ↔ cascade contract check)
author: jeong-sik (with Claude Opus 4.7)
created: 2026-05-15
status: Draft
supersedes: —
related:
  - RFC-0082 (last_blocker auto-clear — discovered this inconsistency during 3-axis root-cause analysis)
  - RFC-0057 (tool descriptor codegen — owns the descriptor side, receipt-side is unscoped)
  - RFC-0064 (two-surface tool-alias — surface name space, not count)
---

# RFC-0083: Keeper tool surface `visible_tool_count` consistency

## §0 Summary

A keeper's execution receipt records `visible_tool_count: 20` for a turn, yet the cascade-side completion contract check rejects the *same* turn with `"Completion contract [require_tool_use] violated: tool_choice requires tool use, but no tools are visible in this turn"`. Two sites in the per-turn pipeline disagree on how many tools are visible at the model dispatch boundary.

This RFC defines `visible_tool_count` as a *single value computed once per turn at dispatch boundary* and requires every downstream consumer (receipt writer, cascade contract checker, dashboard renderer) to read the *same* number. Producer→consumer drift is a CI lint failure.

This is a narrow RFC: one field, one boundary, one invariant. No new subsystem.

## §1 Problem (verified evidence)

Activity event from `~/me/.masc/activity-events/2026-05/14.jsonl`, 2026-05-14T14:53:55Z, keeper `masc-improver`:

```json
{
  "kind": "keeper.operator_broadcast_required",
  "payload": {
    "keeper_name": "masc-improver",
    "terminal_reason_code": "completion_contract_violation:require_tool_use",
    "error_kind": "agent",
    "error_message": "Completion contract [require_tool_use] violated: tool_choice requires tool use, but no tools are visible in this turn",
    "cascade_name": "tier-group.strict_tool_candidates",
    "model_used": null,
    "tool_contract": {
      "result": "satisfied_completion",
      "required_tools": [],
      "missing_required_tools": [],
      "visible_tool_count": 33,
      "tool_requirement": "required",
      "tool_surface_class": "mixed",
      "tool_gate_enabled": true
    }
  }
}
```

**The contradiction**: `tool_contract.visible_tool_count = 33` but the same event's `error_message` says "no tools are visible in this turn". The dispatch-side contract checker counted 0; the receipt-side checker counted 33. Same turn, same keeper, same activity event.

Earlier receipts from the same keeper show `visible_tool_count: 20`. The receipt-side number itself varies (20, 33) depending on which keeper-turn boundary writes the receipt — suggesting *neither side* has a stable definition of "what tools are visible for this turn".

## §2 Why this matters

1. The dispatch-side check fires first; if it sees 0 visible, the cascade rejects the turn with `completion_contract_violation`. The receipt writer (which sees ≥20) is left producing a record that *says* the turn had tools — operators reading the receipt cannot reproduce the failure.
2. RFC-0082 §2 noted this same inconsistency as evidence that `last_blocker` semantics are layered on top of inconsistent producers. RFC-0082's auto-clear hook will resume the keeper after each stuck cycle, but the *next* cycle will hit the same contract violation if `visible_tool_count` disagreement persists.
3. AI-generated PRs that touch tool surface assembly (RFC-0064 alias work, RFC-0042 typed terminal codes) will silently introduce new sites computing the count, because there is no SSOT to import. The disagreement count grows.

## §3 Goals / Non-goals

### Goals

- One function `Keeper_tool_surface.visible_for_dispatch ~meta ~turn` returns the canonical `int` for a turn.
- All sites that currently compute, log, or compare a "visible tool count" call that function.
- CI lint blocks reintroduction of ad-hoc counts (`List.length`, `Hashtbl.length`, `Array.length` directly on tool-list values inside `lib/keeper/`).

### Non-goals

- Redefining what "visible" means (allowlist filter / progressive disclosure rules in `lib/keeper/keeper_tools_oas.ml:888-911` stay as is).
- Tool descriptor codegen (RFC-0057 scope).
- Tool alias name space (RFC-0064 scope).
- Cascade tier resolution.

## §4 Design

### §4.1 SSOT function

`lib/keeper/keeper_tool_surface.ml(.mli)` — new module:

```ocaml
(* lib/keeper/keeper_tool_surface.mli *)
type counted = private {
  count : int;
  names : string list;          (* sorted, deduplicated *)
  computed_at : Mtime.t;
}

val visible_for_dispatch :
  meta:Keeper_types.keeper_meta ->
  turn:Keeper_types.working_context ->
  counted
(** Canonical visible-tool surface for a keeper turn at dispatch boundary.
    The result is computed *once* per turn, memoised against [(meta.agent_name, turn.id)].
    [count = List.length names] is an invariant guaranteed by construction. *)

val to_receipt_field : counted -> Yojson.Safe.t
val to_contract_check : counted -> int
val to_dashboard_payload : counted -> Yojson.Safe.t
```

The three projection functions (`to_receipt_field`, `to_contract_check`, `to_dashboard_payload`) are *the* interface for every downstream consumer.

### §4.2 Consumer migration

`rg -n "visible_tool_count\|visible_tools" lib/keeper/ | wc -l` returns the surface area (TBD in Phase 0 inventory). Each site converts to one of the three projection functions. Direct construction of the count outside `Keeper_tool_surface.visible_for_dispatch` is removed.

### §4.3 CI lint

`.github/workflows/lint.yml` adds:

```bash
# Block ad-hoc visible-tool counting outside the SSOT module
rg -n 'List\.length.*tool\|Hashtbl\.length.*tool\|visible_tools.*\.length' lib/keeper/ |
  rg -v 'keeper_tool_surface\.ml' |
  rg . && { echo "RFC-0083: count tools via Keeper_tool_surface.visible_for_dispatch"; exit 1; } || true
```

The pattern is intentionally conservative — false positives are reviewed via inline `(* RFC-0083-allowlist: <reason> *)` annotation.

## §5 Implementation phasing

| Phase | Files | LOC | Risk |
|---|---|---|---|
| **0 (this PR)** | `docs/rfc/RFC-0083-*.md` | docs only | none |
| **1** | `lib/keeper/keeper_tool_surface.ml{,i}` + 1 reference consumer in `lib/keeper/keeper_tools_oas.ml:852` | ~150 | low (additive) |
| **2** | Migrate `lib/keeper/keeper_execution_receipt.ml` `visible_tool_count` to SSOT | ~80 | medium (wire-format observable) |
| **3** | Migrate cascade-side contract check (`lib/cascade/cascade_runner.ml` — exact site TBD in Phase 1 inventory) | ~120 | medium (rejects fewer/more turns; canary) |
| **4** | Dashboard renderer migration + CI lint | ~80 | low |

Each phase compiles independently; each phase's PR includes a *count-of-disagreements* test that builds two keepers with identical config and asserts both projections return the same `int`.

## §6 Verification

- **Differential test**: a keeper turn that today produces `receipt.visible_tool_count != cascade.visible_for_check` becomes a compile-time impossibility — both paths derive from the same `counted.count`.
- **Production canary** (Phase 3): replay the 2026-05-14T14:53:55Z masc-improver fixture; the turn should either succeed (count=33, tools visible) or fail with a *single coherent* reason — not a contradictory receipt.
- **Inventory drift**: `scripts/rfc-0083-inventory.sh --check` exits non-zero if a new site computes visible tool count outside `Keeper_tool_surface`.

## §7 Risks

| Risk | Mitigation |
|---|---|
| Phase 2 wire-format change breaks downstream dashboard renderer | Dashboard already reads `tool_contract.visible_tool_count` — keep field name, change only how it's *computed* |
| Phase 3 alters which turns are rejected (real behaviour change) | Production canary on a single keeper for 24h; rollback flag `MASC_TOOL_SURFACE_SSOT=0` |
| Memoisation key `(agent_name, turn.id)` is wrong (turn re-entry) | Use turn's `dispatch_id` (monotonic per dispatch attempt) instead of `turn.id` |

## §8 Stop conditions

- Phase 1 inventory: if `rg -n "visible_tool_count" lib/keeper/` returns > 30 distinct sites, the RFC's surface area is wider than expected — split into RFC-0083a (receipt + cascade) and RFC-0083b (dashboard + telemetry).
- Phase 3 canary: if the differential test fails (counts still disagree after migration), the bug is upstream of dispatch — escalate to a tool-surface-assembly RFC, not a counting fix.

## §9 References

- Activity event evidence: `~/me/.masc/activity-events/2026-05/14.jsonl` line for 2026-05-14T14:53:55Z (masc-improver)
- RFC-0082 §2 §6 — listed this inconsistency as a parallel finding; RFC-0083 is the targeted fix
- 3-axis investigation transcripts (this session): `/private/tmp/claude-502/-Users-dancer-me/<session>/tasks/{a8c42e55f427f68da,a2b20180f03ae2f55,ad8ec8979cef72647}.output`

🤖 Generated with [Claude Code](https://claude.com/claude-code) during masc-improver Tier 1 unblock follow-up
