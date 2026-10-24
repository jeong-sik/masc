# Task approval and external outcome scope (A7)

The approval branch in `workspace_task_transitions.ml` wrote `success=true`
to the Task metric hook. The aggregate's `task_success_rate` then reached
`masc_agent_fitness` as `components.reliability`, and the agent detail rendered
it as 신뢰도. That stream records Task lifecycle observations; it contains no
external acceptance observations and cannot establish Goal success.

The hook and Task-completed telemetry convenience API now accept a closed
`Approved | Cancelled` terminal observation. One pure module in the existing
types library projects it onto the existing durable boolean. Task metric/event
storage formats are unchanged; historical `success` remains recorded lifecycle
success and is not upgraded to independently observed acceptance.

Aggregates explicitly state `outcome_basis="task_lifecycle"` and
`external_acceptance={"kind":"unobserved","completed_tasks":N}`. The latter
describes missing external observations in this stream for its N unambiguous
completed Tasks, including cancellations. It does not say another authority
has never observed an external result. No external success rate is invented.
The fitness component is now `task_lifecycle_success`; its output schema, strict
dashboard parser, and displayed 작업 승인률 label share that meaning. The UI
states that external acceptance is unobserved here and Goal human confirmation
is separate. There is no additional counter, ledger, approval gate, or Goal
transition; note-only approval policy is unchanged.

## Bounded source execution

Run from the candidate checkout with installed OCaml/ocamlfind, yojson,
ppx_deriving_yojson, ppx_deriving.show, and Alcotest:

```sh
python3 docs/evidence/2026-10-24-task-outcome-scope/verify_scope.py \
  --repo "$PWD" --out /tmp/masc-task-outcome-check-new-directory
```

The output directory must be new. The recorded final run used
`/tmp/masc-task-outcome-probe-20261024-r2`.

The script executes the actual Task types, aggregation, and fitness-component
source fragments from exact base `3e8a9f3f26f841ad9fc7508555f07e84e19a5ff5`
and candidate. An explicit `read_recent` input port supplies fixture rows; no
aggregation or component calculation is reimplemented. The full new observation
module and its two focused tests also compile with fatal warnings and run.
`source-manifest.json` retains exact source hashes, extracted fragments, and the
port. `observations.json` retains the resulting JSON.

| Supplied Task records | Before | After |
| --- | --- | --- |
| One successful terminal record | `reliability=1`, no outcome scope | `task_lifecycle_success=1`, external acceptance unobserved for 1 Task |
| One successful and one cancelled record | `reliability=0.5` | Lifecycle rate 0.5, external acceptance unobserved for 2 Tasks |
| One pending record | Undefined success rate | Undefined lifecycle rate, 0 completed Tasks with unobserved acceptance |

This executes the real aggregation and projection code against injected records.
It does not execute producer hooks, telemetry persistence, completion authority,
Goal policy, native MASC linking, or a live Keeper. The actual approval-path
integration test now asserts an `Approved` metric with external acceptance still
unobserved, but native execution is pending.

## Frontend and remaining checks

The actual `src/api/agent-fitness.test.ts` suite passed 6/6, including the detail
refresh and refusal of fabricated acceptance/basis or mismatched coverage.
`frontend-verification.json` records command, source hashes and scope.

Whole-dashboard `pnpm exec tsc --noEmit` exits 2 on both the candidate and an
exact-base dashboard/test-fixture archive with the same installed dependencies.
The two diagnostics at `src/keeper-stream.test.ts:1862,1873` are identical;
`candidate-tsc.txt` and `baseline-tsc.txt` preserve them. There are no new
diagnostics from this change. OCaml syntax parsing passed for all 19 changed
ML/MLI sources. Neither result is native dependency linking.

Focused native suites for the integrated candidate are
`test_task_outcome_measurement`, `test_metrics_store_eio`,
`test_tool_task_coverage`, `test_tool_agent_coverage`,
`test_telemetry_task_transition_10358`, `test_keeper_tool_plan`, and
`test_error_logging_coverage`. No local Dune command was run.
