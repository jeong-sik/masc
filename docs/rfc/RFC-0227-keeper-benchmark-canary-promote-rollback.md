---
rfc: "0227"
title: "Keeper benchmark canary: wire verify -> gated promote -> rollback for per-keeper model selection"
status: Draft
created: 2026-06-11
updated: 2026-06-11
author: vincent
supersedes: []
superseded_by: null
related: ["0220"]
implementation_prs: []
---

# RFC-0227: Keeper benchmark canary — verify -> gated promote -> rollback

Status: Draft · Closes the half-built VPR loop around per-keeper model choice · No new conversation/runtime store
Drafted by: Claude Opus 4.8 (research-to-RFC pass with owner, 2026-06-11).

> Anchors marked **(verified)** were read against `origin/main` (`68c6a0877`)
> on 2026-06-11 while writing this RFC.

---

## §1 Problem — the benchmark canary verifies but nothing promotes or rolls back

`lib/keeper_benchmark_canary.mli` **(verified)** exposes a complete *verify*
half:

- `build_manifest : ?source_summary_path -> Tool_call_quality_benchmark.benchmark_summary -> manifest`
  turns a benchmark run into a `manifest` of per-profile `recommendation`s
  (`model_label`, `composite_score`, `task_pass_rate`, `stability_score`,
  `cases_total`, `cases_passed`).
- `recommended_model_label_for_keeper : keeper_name:string -> string option`
  is the read API for "which model did the benchmark recommend for this
  keeper".
- `load_manifest` / `default_manifest_path` / `enabled` round out persistence.

The *promote* and *rollback* halves are absent:

### 1.1 No promote: recommendations are never adopted

`recommended_model_label_for_keeper` has **zero callers** in `lib/` or `bin/`
(verified: `git grep recommended_model_label_for_keeper origin/main` returns
only the module itself and `lib/tool_call_quality_benchmark/dune`). A manifest
can be built and a recommendation read, but no keeper's model selection
consults it. The benchmark produces a number that changes nothing.

### 1.2 No rollback: a regressing promotion has no reverse edge

There is no signal path from "the promoted model is doing worse" back to
"revert to the prior model". A regression signal already exists elsewhere:
`Convergence.StagnationDetected { iterations_without_progress }`
(`lib/goal/convergence.ml:10` **(verified)**), emitted after a configurable
number of no-progress iterations (default 5, `convergence.mli:31`
**(verified)**). It is not wired to model selection.

### 1.3 Why this matters (autonomy <-> determinism)

Model choice is the autonomy lever; without a deterministic control loop
around it, choice is either frozen (today: a static default) or unguarded (a
naive "always use the recommended model" would adopt regressions with no
reverse edge). The canary already externalizes model quality into a
deterministic, on-disk manifest. This RFC adds the deterministic *control
loop* — gated promote + signal-driven rollback — so the non-deterministic
model behavior sits inside a measured harness. This is the MOSS
(verify -> promote -> rollback) shape applied to model selection.

## §2 Design principles

