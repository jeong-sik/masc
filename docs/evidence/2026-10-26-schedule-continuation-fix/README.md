# Scheduled work continuation repair: source evidence

The F6 reproduction in [the scheduled-job runtime audit PR](https://github.com/jeong-sik/masc/pull/46157)
ran installed binary `6a2d8dd6171e1d732ca15f918fb084e462e4d371`.
The first schedule checkpointed for a newly arrived second schedule, then its
source was durably marked completed before its requested note existed. Only the
second note was produced; both sources ended completed and no turn remained live.

The repair retains scheduled work through checkpoint settlement and admits one
exact scheduled occurrence per work scope. Intake carries the full original
pending snapshot separately from admitted work. Existing waiting sources cannot
preempt their successor as new input; a new incarnation can.

## Canonical helper reuse

[canonical-source-comparison.json](canonical-source-comparison.json) records a
byte comparison with PR #46125 at `b9e1fee387bb6e1f6eeeb3d42bbb9225ad7ace7f`.
The existing `keeper_heartbeat_source_batch.ml` implementation and its
`of_intake ~pending ~admitted` / `pending_at_intake` API are reused in the same
module. There is no parallel source-batch implementation.

This repair starts from main `6a2d8dd6171e1d732ca15f918fb084e462e4d371`.
Async stack #46110's observed top was PR #46178 at
`4db12cb6892eb357a9111c2aa097c2aca69f6f15`; it did not yet contain main's
scheduled Owner handoff. Taking that entire stack as the repair base would also
require integrating the newer schedule path. This PR instead brings forward the
same small canonical helper. Integration must reconcile both stacks' changes to
heartbeat settlement, intake, unified-turn preemption and Connector tests.
The async stack is not part of this PR's merge scope.

## Validation boundary

`ocamlc -stop-after parsing -c <file>` accepted all ten changed OCaml source and
interface files; `git diff --check` passed. No local Dune build, type check,
behavioral test, provider invocation or CI run was performed by this repair.
The working command log is under
`artifacts/schedule-continuation-fix-20261026/parse-only.log`.

Two authored cases in `test_keeper_connector_attention_batch` traverse actual
durable queue reads/writes, intake, dispatch validation, handoff candidate reads
and production checkpoint settlement. They cover checkpoint retention, exact
successor priority, original request/body re-admission, completed-source removal,
cold queue reload and cancellation/reinsertion. An existing mixed-source case
now asserts that independent scheduled occurrences cannot share one terminal
batch. These fixtures have not yet executed in this repair session.

Suggested focused targets are `test_keeper_connector_attention_batch`,
`test_keeper_failed_selection_disposition`, `test_keeper_owner` and
`test_schedule_consumer_dispatch`. The caller will request the necessary CI.
Cold queue reload is not process restart or provider-checkpoint replay proof.
Real-provider effect-before-yield duplication, successor/original effect
completion, restart, cancellation and replacement remain runtime validation
requirements. This repair does not add a general exactly-once tool-effect
protocol or claim arbitrary requested effects are verified by a turn terminal.
