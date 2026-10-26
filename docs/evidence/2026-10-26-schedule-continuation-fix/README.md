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

The response adds `Chat_operation.t` to the existing unconstrained Owner fixture
value. Latest inspected main `1e5ae1f81ea68a69b565ebdee2e5000e69587dc9` still had the same missing annotation;
related open-PR searches found no separate repair. The continuation fixture now
checks absent cancellation as `Withdrawn`, exact reinsertion as the specific
incarnation error, and the replacement's unchanged pending selection and valid
current dispatch authority. No production guard is relaxed.

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

The product stack was subsequently rebased with `gh stack rebase` onto main
`fae95aaf9575fff4c9c7a18cd1dcf1d428d4227a`. This integration tree includes main's
changes and is not byte-identical to the earlier native artifact. Conflict
resolution preserves main's `Keeper_event_queue_state.equal_pending_selection`
as the single comparison authority in successor filtering, exact scheduled
scope matching, intake priority and the Owner regression. The duplicated
handoff comparison helper remains removed. F6's intake cohort, exact scheduled
scope and checkpoint retention remain part of the reviewed integration diff.
Earlier test results and the separate native proof branch remain bound to their
recorded source identities; no CI or runtime result is asserted for this rebased
head by this source-only resolution.


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