1. **Manifest is the SSOT, no separate promotion store.** The promoted model
   for a keeper is derived from the manifest plus a deterministic gate, read
   fresh at selection time. No standing "currently promoted" table, no cursor.
   Rollback state (a recommendation that regressed and must not be re-promoted)
   is recorded *in the manifest* as a typed status on the recommendation, not
   in a side store. Rationale: RFC-0223 §2.6 — accumulating small state
   machines (the deleted tool-retry budget #20624, the removed tool_heavy
   compaction trigger #20694) are the cautionary precedents.
2. **Gate is a total function, parse don't validate.** Promotion is
   `decide_promotion : recommendation -> current -> promotion_decision` over a
   closed sum (`Promote | Hold of hold_reason | Rollback of rollback_reason`),
   exhaustively matched. No `_ -> default` catch-all (software-development.md
   AI anti-pattern #4). Thresholds (min `composite_score`, min `task_pass_rate`,
   min `stability_score`) are named constants, not literals.
3. **Rollback is signal-driven, not time-driven.** The reverse edge fires on a
   typed regression signal (`StagnationDetected`, or a composite-score drop
   measured against the recommendation that was in force), never on a
   cooldown/timer. A cooldown here would be the cap/cooldown workaround
   signature.
4. **Opt-in and reversible.** `enabled ()` already gates the canary. Promotion
   defaults to off; when off, keeper model selection is exactly today's
   behavior. The gate is observable (the decision and its reason are logged as
   typed values).
5. **Benchmark stays out of the turn path.** `build_manifest` runs offline
   (benchmark job), as today. The turn-time cost is one manifest read +
   one total-function gate evaluation — no benchmark execution inside a turn.

## §3 Typed model (sketch)

```ocaml
type promotion_decision =
  | Promote of { model_label : string; composite_score : float }
  | Hold of hold_reason
  | Rollback of rollback_reason

and hold_reason =
  | Below_score_floor of { score : float; floor : float }
  | Below_pass_rate_floor of { rate : float; floor : float }
  | Insufficient_stability of { stability : float option }
  | No_recommendation

and rollback_reason =
  | Regression_stagnation of { iterations_without_progress : int }
  | Composite_score_regression of { from_score : float; to_score : float }

(* recommendation gains a typed status persisted in the manifest *)
type recommendation_status =
  | Candidate
  | Promoted of { since : string }
  | Rolled_back of { reason : string; at : string }
```

`decide_promotion` is total over `recommendation_status x signal`. Adding a
new status or signal forces every match site to be updated at compile time.

## §4 Phases

### P1 — Gate (verify -> promote, no rollback yet)
- Add `decide_promotion` + thresholds (named constants) in a new
  `keeper_model_promotion.ml` / `.mli`.
- Wire keeper model selection to consult
  `recommended_model_label_for_keeper` *through the gate* when promotion is
  enabled; otherwise unchanged.
- `recommendation_status` defaults to `Candidate`; P1 can promote to
  `Promoted` but never rolls back.
- Tests: gate is total; below-floor -> `Hold`; at/above floors -> `Promote`;
  disabled -> today's selection.

### P2 — Rollback edge
- Subscribe the promotion layer to `Convergence.StagnationDetected` for a
  keeper running a `Promoted` model -> emit `Rollback` -> mark the manifest
  recommendation `Rolled_back` -> next selection falls back to the prior
  (or default) model.
- Add composite-score-regression rollback: a fresh manifest whose
  `composite_score` for the promoted profile dropped below the in-force score
  by more than a named delta -> `Rollback`.
- Tests: TLA+ bug-model (software-development.md §TLA+) — a `RollbackAbsorbed`
  action that drops the reverse edge must violate a
  `RegressionAlwaysRollsBack` invariant; clean spec must satisfy it.

### P3 — Observability (not a fix, a window)
- Log each `promotion_decision` as a typed value (decision + reason). This is
  a window on an existing control loop, not a counter standing in for a fix
  (telemetry-as-fix is rejected).

## §5 Verification

| Claim | How |
|-------|-----|
| Gate is total | OCaml exhaustive match; no catch-all (CI ratchet already guards catch-alls) |
| Disabled = today's behavior | Test: `enabled () = false` -> selection identical to pre-RFC |
| Regression always rolls back | TLA+ clean vs `-buggy` cfg pair |
| No new store | Code review: promotion/rollback state lives in the manifest only |
| No cooldown/cap | Code review against workaround signatures |

## §6 Non-goals / boundaries

- Not a multi-armed-bandit / online learning loop. Promotion is gated on
  offline benchmark scores, not online reward.
- Not cross-keeper. Each keeper_profile is decided independently from its own
  recommendation.
- Does not change `build_manifest` or the benchmark itself (the verify half is
  already complete).
- Does not introduce a model-selection cache or cursor; selection reads the
  manifest each time.

## §7 Open questions

1. Where does "the model currently in force for a keeper" come from at
   selection time if not a store? Proposal: the manifest's `Promoted` status
   *is* that record (manifest as SSOT). Confirm this is sufficient for the
   rollback comparison, or whether the last-applied label must be read from
   the keeper's own recent run metadata instead.
2. Should `reset_for_testing` (already exposed in the canary `.mli`) be
   narrowed? It is a pre-existing test backdoor; this RFC neither widens nor
   relies on it.
