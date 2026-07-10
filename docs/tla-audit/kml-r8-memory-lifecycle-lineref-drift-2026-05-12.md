# KML R-8 — KeeperMemoryLifecycle.tla: horizon-constant line-refs drifted +46; symbol-anchored (first-entry audit, fixed) + line-ref drift class survey

**Date**: 2026-05-12 · **Iteration**: 81 (`/loop` FSM/TLA+/OCaml drift hunt) · **Phase**: R (first entry)
**Spec**: `specs/keeper-state-machine/KeeperMemoryLifecycle.tla` (265 LOC, bug-model paired)
**OCaml**: `lib/keeper/keeper_memory_policy.ml` (`short_term_horizon` / `mid_term_horizon` / `long_term_horizon` constants) · `keeper_memory_bank.ml` / `keeper_memory_recall.ml` (symbol-anchored already, accurate)
**Verdict**: **model correct; the 4 `keeper_memory_policy.ml:155-157` citations drifted +46 (the horizon constants are now ~line 201-203), symbol-anchored comment-only**. Everything else in the preamble is already symbol-anchored (`memory_horizon_of_kind_opt`, `memory_horizon_of_kind`, `memory_horizon_of_json_opt`, the persistence sites) and accurate. TLC re-verified (clean = no error; buggy = invariant violated).

## What the spec is

