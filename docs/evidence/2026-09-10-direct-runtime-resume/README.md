# Direct Keeper runtime continuation wiring

This unit connects the durable direct-runtime continuation contract to direct
turn dispatch, the Owner child lifecycle and the operation transcript. It is
stacked on `fix/direct-keeper-continuation`.

A typed driver deferral keeps the original operation queued with its original
input, task/channel/attachments and frozen runtime suffix. Before consuming that
continuation, dispatch loads the current canonical checkpoint, verifies its exact
reference and requires the original operation to own the checkpoint's active
repetition scope. A checkpoint belonging to a different invocation, or a changed
canonical checkpoint, is rejected before inference. This does not roll shared
history backwards. Existing quota ordering can move a missing frozen successor
behind still-resolvable members; it cannot introduce a new runtime candidate.

The native runtime continues the accepted checkpoint without appending the user
input again. Eager image admission is skipped on resume; explicit blocks remain
available for official-client runtimes through the driver's existing per-runtime
projection. A deferred child releases the Owner slot without terminalizing the
operation. The Keeper-to-Keeper adapter does not report `Delegate_no_reply` while
that operation has a durable pending runtime continuation.

Pending runtime attempts persist only their new tool rows, leaving the original
operation's terminal assistant slot available for the actual answer. New tool
rows after a resume use `Operation_checkpoint`, binding their ordinal namespace
to the original operation and its exact incoming checkpoint. The original user
and final assistant retain the original operation identity. Prior canonical
execution IDs cannot be republished under the new attempt key.

## Verification boundary

`test_keeper_direct_runtime_resume` includes a real loopback HTTP fixture:
primary tool result, provider 429, durable deferral, Owner teardown/reinstallation,
removal of the first frozen successor, and completion using the remaining
alternate runtime. It checks the same operation and complete input, one effect
execution, the original user input once, and the completed tool receipt in the
alternate request. Separate tests exercise active-scope denial and the same
server persistence function used by `process_single_turn`, then reload the
final answer and both attempts' tool evidence. `test_keeper_owner` also covers
nonterminal child settlement and automatic same-operation draining.

These tests are written but have not yet run at this unit's commit boundary.
`git diff --check` and source-only `ocamldep` parsing passed. No local build ran.
CI, deployed runtime replay of the original failed operation, connector delivery,
and a reload of that live final answer remain separate acceptance evidence.
No semantic verification or completed production replay is claimed here.
