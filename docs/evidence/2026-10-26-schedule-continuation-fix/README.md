# Scheduled work continuation repair: source evidence

The F6 reproduction in [the scheduled-job runtime audit PR](https://github.com/jeong-sik/masc/pull/46157)
ran installed binary `6a2d8dd6171e1d732ca15f918fb084e462e4d371`.
The first schedule checkpointed for a newly arrived second schedule, then its
source was durably marked completed before its requested note existed. Only the
second note was produced; both sources ended completed and no turn remained live.

The repair retains scheduled work through checkpoint settlement and admits one
exact scheduled occurrence per work scope. A schedule that intake already saw,
including a suspended predecessor, cannot preempt its successor. A schedule
that reaches the queue after that intake read can, and so can one that was
withdrawn and reinserted.

## Where the repair lives

- `keeper_heartbeat_loop.ml` `checkpoint_source_policy` maps `Schedule_due` to
  `Preserve_and_rotate`. At a checkpoint, `retain_checkpoint_continuations`
  keeps the occurrence pending and moves it to the tail of its urgency lane;
  `checkpoint_source_may_ack` is false for it, so the checkpoint never ACKs it.
- `keeper_heartbeat_stimulus_intake.ml` `source_scope` gives each `Schedule_due`
  its own `Scheduled_work` scope, compared with
  `Keeper_event_queue_state.same_entry`. One intake therefore admits one
  scheduled occurrence and no other source with it.
- `keeper_scheduled_turn_handoff.ml` `successors ~intake` returns the pending
  scheduled entries for which `Keeper_heartbeat_source_batch.arrived_since_intake`
  holds. `request ~intake` hands off only those. Retention, deferral and
  reprioritization keep an entry's arrival; an ACK followed by reinsertion
  creates a later one.
- `keeper_unified_turn.ml` `make_autonomous_yield_probe` passes the running
  turn's intake batch as `~intake`. `keeper_chat_yield_request.ml` passes
  `Keeper_heartbeat_source_batch.empty`, which has no intake read, so every
  pending scheduled entry is a candidate there.

## Validation boundary

`ocamlc -stop-after parsing -c <file>` accepted all ten changed OCaml source and
interface files; `git diff --check` passed. No local Dune build, type check,
behavioral test or provider invocation was performed locally. The caller
later requested the focused CI and isolated provider execution recorded below.
The working command log is under
`artifacts/schedule-continuation-fix-20261026/parse-only.log`.

Two authored cases in `test_keeper_connector_attention_batch` traverse actual
durable queue reads/writes, intake, dispatch validation, handoff candidate reads
and production checkpoint settlement. They cover checkpoint retention, exact
successor priority, original request/body re-admission, completed-source removal,
cold queue reload and cancellation/reinsertion. An existing mixed-source case
now asserts that independent scheduled occurrences cannot share one terminal
batch. Both new cases pass in the 32-case Connector suite at the exact
`b5c9762b27845918eba2acb804434a0da435cc78` execution recorded below. That run
still fails three separate Owner fixtures; it is not an overall passing run.

Suggested focused targets are `test_keeper_connector_attention_batch`,
`test_keeper_failed_selection_disposition`, `test_keeper_owner` and
`test_schedule_consumer_dispatch`. The caller will request the necessary CI.
Cold queue reload is not process restart or provider-checkpoint replay proof.
Actual DeepSeek/GLM successor/original note completion on product94b2 is
reported separately below. Effect-before-checkpoint nonduplication, restart,
cancellation and replacement remain runtime validation requirements. This repair does not add a general exactly-once tool-effect
protocol or claim arbitrary requested effects are verified by a turn terminal.

## First focused CI failure and test response

[**Test 40334229000**](https://github.com/jeong-sik/masc/actions/runs/40334229000),
head `94b2df25abcdfe20c658322f4156ad63f5546c34`, ref
`fix/schedule-work-continuation-20261026`, completed with **failure**.
The [retained original metadata, exact selected log lines and digest manifest](ci40334229000/manifest.json)
preserve the failure; the original full log and archive remain at the recorded
local capture path. The archive hash matches GitHub's artifact digest and its
log bytes match the original extracted file.

- Owner suite: compilation stopped at `test_keeper_owner.ml:5874`, unbound
  `operation_id` record field; no Owner cases executed.
- Connector batch: 31 passed, 1 failed. New case 0 passed the complete queue
  checkpoint/successor/original assertions. New case 1 reached reinsertion and
  failed because the authoritative API correctly returned
  `event queue pending selection incarnation changed`, rather than withdrawal.
- Failure-disposition suite: 16 passed. Informational-checkpoint suite: 1 passed.
  These partial results do not make the overall run successful.

The continuation fixture now checks absent cancellation as `Withdrawn`, exact
reinsertion as the specific incarnation error, and the replacement's unchanged
pending selection and valid current dispatch authority. No production guard is
relaxed.

From `94b2df25abcdfe20c658322f4156ad63f5546c34` through the pre-rebase head
`ccb0007e95ead82676a58d0dcc17d740dfe94f30`, only test sources and evidence
changed; `lib/` and `bin/` were byte-identical within that historical interval.
The native proof run targeting the earlier source is not changed, cancelled
or retried by this response. Its product artifact can be compared within those
unchanged product inputs; it is not a current-head test result or proof that a
later integration tree is identical. Both modified `.ml` files passed syntax
parsing and `git diff --check` at the first correction boundary.
At that first correction boundary the tests were unexecuted. The caller then
requested the exact two-suite execution recorded below; its failure is preserved.

## Second focused CI and faithful Owner continuation fixture

**Test [40341860767](https://github.com/jeong-sik/masc/actions/runs/40341860767)**,
head `b5c9762b27845918eba2acb804434a0da435cc78`, ref
`fix/schedule-work-continuation-20261026`, completed with **failure**. Connector
passes all 32 cases, including both new continuation cases. Owner executes 106:
103 pass and three scheduled-handoff cases fail because the original operation
does not become terminal. [Selected failure evidence and original digests](https://github.com/jeong-sik/masc/pull/46221)
retain that result.

All three failing fixtures produce `invalid semantic execution transition:
action is not admitted in suspended`. The fixture defers the original exact
checkpoint, then reclaims the operation and reports success without consuming
that checkpoint. The production runner instead calls
`Keeper_direct_checkpoint_continuation.consume`, which invokes
`Owner.resume_direct_checkpoint` before executing the continuation. Claiming the
operation alone does not resume suspended semantic execution. The natural
completion case has no suspended checkpoint and passes.

The fixture now follows that existing exact resume path, verifies checkpoint
consumption and running operation id/digest, and confirms that scheduled-source
and fresh-chat scopes preserve the original checkpoint. No production source,
state guard, sleep or polling count is changed. Independent source review found
no P0–P2 in this test delta; parse and whitespace checks pass. The new correction
has not yet executed and is not a passing Owner result.

## Isolated actual models and native source boundary

Native **Test [40339887803](https://github.com/jeong-sik/masc/actions/runs/40339887803)**
uses definition `117dc31e1ca8f71f47bbbe91fa2adab5befb5761`, ref
`ci/schedule-native-runtime-proof-20261026`, actual product source
`94b2df25abcdfe20c658322f4156ad63f5546c34`, conclusion **success**. The downloaded
archive, seven distribution files and embedded source were verified before
running its server in owned workspaces. That historical source remains distinct
from later test-only heads even when their product trees are identical.

[Actual repair validation](https://github.com/jeong-sik/masc/pull/46221) retains
DeepSeek and GLM checkpoint/source readmission, both exact required note effects,
and delayed first-source ACK. GLM writes the first note only after that source is
readmitted, with observer11 PASS and producer exit0. The first DeepSeek observer
remains failed because it missed the sampled overlap; its independent complete
raw-ledger review is separate evidence. Two after-effect arrivals complete
sequentially and contain no after-effect checkpoint. These examples do not prove
arbitrary effects exactly once, account/provider failover, crash recovery,
external delivery or whole-feature PASS. No production executable was installed.

## Integration on main 6d83e98b

The stack is rebased onto main `6d83e98b165706284b28015bcb7e822685904671`. This
tree is not byte-identical to the earlier native artifact; earlier test results
and the native proof branch stay bound to their recorded source identities.

Local checks ran at `d0433c4ea61867a8869f135f566bc4eecbf1bd73`. Later commits
change only `docs/` and `changelog.d/`. `dune build --cache=enabled @lib/check
@bin/check @packages/check` exited 0. Each test executable ran from `test/` with
`DUNE_SOURCEROOT` set to the checkout and
`MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED=false`:

| Executable | Cases | Failed |
| --- | --- | --- |
| `test_keeper_connector_attention_batch` | 39 | 0 |
| `test_keeper_connector_attention_wake` | 11 | 0 |
| `test_keeper_failed_selection_disposition` | 16 | 0 |
| `test_keeper_owner` | 108 | 0 |
| `test_keeper_board_turn_ack` | 1 | 1 (`continuity` 0) |
| `test_schedule_consumer_dispatch` | 60 | 1 (`keeper_wake` 21) |
| `test_keeper_informational_checkpoint_ack` | 1 | 1 (`production cycle` 0) |
| `test_keeper_codex_current_context` | 31 | 1 (`native requests` 22) |

The four failing cases fail the same way when built and run the same way at
main `6d83e98b165706284b28015bcb7e822685904671`. These are local results, not
CI, and not a full `@runtest`.
