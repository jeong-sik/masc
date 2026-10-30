# Durable Goal cancellation audit

Base: #41053 at `389224c1dbbaf8a64787740d0da160769ce135a7`.

When the audit path cannot be appended, `drop` used to commit Dropped and then
raise from the separate audit write. The retry took the Already path and never
recreated the missing audit. The same five registered scenarios run against the
parent implementation fail in both recovery cases (2/5 failures).

The cancellation now decides from the current locked Goal and commits its phase,
review metadata and audit intent in the existing Goal store transaction. Delivery
uses the existing Goal_delivery owner. A delivery failure leaves the successful
cancellation intact and reports `effect_delivery.status = deferred`, with a durable
retry. Repeating drop drains the outbox while preserving the original reason,
event identity and no-op behavior. The cancellation hook only fires on a change.
No new persistence schema, lifecycle phase or verifier authority is introduced.

## Evidence

The candidate passes all five registered regressions, and the existing complete
Goal tool suite passes 26/26 through its tool dispatch paths (31 cases total):

1. An obstructed audit path, followed by repeated Drop, emits one event with the
   original ID and actor; it does not overwrite the reason or repeat the hook.
2. A fresh child process drains the pending event even after the Goal was deleted.
3. Failure to persist Goal state produces no phase change, event or hook.
4. An unreadable primary is refused without repairing or overwriting it.
5. A missing Goal is not created by Drop.

The complete Workspace_goals implementation is compiled natively, against its
unchanged cached public signature. The interface change is documentation only.
The registered suite runs with a direct module alias and cached lower dependencies.
The cached Goal_store, Goal_delivery and Goal_verification source copies match the
candidate exactly; hashes are recorded. Temporary files are real filesystem writes,
and recovery case 2 starts a separate process using Eio.Process.run.

Runner: `python3 check-goal-drop.py CHECKOUT CACHE_CHECKOUT`. Add
`--source-ref 389224c1dbbaf8a64787740d0da160769ce135a7` for the failing baseline, or
`--suite test_goal_tools` for the existing tool suite. It creates its own temporary
directory, prints it, retains native outputs, and exits nonzero when tests fail.
An initial restart-harness attempt used Unix.waitpid inside Eio and was interrupted
with EINTR; the final registered case uses Eio's process manager and passes.

This is scoped native evidence, not a full product build, production restart,
provider execution, independent approval, merge or deployment. The creation-time
criterion feasibility review (D3) and Pause/Resume/Block/Unblock (D4) remain separate
unimplemented capabilities. Existing request-complete, reopen and confirmation
paths are unchanged; this PR makes no wider claim that all lifecycle side effects
already have the same durable boundary.
