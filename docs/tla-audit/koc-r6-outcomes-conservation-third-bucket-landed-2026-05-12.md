# KOC R-6 — KeeperOutcomesConservation.tla: the third bucket landed; preamble "SCOPE DRIFT (r always 0)" note is now stale (first-entry audit, fixed)

**Date**: 2026-05-12 · **Iteration**: 79 (`/loop` FSM/TLA+/OCaml drift hunt) · **Phase**: R (first entry)
**Spec**: `specs/keeper-state-machine/KeeperOutcomesConservation.tla` (157 LOC, 4 vars, bug-model paired)
**OCaml**: `lib/dashboard/dashboard_http_keeper.ml` — `compute_outcomes_rollup`
**Verdict**: **model correct throughout; preamble lags the runtime (sub-class 9: spec-banner-lags-runtime), fixed comment-only**. The spec body (`successes + failures + rejected = observed_turns`, three single-bucket actions, `BuggyDoubleBucket` mutation) was *always* the right model. But the preamble's `OCaml ↔ TLA+ mapping` had drifted line numbers (`:81/:82/:89`), a stale 2-bucket form (`observed_turns = succ_turns + fail_turn`), and — most notably — a "SCOPE DRIFT" note saying *"r is always 0 ... the spec's 3-bucket law holds vacuously ... when `gate_rejected` becomes a live counter the spec invariant becomes load-bearing"*. That has happened: `fail_gate_rejected` is now a live counter, and the OCaml's own doc-comment cites `{!KeeperOutcomesConservation.tla}` with the matching 3-bucket law. Fixed: symbol-anchored the mapping, replaced "SCOPE DRIFT" with a "Runtime status (2026-05-12)" block.

## What the spec is

`KeeperOutcomesConservation.tla` proves `ConservationLaw == successes + failures + rejected = observed_turns` — every observed turn lands in exactly one outcome bucket, so pass-rate percentages (`successes / observed_turns`) shown in the Agent Modal's "결과 / 실패 / 검증" section are truthful. Bug model `BuggyDoubleBucket` categorises one turn into two buckets at once (bumps `successes` and `failures`, `observed_turns` only once) → `ConservationLaw` fails. TLC: clean = no error; buggy = `Invariant ConservationLaw is violated`. (Re-verified this PR — model body untouched.)

## What drifted (sub-class 9: spec-banner-lags-runtime, + sub-class 8 line-refs along the way)

| Preamble claim (as written) | Reality 2026-05-12 (`compute_outcomes_rollup` in `dashboard_http_keeper.ml`) | Fix |
|---|---|---|
| `successes` ← `succ_turns` (incr on `Turn_succeeded`) — `dashboard_http_keeper.ml:81` | `succ_turns` ref at line **74**; incr when a `completed_turn_record` has outcome `Keeper_transition_audit.Turn_substantive` (not "`Turn_succeeded`") | symbol anchor; correct outcome variant name |
| `failures` ← `fail_turn` (incr on `Turn_failed _`) — `:82` | `fail_turn` ref at line **77**; incr on `Turn_failed` | symbol anchor |
| `rejected` ← `gate_rejected` field — **"currently 0 — see scope drift below"** | `fail_gate_rejected` ref at line **78**; incr on `Turn_gate_rejected` (line 89). **A LIVE COUNTER** — no longer always 0. The json export emits `("gate_rejected", \`Int !fail_gate_rejected)` | symbol anchor; "NO LONGER always 0" |
| `observed_turns` ← `succ_turns + fail_turn` — `:89` | `let observed_turns = List.length completed_turns` (line **102**) — the size of the `Keeper_transition_audit.recent_completed_turns` 50-entry ring; line 89 is `incr fail_gate_rejected)`. The three counters **partition exactly this list**, so `succ_turns + fail_turn + fail_gate_rejected = observed_turns` by construction | symbol anchor; 3-bucket form |
| "SCOPE DRIFT ... The OCaml comment above compute_outcomes_rollup (lines 60-64) reads: 'Historical [gate_rejected] counts are not yet persisted ... the field remains 0'" | The *current* OCaml doc-comment (above `compute_outcomes_rollup`) reads: *"Conservation law (spec {!KeeperOutcomesConservation.tla}): successes.substantive_turns + failures.turn_failed + failures.gate_rejected = observed_turns holds by construction because all three turn buckets now come from the same completed-turn ring."* The "remains 0" comment is gone | replaced with "Runtime status (2026-05-12, iter 79 R-6)": the third bucket landed; conservation is load-bearing and OCaml-satisfied by construction |

## Cross-checks (pass)

| Spec element | Runtime | Status |
|---|---|---|
| `successes` / `failures` / `rejected` (each turn bumps exactly one + `observed_turns`) | `succ_turns` / `fail_turn` / `fail_gate_rejected` refs, incremented in a single `List.iter` over `completed_turns` via an exhaustive `match turn.outcome with Turn_substantive \| Turn_failed \| Turn_gate_rejected` | ✓ — exhaustive 3-way match = exactly one bucket per turn |
| `observed_turns` = sum of the three buckets | `List.length completed_turns` — the list the three counters partition | ✓ — conservation by construction |
| `ConservationLaw` is load-bearing (not vacuous) | `gate_rejected` is a live counter | ✓ as of this PR's preamble |
| OCaml ↔ spec cross-ref | OCaml doc-comment cites `{!KeeperOutcomesConservation.tla}` + the matching law; spec preamble cites `dashboard_http_keeper.ml:compute_outcomes_rollup` | ✓ bidirectional |
| `.cfg` / `-buggy.cfg` | both present | ✓ |
| Bug-Model contract | clean = no error; buggy = `Invariant ConservationLaw is violated` — re-verified this PR | ✓ |
| Out-of-scope counters (`succ_compactions` / `fail_compaction` / `succ_handoffs` / `fail_handoff` / `keeper_verdicts`) correctly excluded | those refs exist in `compute_outcomes_rollup` but are per-mechanism, not per-turn, and don't feed `observed_turns` | ✓ — preamble's "out-of-scope" note still accurate |

## Sub-class placement & follow-up

- This is **first-entry sub-class 9 (spec-banner-lags-runtime)** — the same shape as iter 68 KEQ Q-1 / iter 69 KEQ Q-2 (the spec preamble framed something as not-yet-true while the runtime had caught up). Inverse of sub-class 7 (runtime-owes-spec, e.g. KOAS M-1). The line-ref drift in the mapping table (sub-class 8) tagged along; both fixed the same way (symbol anchors).
- No follow-up PR owed. Comment-only spec change — model body byte-identical; `specs/INDEX.md` regenerated (KOC content-hash bump `c53dded69dc1 → 7ac6ec2c5bf3`).
- The spec is in the `make -C specs check-clean` runner (not `KNOWN_FAILURES`); CI re-checks it. The OCaml's `{!KeeperOutcomesConservation.tla}` doc-comment cross-ref means a future change to `compute_outcomes_rollup` that breaks conservation should be caught at review time *and* by running the spec's buggy cfg — exactly the workflow the old "SCOPE DRIFT" note recommended, now retrospectively confirmed.