`KeeperMemoryLifecycle.tla` models the short/mid/long memory tiers across note capture, overflow compaction, and generation handoff. Safety goals: provenance on every persisted note, no silent drop on overflow/handoff, handoff clears stale short-term notes, each tier within its bound. Bug model `BuggyCompactOverflow` trims the short tier without promoting to mid → dropped notes accumulate in `lost_notes`. TLC: clean = no error; buggy = invariant violated (`TypeOK` fires first in the buggy cfg's invariant list `{TypeOK, ProvenanceRequired, NoSilentLoss, RecoveryBounded, HandoffLeavesNoStaleShort}` — see "pre-existing observation" below).

## What drifted (sub-class 8: line-reference drift)

| Spec citation (×4 occurrences) | Actual location 2026-05-12 | Drift | Fix |
|---|---|---|---|
| `lib/keeper/keeper_memory_policy.ml:155` — `short_mem` ↔ `horizon = "short_term"` (mapping table) | `let short_term_horizon = "short_term"` at line **201** | **+46** | `lib/keeper/keeper_memory_policy.ml — \`short_term_horizon\`` |
| `lib/keeper/keeper_memory_policy.ml:156` — `mid_mem` | `let mid_term_horizon = "mid_term"` at line **202** | **+46** | `— \`mid_term_horizon\`` |
| `lib/keeper/keeper_memory_policy.ml:157` — `long_mem` | `let long_term_horizon = "long_term"` at line **203** | **+46** | `— \`long_term_horizon\`` |
| `lib/keeper/keeper_memory_policy.ml:155-157` — "Tier vocabulary" block header (followed by the three `let ... = "..."` lines verbatim) | constants at lines 201-203 | **+46** | drop the `:155-157`; the block already lists the `let` definitions verbatim, so "the horizon string constants in lib/keeper/keeper_memory_policy.ml" suffices |

The rest of the preamble's OCaml refs were already symbol-anchored and verified accurate:
- `memory_horizon_of_kind_opt` (strict, line 207), `memory_horizon_of_kind` (back-compat wrapper, line 218 — still has `| None -> mid_term_horizon`), `memory_horizon_of_json_opt` (line 230) — all by name ✓
- `keeper_memory_bank.ml:append_memory_notes_from_tool_results`, `keeper_memory_recall.ml:read_recent_memory_texts`, `keeper_compact_policy.ml`, `keeper_compact_audit.ml` — by name/file ✓
- The "SCOPE DRIFT" note (`memory_horizon_of_kind` routes unknown kinds to `mid_term_horizon` via `| None -> mid_term_horizon`; tracked for the `#8605` strict-`_opt`-plus-warn-wrapper template) — still accurate (the wrapper still defaults; the strict `_opt` exists, the wrapper still doesn't reject) ✓

## Line-ref drift class — survey across the spec corpus (the reason this iteration was a "sweep candidate")

iters 77→80 found four consecutive first-entry audits with stale preamble line numbers (KDM, KCGP, KOC, KLP). A `rg '\.ml:[0-9]' specs/keeper-state-machine/*.tla` shows the citation style appears in **~12 spec files, ~50+ hits**. But not all are drifted:

- **Stable** (top-of-file refs that don't move): `KeeperCompactionLifecycle.tla:18-21` cites `keeper_state_machine.ml:8/10/11/14` for the `type phase` constructors `Running`/`Overflowed`/`Compacting`/`Paused` — and `type phase` *is* at lines 6-19 of `keeper_state_machine.ml`, so `Running` is genuinely at line 8, etc. Refs to a type declaration at the very top of a file don't rot.
- **Drifted** (refs into functions deep in growing files): the ones the loop has been fixing — `keeper_registry.ml:NNN` (file grew ~1k lines → KLP iter 80 drifts up to +1035), `keeper_memory_policy.ml:155-157` (this PR, +46), `keeper_run_tools.ml:NNN` (retired surface pipeline spec — ~15 hits, lines 794-1011 cited — probably drifted), `keeper_post_turn.ml:NNN` (KeeperPostTurnOrchestration — ~8 hits), `keeper_unified_turn.ml:318/1640`, `keeper_state_machine.ml:402-408/754-758`, `keeper_registry.ml:63-68/70-74/76-81` (the 3-axis type defs — cited by 4 specs: KeeperRuntimeLifecycle, KeeperDecisionPipeline, KeeperTurnCycle — these are mid-file type defs, likely drifted), `keeper_social_model_magentic_ledger_v1.ml:204`, `keeper_composite_observer.ml:25-32`.

**Recommendation** (not done here — too large for one 10-min PR, and a pure "ban `\.ml:[0-9]`" lint would be the string-classifier workaround pattern):
1. **Extend the existing validator** `scripts/audit-tla-ml-line-refs.sh` (iter 64 #14925, currently handles `[funcname]...line N`) to also resolve the `<file>:<line>` citation form and warn on drift > tolerance. This *resolves* the ref (the right structural fix — it tells you the true line) rather than banning the syntax. The validator already has the OCaml-file-resolution machinery; the new patterns are `\b\w+\.ml:[0-9]+` and `\b\w+\.ml:[0-9]+-[0-9]+`.
2. **Per-spec symbol-anchor PRs**, prioritized by drift magnitude — retired surface pipeline spec (~15 hits) and the 3-axis-type-def trio (KeeperRuntimeLifecycle/KeeperDecisionPipeline/KeeperTurnCycle, shared `keeper_registry.ml:63-81` refs) are the biggest remaining clusters.

## Pre-existing observation (not fixed here — out of scope)

The `KeeperMemoryLifecycle-buggy.cfg` invariant list puts `TypeOK` first, so TLC reports `TypeOK is violated` rather than the *intended* `NoSilentLoss` (the spec preamble says "NoSilentLoss MUST be violated"). A well-formed buggy cfg often omits `TypeOK` so the demonstrated violation is the property the spec exists to defend. This is pre-existing (not introduced by this comment-only PR) and is a candidate follow-up: drop `TypeOK` from the buggy cfg (or confirm the bug action genuinely produces a malformed state, in which case keep it but note why). Out of scope for a line-ref-drift fix.

## Sub-class placement & follow-up

- Drift = **sub-class 8 (line-reference drift)** — fifth consecutive first-entry audit to hit it. Fix: symbol anchors + a top-of-mapping note recording the convention switch and drift magnitude.
- No follow-up PR owed for *this* spec. The corpus-wide follow-ups are the two recommendations above (extend the validator; per-spec symbol-anchor PRs for the biggest remaining clusters). Comment-only spec change — model body byte-identical; `specs/INDEX.md` regenerated (KML content-hash bump `821cd485dadf → aacf99ece735`). The spec is in the `make -C specs check-clean` runner; CI re-checks it.
