---
status: partial
updated: 2026-10-24
---

# Verification model identity observation

Calibration previously called a comparison of runtime configuration keys a
`cross_model_rate`. Two keys can resolve to the same model, and one key can
change its provider or model after a submission. The rate also became `0.0`
when no producer key had been recorded. Neither result measured independent
models.

The current measurement uses `distinct_runtime_count` and
`distinct_runtime_rate` for that comparison. The rate is `null` with no
recorded runtime pair. `model_identity_observation` reports
`{ "kind": "unobserved", "verdict_count": N }`: these verdicts have no bound
producer/judge model pair. The dashboard projects these ledger observations
without computing another rate. This fixes a misleading measurement; the
model independence finding remains open.

## Existing evidence and its gaps

| Boundary | Current fact | Missing binding |
| --- | --- | --- |
| `keeper_tool_task_runtime.ml`, `keeper_task_done` | The Keeper submits through `Task.Tool.handle_transition`. | The task tool context contains configuration, agent name, and switch; the submission does not carry the active execution identity. |
| `verification_protocol.ml`, `create_submit_request` | Captures artifacts and collaboration content at submit time. | It receives worker name and claim, with no producer turn or attempt identity. Reading current Keeper metadata cannot identify the attempt that submitted this request. |
| `verification.ml` and `workspace_verification_snapshot.ml` | The request stores task, worker, time, output, and immutable evidence. | No producer execution binding survives reload. |
| `runtime/runtime_observation.mli` | A captured execution has `observation_id`, `runtime_id`, `selected_model`, and attempt facts. | There is no submission-to-observation relation. `selected_model = None` remains an observation gap. |
| `keeper_execution_receipt.mli` | The receipt retains trace, turn, current task, selected model, and lane evidence. | Current task alone does not prove which attempt submitted which verification request. |
| `workspace_metric_hooks.ml`, reviewer hook | The named runner returns a `Runtime_agent.run_result`; its runtime observation is available at this boundary. | The hook returns only `selected_runtime_id` and verdict, discarding the observation identity and selected model. |
| `anti_rationalization.ml/.mli` | `reviewer_reply` and `review_result` retain the actual winning runtime key. | The judge execution/model observation does not reach calibration. |
| `completion_authority_agent.ml` and `eval_calibration.ml` | Correlate the request, verdict, and calibration notes hash. | No pair of captured producer/judge identities can be compared. |

## Required next implementation

1. Pass a host-owned producer execution binding through the task tool context
   and `Verification_protocol.create_submit_request`. A binding must identify
   the exact observation/attempt that dispatched the submitting tool, along
   with its worker, trace/turn, and task. User-authored tool arguments and a
   later `last_model_used` lookup cannot supply it. Non-Keeper submissions
   remain explicitly unobserved when no binding is available.
2. Persist that binding with the immutable verification request and validate
   it on read. A tool can submit before its turn receipt settles, so distinguish
   an attested execution reference whose observation has not settled from a
   missing reference. Join only the exact bound observation when it exists;
   never pick the newest receipt for the worker or task. Artifact content and
   its original hash remain the original submission.
3. Retain the winning judge's `Runtime_agent.run_result.runtime_observation`
   in `workspace_metric_hooks.ml`; carry its identity and actual selected model
   through `reviewer_reply`, `review_result`, review notes, and the verdict
   ledger. Failed candidates, a later continuation, and a configured lane
   alias cannot stand in for the verdict-producing attempt.
4. Record provider/model identities from the actual runtime observation or
   its captured provider attempt. A model label alone is insufficient when
   its provider namespace is absent. Extend the producer-owned observation
   if a runtime cannot currently supply this evidence; preserve unknown
   values rather than resolving the current runtime catalog retrospectively.
5. Compare only complete attested pairs. Report observed-pair coverage,
   unknown coverage and causes, same-model count, and distinct-model count.
   A ratio is absent when the observed-pair denominator is zero. Runtime-key
   diversity remains a separate diagnostic.

This is an observation contract, not a Task approval policy. Note-only Task
judgment and the separate Goal proof/person-confirmation policy remain as
configured. Missing model provenance does not itself authorize a new gate.

## Required scenarios

Native tests must cover two runtime aliases selecting the same actual model,
one alias changing configuration after submission, a successful judge fallback
whose actual model differs from the requested slot, producer continuation after
submission, a still-settling bound execution, a missing capture, a non-Keeper
producer, and restart/readback of the immutable request. Calibration and its
dashboard projection must retain unknown coverage for every unproven pair.

The bounded measurement change has authored calibration and dashboard tests
for missing producer runtime data, mixed runtime aliases, and retained
unobserved-model coverage. Local validation is source syntax and whitespace
only for OCaml. The dashboard TypeScript check reports the same two TS2322
errors in `keeper-stream.test.ts` at lines 1862 and 1873 with both the changed
and original overview interface. Linked tests, CI, installed binaries, and
live producer/judge readback have not been established by this change.
