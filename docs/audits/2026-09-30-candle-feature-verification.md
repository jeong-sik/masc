# Candle feature verification: remaining completion requirements

This is a scope audit, not an acceptance or deployment verdict. The implementation
reference is integration commit `f4673b23d7686a62ace921be5ecb588e7e072f88`.
Requirements come from [the Candle RFC](../rfc/RFC-goal-candle-ledger.md),
particularly sections3.2,3.6,3.7,3.9 and5, plus the operator decisions recorded
in audit issue#39953: shared ownerless Goals, hard cut, and five explicit grades.

## Authority boundaries

| Requirement | Implementation/evidence owner | Completion limit |
|---|---|---|
| Shared Goal; Task claim owns responsibility | #39975, Goal schema/public actor history | Live hard cut is approved but unapplied; prepare current data with writers stopped at rollout |
| Snapshot follows exact successful verifier run | `Candle_snapshot`, `test_candle_goal_flow` same-second orphan case | An arbitrary earlier Snapshot is not payment authority |
| Human confirmation commits obligation; reopen does not remit | Confirmation handler and worker | Positive whole-path coverage gap described below |
| Model decisions cannot manufacture eligible recipients or money | `Candle_appraise`, `Candle_payment`, `test_candle_appraisal_flow` | Injected judgments prove orchestration/arithmetic, not model quality |
| No wallet/supply secondary storage | Immutable `Candle_balance` fold; `Candle_observe` single view | Decimal strings and Zarith aggregates; only actual credited allocations issue currency |
| Purchase/equip trusted self; Item catalog follows Look types | `Keeper_candle_tools`, shop/equipment, purchase and portrait HTTP suites | Public response and rendering evidence is distinct from deployed identity |
| HTTP and proactive SSE withdraw unavailable authority | `Dashboard_projection_cache`, execution surface preparation | New SSE path passes integrated f467 payload scenario; not live socket ordering proof |
| TUI/browser keep lifecycle usable during monetary failure | Strict decoder, currency state, Keeper surfaces | Synthetic wire PTY/browser evidence does not prove live Keeper behavior |
| Keeper discovers balance/purchase without reward prompt injection | Eager tool descriptors; `test_candle_purchase_flow` | Shared Keeper prompt stays separate; no automatic balance context or work gate |
| Decay remains Off | Explicit policy and constitution boundary | `HalfLifeSet`/Hours require the separate adopted constitution amendment; no implicit authorization here |

## Evidence available

- Currency run[36595091066](https://github.com/jeong-sik/masc/actions/runs/36595091066),
  source `f86dfe04f95a4ef608b92cc0985d6cff56b8a9d7`:17 suites completed,
  653 Alcotest cases and four real TUI PTY scenarios. Bundle in
  #40024 commit1448d6e02d, `docs/evidence/2026-09-30-candle-currency-native`.
  The run contains real isolated ledger1000→800/public-roster/strict-decoder
  assertions and separate synthetic-wire terminal scenarios. It predates SSE
  correction7a5cdd and main Dashboard composition.
- Actual native purchase/equip before/after PNGs and browser replay are retained
  in `docs/evidence/2026-09-30-equipped-portrait-browser`. Component replay is
  not a full browser purchase session or remote TUI PNG proof.
- Integrated frontend atf467: six files/64 tests and full TypeScript check pass.
- Combined30 run[36597801658](https://github.com/jeong-sik/masc/actions/runs/36597801658)
  atf467 has29/30 targeted suites passing, including the new SSE payload
  scenario and main Dashboard currency PTY. Remote TUI list/PNG scenario
  fails; it is not an integration PASS. [Raw results](../evidence/2026-09-30-candle-integration-f467/README.md)
  distinguish the observed paths and limits.
- Collector run[36591058373](https://github.com/jeong-sik/masc/actions/runs/36591058373)
  at26b0541d completed all four Python CLI cases through its Dune alias.
  Missing edit events are `not_observed`, not zero actual edits.

## Remote roster defect and historical cache failures

Cross27 run36595321621 at649adfa completed its targeted step with25/27
successful suites. The real remote TUI passed the workspace-mismatch assertion
but displayed no Keeper rows: the remote lifecycle roster did not populate the
list that local metadata normally filled. This is an implementation defect,
not successful remote PNG evidence. A fix must use authoritative remote data
without inventing local configuration or re-enabling local reads on mismatch.

The other failing suite was dashboard HTTP, with seven prepared-byte assertions.
That older smoke fixture lacked portrait fields on its Keeper/continuity rows;
the response overlay therefore changed its JSON. Equip parent9b304ffaf0 fixes
those four fixture lines. Currency and f467 already contain them, and the
currencyf86 dashboard suite passed all135cases. No cache assertion was weakened.

## Positive completion-to-payment coverage gap

The inspected `test_candle_goal_flow` uses actual Goal tool creation,
production proof commit and HTTP confirmation callback, but its worker scenario
has no linked Tasks and ends as Unattributed. The positive
`test_candle_appraisal_flow` begins from manually appended Snapshot/PayoutOwed
and prepared Candidates. Both are useful, but neither alone proves that the
actual successful Goal path reaches Paid.

The missing scenario must connect:

1. A persisted Goal and linked completed Task belonging to a configured Keeper.
2. Production proof commit, then the existing HTTP confirmation handler.
3. Confirmation wake of the real payout worker and production candidate readers.
4. Paid for the exact confirmed run and expected recipient/balance.
5. Reconfirmation, reopen/new proof, and worker restart without a second payment.

Only the model decision boundary may be injected. Do not directly append
Snapshot, PayoutOwed, Candidates or Paid in this scenario. A successful test
will prove this orchestration path; actual provider judgments remain separate.

## Semantic acceptance remains incomplete

The retained baseline has240 structurally valid actual-model decisions and a
confirmed short/expanded-title grade mode divergence. The separate candidate
experiment is ongoing. Human20Goal labels, accepted stability/fairness
thresholds and all five grade boundaries remain uncalibrated. Assistant rubric
proposals are not human labels. Do not infer payout readiness from type checks,
injected judgments or a successful transport receipt.

No source check or scoped fixture establishes the constitution's10-turn and
1h/2h/4h/24h+ multi-runtime Keeper continuity, deployed binary identity or the
live shared-Goal hard cut. These remain independent completion requirements.
