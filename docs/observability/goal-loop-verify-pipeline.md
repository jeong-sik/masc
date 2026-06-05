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
gate evidence records those snapshot keys separately from the underlying
`masc_*` metric series used to derive them. The rendered command examples
therefore query `GOAL_LOOP_METRICS_JSON` with `jq` instead of requiring an
external metrics CLI.

Covered gate groups:

- `unit_tests`: `dune runtest test/`
- `regression_metric`: semaphore skip, pricing miss, UTF-8 repair, recovery
  execution, and admission backpressure
- `metric_verification`: keeper turn success rate and dashboard snapshot latency
- `tla_check`: prompt specs
  `specs/goal-loop/{TierRouting,Validation,Liveness}.tla`
- `log_verification`: required and forbidden post-ACT production log patterns
- `orient_recheck`: still-present and new-finding counts from the Orient recheck

The current prompt TLA spec names are intentionally checked by exact filename:
`TierRouting.tla`, `Validation.tla`, and `Liveness.tla`. If those specs are
absent, the gate is `BLOCKED` with `reason: prompt_tla_spec_missing`; it is not
silently satisfied by adjacent TLA assets. The clean and buggy cfg pairs under
`specs/goal-loop/` are included in the TLA matrix shard so CI verifies both the
happy path and the corresponding bug model.

The pipeline result is the verification artifact. Completion gating should use
the explicit gate IDs and evidence payloads above, not a separate prompt-corpus
closeout ledger.
