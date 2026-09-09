# Direct runtime continuation: Owner journal contract

This first unit provides the durable contract. It does not yet wire direct
Keeper dispatch to that contract, so the observed direct-turn failure is not
resolved by this unit alone.

A typed runtime retry records an exact checkpoint reference and the driver-owned
frozen runtime suffix in the existing semantic-execution journal. One transaction
binds it to the original chat operation's canonical execution input and returns
that same operation to Queued. Source/channel metadata, message, attachments,
turn instructions, admission identity and execution digest are preserved.
Queued input edits are refused after semantic admission.

After Owner claim, continuation may enter Running only when the caller supplies
the exact observed checkpoint/runtime identity. The dispatch integration must
independently re-read the canonical checkpoint bytes and verify their operation
scope before calling this method; the SQLite layer does not inspect checkpoint
files. Checkpoint equality is not permission to replay the original user input.

Startup restores a Running chat claim only when its semantic journal still owns
a bound pending runtime retry. If resumed execution had already entered Running
without a new durable deferral, startup requires reconciliation instead of
replaying effects from an older checkpoint. The original semantic input remains
available for that reconciliation. No timeout, retry counter or error-string
classification authorizes these transitions.

Successful/failed/cancelled operation settlement updates its associated semantic
record in the same transaction. Commit uncertainty is resolved by reading the
exact committed state where possible; unconfirmed commits remain errors.
Owner mailbox methods serialize these mutations with queue claims and lifecycle
operations.

Seven new store scenarios cover same-operation completion after reopen, restart
between claim and resume, checkpoint mismatch, interrupted resumed execution,
input/edit binding, deferral commit faults, resume commit readback and cancellation.
They are written but have not been built or executed locally. CI must validate
this unit together with the existing operation and semantic-store suites.

Still required in the dependent dispatch unit: capture the typed driver deferral,
validate actual checkpoint/effect ownership, pass its frozen suffix to the next
attempt, skip re-admitting the checkpointed user input, retain the original
channel/attachments/task context, and emit a continuing operation outcome instead
of terminal failure. Real provider fallback and owner-restart proof remain open.
