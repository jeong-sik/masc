# GOAL LOOP Verify Pipeline

`scripts/goal_loop_verify_pipeline.py` is the repo-owned contract for the
prompt-level Verify phase. It turns partial evidence into explicit gate records
instead of letting a narrow post-ACT log check stand in for full completion.

## Gate Contract

The output JSON has `schema_version: 1`, a top-level `status`, and one `gates`
entry per required check. `PASS` is only emitted when every gate passes.
Missing production evidence is represented as `BLOCKED`; mapped but unrun
commands are represented as `SKIPPED`.

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

## Completion Audit

`scripts/goal_loop_completion_audit.py --verify-pipeline <result.json>` consumes
the pipeline result. A partial pipeline adds the `verify_pipeline_complete`
blocker, so a generic Verify `PASS` cannot close the GOAL LOOP while metric,
TLA, log, or Orient gates are blocked.
