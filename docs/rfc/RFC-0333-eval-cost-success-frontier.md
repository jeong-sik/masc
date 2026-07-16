# RFC-0333 — Deterministic cost↔success frontier join for the eval harness

- Status: Draft
- Decision driver: Ilya-30-papers adversarial transfer census (2026-07-08), axis A2's surviving core after the scaling-law refutation: "`total_cost_usd` ↔ `pass_at_k` paired frontier join — 오늘 없는 join, stochasticity 추가 0." The Kaplan curve-fit proposal was refuted on power grounds (6-value quantized Bernoulli at n=5, SE≈0.22, <1 OOM of resource range — curve shape unidentifiable); what survives is a deterministic join over data the harness already records.
- Area: `lib/eval_harness.ml:105,113-124` (`eval_run.total_cost_usd`, `eval_result` carrying both `pass_at_k` and `total_cost_usd` per scenario, `:321-337` aggregation), `:629-633` (summary print — pass/score/consistency only).
- Refinement over the census (fresh-read 2026-07-09): the census said "success↔cost가 join 안 됨"; in fact both metrics already coexist **per scenario** in `eval_result`. The missing join is **across configurations** — nothing pairs the same scenario under different resource configs (model, panel size, retry budget) and computes dominance, and the human-facing summary does not surface cost at all.

## Problem (audited)

Resource choices (which model, what panel width, how many retries) are made without a cost-per-success comparison, even though every input is already recorded:

- Per run: `total_cost_usd : float option` (`eval_harness.ml:105`), missing costs propagate as `None` (`sum_costs`, `:309-311`) — the honest-unknown path already exists.
- Per scenario: `pass_at_k` (`:334`) and summed `total_cost_usd` (`:337`) sit in the same record; the PASS/FAIL summary (`:629-633`) prints pass\@k, mean score, and consistency but not cost.
- Fusion accepts the supplied non-empty panel set without a product-owned width cap. Panel width remains useful as an explicit eval dimension, not an execution gate.

The refuted alternative (fit `success = f(N, R, B)` curves) would have burned ~900 real API calls to produce "no recommendation" at the harness's statistical power. The frontier join asks a weaker, answerable question: **among the configs we actually ran, which are dominated** (worse-or-equal success at higher-or-equal cost)?

## Decision

1. **A deterministic pairing**: group `eval_result`s by scenario across configs (config identity = the scenario's resource parameters, carried explicitly rather than parsed from names). Emit per scenario a frontier table: `(config, pass_at_k, total_cost_usd, cost_per_success)` where `cost_per_success = total_cost_usd / max pass_at_k ε` is defined only when cost is known (`None` cost ⇒ excluded from ranking, shown as unknown — never coerced to 0/free; the unknown-model→$0 anti-pattern is the exact failure class this respects).
2. **Dominance verdict, not a recommendation engine**: a config is `Dominated` iff some other config has ≥ pass_at_k and ≤ cost with at least one strict inequality; otherwise `On_frontier`. A closed sum, no scores, no fitting, no thresholds to tune.
3. **Statistical honesty is structural**: results with `min_runs_met = false` (`:123`) are excluded from dominance and rendered as `Insufficient_runs` — the harness's own n≥5 gate, reused. No confidence claims beyond what `ci95_low/high` already carry.
4. **Zero new stochasticity**: the join is a pure function over persisted `eval_suite_result`s. No new API calls; the sufficient-power A/B (n≈200) stays DEFER as the census recorded.

## Waves

| Wave | Scope | Exit criterion |
|---|---|---|
| W1 | `frontier_row` / `dominance = On_frontier \| Dominated \| Insufficient_runs \| Unknown_cost` types + pure join fn + unit pins | dominance is a total function over any two results; None cost never ranks |
| W2 | Summary surface: frontier table in the suite report (`:629` region) and JSON output | cost visible where pass/fail already prints |
| W3 | Panel-width sweep harness configs (for example 2/4/8) as explicit experiment inputs | one recorded comparison exists; no runtime cap or auto-tuning is introduced |

## Verification

- Property pins: dominance is irreflexive/antisymmetric on strict pairs; `None` cost ⇒ `Unknown_cost` regardless of pass_at_k; `min_runs_met=false` ⇒ `Insufficient_runs` even if it would dominate.
- Golden test: a fixed 3-config fixture with a known frontier.
- Workaround-gate self-check: no curve fitting, no learned scorer, no threshold knobs — a dominated/on-frontier partition is the whole output.

## Boundaries (untouched)

- `compute_pass_at_k` and CI math — unchanged.
- Panel cardinality is not a runtime governance knob; W3 observes explicit experiment inputs only.
- No new eval executions are triggered by the join itself; it consumes existing results.

## Evidence record

- Evidence: `lib/eval_harness.ml:105,113-124,309-337,629-633`, census artifact e1d4ba86 (axis A2, WEAKENED→surviving core), fresh-read re-verified 2026-07-09 at `63b5a69975` including the per-scenario-join refinement.
- Confidence: High (all cited lines re-read; the census claim was tightened, not weakened, by the re-read).
- Delta: replaces the refuted Kaplan-style curve fit with a dominance partition over already-persisted data; the expensive A/B remains deferred.
