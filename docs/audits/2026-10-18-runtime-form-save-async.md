# Runtime model and account forms: owned asynchronous saves

Source baseline: `5dea900c6261e51ac45b035dfd504c7c3d3a79f0` (#43663).

## As-Is / To-Be

| Boundary | Baseline | This layer |
| --- | --- | --- |
| Successful model/account submit | Key handler waits for three identity checks, one raw source read, preview and guarded commit | Key handler records immutable input and starts an owned worker |
| Logical HTTP waits in that key-handler chain | Six | Zero |
| Logical HTTP calls for the same successful save | Six | Six; no round-trip reduction claimed |
| Local declaration and response interpretation | Runs from the inline submit chain | Frozen source decode uses shared CPU submission; declaration uses shared IO submission because account/client-path resolution can read environment/files |
| Another submit | UI cannot process it while save waits | Existing pending operation blocks a duplicate across both forms |
| Leave the form | Input handling waits for the chain | Esc leaves without claiming rollback; existing edit/add keys restore its original draft |
| Disconnection after possible dispatch | Draft retained as refusal text | Typed unconfirmed receipt and exact prepared text retained; recovered form cannot resubmit |
| Fresh attempt after terminal result | Reopening loses original form context | Explicit Ctrl-X closes recovery and rereads config; next open is a new intent |
| Late completion | Inline completion owns the visible form implicitly | Original request token, physical input identity, authority and workspace gate visible updates; receipts still survive withdrawal |
| Status | Final result or form refusal | Checking, validation, submission and terminal outcome remain visible on the relevant config pane |
| Observation | No form operation timeline | Request start, worker observation and UI admission share a request-start identity; no source text or form fields in structured timing records |

These are source-derived dependency/ownership counts on the successful path,
not measured responsiveness or speedup. Pool absence or existing inline-worker
policy may still run declaration/decoding inline. No new pool or timing gate is
introduced. File commit, durability and routing/keeper/skill application retain
the existing receipt semantics.

## Operation continuity

Each operation keeps its original model/account form, workspace identity,
authority and opening revision. Preparation retains the exact read base and
transformed submitted text. A changed opening revision refuses before applying
fields. Account field-specific rejection retains the typed form. Preview and
CAS commit use the same prepared text/path/revision and original workspace.

Workers atomically publish monotonic status before notification. The input loop
reads advancing observations directly, so bounded mailbox capacity cannot delay
commit dispatch or erase cancellation receipts. Coalesced checking-to-posting or
terminal admission is valid; late progress cannot regress terminal uncertainty.
Authority withdrawal before worker entry publishes not-sent. Cancellation before
the commit marker is not-sent; after possible dispatch it is unconfirmed. There
is no automatic save retry. Esc does not cancel an admitted operation. Request
records are session memory, not a durable restart journal.

Only the still-attached original form in its confirmed original authority can
close or become a saved sign-in card. A detached or old-authority receipt cannot
overwrite a successor. The current workspace may revalidate configuration and
runtime inventory after a matching receipt; operation facts survive read-scope
withdrawal without granting that read authority. Existing raw-editor and lane
writes remain separate flows guarded by server source-revision CAS; this layer
serializes the two forms, not every runtime writer.

## Evidence and remaining work

Three feature/state scenarios are authored and **unexecuted**: actual model
transformation on the opening source and changed-revision refusal; pending
sharing, skipped intermediate admission, retained unknown/cancellation outcome,
explicit fresh intent and late-receipt protection; typed account refusal and
original-workspace recovery. No wording/layout/snapshot/PTY test is added.

Only parser-only checks, diff hygiene and changelog validation are authorized.
Typing, scenario execution, CI, independent current-head approval, native/model
runs, installation, restart, runtime behavior, painted UI and timing remain
unverified. No live runtime/config writes occurred in this implementation unit.

The wider preparation/first-input/readability/Ask-to-original-Task-to-work,
resource-owned Composition, held-job/shared-backend continuity and matched
Before/After goal remains open. Raw editor saves, other inline mutations and
end-to-end resource/cancellation behavior remain follow-up implementation and
evidence work; this form layer does not close those requirements.
