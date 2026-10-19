# Explicit original-owner continuation resolution

Relates to #42799, specifically issuecomment-6175534613. This unit implements
the retained permanent-refusal follow-up from #43201. It does not close the
larger preparation, Composition, TUI and matched-observation objective.

## As-Is and To-Be

| Boundary | Before | Source behavior after this change |
| --- | --- | --- |
| Permanent dependency mismatch | Discovery keeps the original pending marker and reports `Invalid_result` on subsequent passes. Ordinary async cancellation rejects the physically terminal waiting worker. | An operator observes the exact original keeper/run/request, then explicitly rejects or cancels future continuation with that observation version and a reason. |
| Authority | Retention prevents unavailable dependencies from becoming successful results or replacement effects. No typed terminal operator path exists. | The original journal transaction compares the physical terminal, owner generation, exact journal bytes and marker identity before appending a terminal decision. Active/noncanonical/unknown source authority still refuses. |
| Marker retirement | Failed readiness cannot authorize retirement. | Only a durable terminal decision permits retiring its exact captured marker through the existing snapshot-guarded transaction. Same-byte inode replacement, changed bytes or competing ownership remain refused. |
| Original evidence | Source, Task, physical outcome, node results and artifact roots remain original. | Those records remain original. Resolution is an additional logical terminal event with caller, reason, time, original owner and observation evidence. No effect result or Task completion is synthesized. |
| Subsequent work | Unresolved retained runs can remain candidates for explicit recovery. | A resolved journal rejects bindings and worker/node/child mutations. It cannot recreate a pending marker through a rejected bind. Named child result reads return the explicit resolution as a typed failure without exports. |
| Interrupted cleanup | No explicit decision to resume cleanup from. | Same-command retries retain the first decision and timestamp and retry only exact marker retirement. A changed decision/caller/reason/version refuses. Committed resolution and retirement/settlement errors remain separate. |

For one permanently refused run, the expected indexed contribution changes
from one retained failure per discovery pass to zero after confirmed marker
retirement. This is a protocol-state expectation, not a runtime measurement.
The marker's stable lock sibling remains infrastructure. There is no expiry,
automatic purge, retry threshold, replacement request or replacement child
dispatch. Earlier or independently running child effects are not undone.

## Product path

`masc_operator_composition_resolution` is an operator-profile-only `CanAdmin`
tool with a closed `observe` / `reject` / `cancel` command. `observe` returns an
opaque `expected_version`. Mutations require that version and a nonblank reason;
the requesting identity comes from the operator call context. Unknown,
duplicate, missing and command-inappropriate fields refuse before mutation.

The resolution-only authority loader can revoke future continuation despite
unavailable dependency/artifact readiness. It does not issue a worker or grant
execution/replay authority. Journal structure, immutable source, current owner,
original named membership when applicable, and canonical physical waiting/lost
terminal proof remain strict. A corrupt journal, absent canonical owner or
physical source mismatch is still held for evidence repair rather than guessed
away. Ordinary request cancellation remains a separate operation.

The version binds the journal's exact bytes, the canonical terminal projection
and the pending marker's bytes and cursor fingerprint. The cursor includes
device, inode and end offset; its public fingerprint is observation only.
Actual retirement still presents the original snapshot to the filesystem
transaction. Binding prepares its marker inside the journal ownership check,
so a rejected post-resolution bind does not re-index a sealed owner.

The original journal append is durable before retirement. Interruption after
the append leaves a sealed run; discovery or the identical explicit command can
finish retiring only the original marker. The operator response distinguishes
the committed decision from unconfirmed retirement, including descriptor
settlement failure. No failed cleanup is described as rolling back resolution.

Named dependency observation reuses the owner reader's final journal snapshot.
A resolved child is ready for an authoritative failure read, with its original
physical terminal and explicit logical decision both retained. The result
reader's own pre-effect failure disposition is not a claim about earlier child
effects. No successful exports are fabricated.

## Authored compound scenarios and evidence limits

The existing first-loss resource scenarios now continue through stale marker
replacement refusal, explicit cancellation/rejection, immutable physical
outcome and journal-prefix preservation, rejected subsequent worker admission,
same-command idempotency and competing-caller refusal. Their original effect
resource remains unchanged.

A real public owned-job/Composition scenario adds a permanent canonical
dependency mismatch, observes its retained `Invalid_result`, explicitly rejects
the original owner, and checks original physical evidence and sibling artifact
preservation, stale continuation refusal, no pending discovery and public
resume rejection. Existing tool-inventory fixtures include the added vocabulary;
the operator-profile bypass contract includes this privileged command. No new
layout, wording, snapshot, row-order, helper-mirror or invocation-count test is
introduced.

All scenarios are authored and **unexecuted**. Validation is OCaml parsing only
and whitespace inspection; parsing is not type checking. No local build/test,
CI dispatch/watch, native/model/PTY/controller run, install, restart, live
configuration/prompt change or merge was performed. Runtime speed, visible TUI
behavior, cross-process recovery and measured Before/After remain unproven.

The larger six axes remain active: original Ask/Task/useful work; preparation
attribution and frozen discovery; ordinary/nested/dynamic/effectful Composition;
held reactivation and shared backends; usable cold input/TUI visibility; and
matched measurements retaining unsuccessful and incomplete samples. This unit
adds explicit terminal disposition and its observation path. It is not evidence
that the full objective or a release is complete.
