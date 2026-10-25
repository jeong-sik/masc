# Fusion invocation counters

`masc_fusion_invocations_total` has three labels. `topology` names the requested topology. `outcome` describes policy refusal or the returned delivery result. `judge_result` describes the already-computed canonical judge result and its recorded judge nodes independently.

| outcome | Meaning |
|---|---|
| denied | Policy refused computation. |
| completed | The sink returned success, including delivery of a failed deliberation. |
| sink_failed | The sink returned an error; delivery remains unresolved. |

| judge_result | Meaning |
|---|---|
| not_attempted | Policy refused computation, or the failed deliberation contains no judge nodes, such as unmet panel quorum. |
| failed | A deliberation with recorded judge nodes has a failed canonical result. |
| synthesized | A canonical synthesis is available and no judge node is recorded as failed. |
| synthesized_with_failures | A canonical synthesis is available alongside failed judge nodes, such as a failed refinement or meta judge. |

A delivered failure is `outcome="completed", judge_result="failed"`; successful delivery does not imply successful judgment. These labels describe canonical results and recorded node outcomes, not every candidate attempt inside a seat. Provider/tool coverage gaps and failed seat candidates remain in the run's own tool trace and seat routes.

The counter is process-local and records each policy refusal or returned projection attempt. A repeated delivery attempt increments it again. It is not a unique-run count, a durable receipt, proof of HTTP dispatch, or an exception-complete event journal. A zero sample does not prove zero dispatch. If projection raises before returning, no returned-result increment is made. Unknown usage and absent elapsed time remain unknown; this metric supplies neither value.

Queries that aggregate delivery results across judge outcomes should sum by `topology,outcome`. Queries that compare synthesis and failure should retain `judge_result`. The per-node counter `masc_fusion_judge_executions_total` continues to record actual node outcomes and roles.

Production emission is owned by `Fusion_orchestrator.compute` for denials and `Fusion_orchestrator.project` after `Fusion_sink.emit` returns. The metrics API requires the original deliberation for projection classification. Source: `lib/fusion/fusion_metrics.mli` and `lib/fusion/fusion_orchestrator.ml`.
