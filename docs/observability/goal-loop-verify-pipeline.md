# GOAL LOOP Verify Pipeline

`scripts/goal_loop_verify_pipeline.py` is the repo-owned contract for the
prompt-level Verify phase. It turns partial evidence into explicit gate records
instead of letting a narrow post-ACT log check stand in for full completion.

## Gate Contract

The output JSON has `schema_version: 1`, a top-level `status`, and one `gates`
entry per required check. `PASS` is only emitted when every gate passes.
Missing production evidence is represented as `BLOCKED`; mapped but unrun
commands are represented as `SKIPPED`.

Metric gates read snapshot keys from the JSON passed via `--metrics-json`; the
gate evidence records those snapshot keys separately from any underlying
`masc_*` Prometheus series used to derive them. The rendered command examples
therefore query `GOAL_LOOP_METRICS_JSON` with `jq` instead of naming a
non-repo `prometheus` CLI.

`scripts/goal_loop_metrics_snapshot.py` converts a Prometheus text scrape into
that JSON shape. It derives the keeper turn success rate, regression counters,
admission queue values, and dashboard latency p99 from `/metrics` text, while
requiring explicit `--set key=value` overrides for non-Prometheus evidence such
as Orient recheck totals or recovery execution counts.
The current live-derived metric fixture is
`test/fixtures/goal_loop/verify-pipeline-live-metrics.external-claim.json`.
It is intentionally not green: the fixture turns observed regressions into
`FAIL` gates while leaving absent metric families as `BLOCKED`.

Covered gate groups:

- `unit_tests`: `dune runtest test/`
- `regression_metric`: semaphore skip, pricing miss, UTF-8 repair, recovery
  execution, and admission backpressure
- `metric_verification`: keeper turn success rate and dashboard snapshot latency
- `tla_check`: prompt specs `TierRouting.tla`, `Validation.tla`, `Liveness.tla`
- `log_verification`: required and forbidden post-ACT production log patterns
- `orient_recheck`: still-present and new-finding counts from the Orient recheck

The current prompt TLA spec names are intentionally checked by exact filename.
If those specs are absent, the gate is `BLOCKED` with
`reason: prompt_tla_spec_missing`; it is not silently satisfied by adjacent
TLA assets.
The prompt-level specs live under `specs/goal-loop/`:
`TierRouting.tla`, `Validation.tla`, and `Liveness.tla`. TLC run evidence for
the current fixture is recorded in
`test/fixtures/goal_loop/verify-pipeline-tla-results.external-claim.json` and
fed into the pipeline with `--tla-results-json`.

## Completion Audit

`scripts/goal_loop_completion_audit.py --verify-pipeline <result.json>` consumes
the pipeline result. A partial pipeline adds the `verify_pipeline_complete`
blocker, so a generic Verify `PASS` cannot close the GOAL LOOP while metric,
TLA, log, or Orient gates are blocked.
For schema version 1, completion also validates the reported gate counts and the
full required gate-id set, so a minimal all-PASS fixture cannot stand in for the
repo-owned Verify contract.
