# Original Ask follow-up cancellation settlement

Source parent: `ba9bc37928f538efce872f7a8dd3c012255a20fe` (#44619).
Addresses the P3 lifecycle lead in parent #44613 review `5593512312`.
This is an implementation delta, not a measured runtime incident or speedup.
The full six-axis objective and matched actual Before/After remain incomplete.

## As-Is / To-Be

| Boundary | Parent source | This source |
| --- | --- | --- |
| Raw producer cancellation | Propagates, retires result token, no terminal message | Caller-provided original cancellation observation publishes through the original token, then raw cancellation/backtrace propagate |
| Ask worker cleanup | Original worker handle clears | Same; physical worker cleanup and job registration release stay with existing lifecycle |
| Original read ticket | Only admitted terminal settles it; raw cancellation produces none | Existing scoped terminal admission settles that exact request; a replacement owner/ticket rejects it |
| Pre-dispatch cancelled switch | No retained terminal | Original cancellation terminal retained; observation-only caller metadata cleanup runs |
| Withdrawal before worker entry | Caller metadata clears, no terminal | Original cancellation terminal retained with the same token; UI still checks old scope/owner |
| Partial sources | Previously published parts remain | Original FIFO retained; received sources stay received, unreceived sources finish unconfirmed |
| UI | Generic incomplete-read notice | Reason shown beside retained observations, using the same safe wrapped field |
| Operation/session results | Cancellation propagates without a synthetic receipt | Same policy (`Propagate`); explicit cancellation observation belongs only to partial-observation API |

`launch_observation` requires an already formed `cancelled` message containing
its caller's original request/source/scope and explicit cause. It is not built by
parsing exception text and does not authorize or repeat a domain operation.
The registry only retains messages. UI application still checks captured
workspace/read authority, current canonical Ask/answer and original source ticket.
No raw worker mutates the UI read ticket. An obsolete cancellation cannot settle
a replacement read or reopen an ended result session.

The common token is removed by terminal publication, so duplicate cancellation
paths or later parts cannot publish another terminal or reopen it. Worker-body
publication occurs after producer cleanup unwinds. Publication itself is not
proof that the workspace-job registration has been released. Closing the result
session discards unclaimed messages but does not cancel workers or retract a
claimed batch. Existing source error/EOF/strict-frame validation is unchanged.

## Before/After and costs

Source topology: raw cancellation previously had no terminal observation to
admit; the partial-observation caller now provides one terminal value and the
same original token accepts it at most once. This fixes the source lifecycle
gap that otherwise can leave `Snapshot_read` pending after the handle disappears.
The existing pulse/demand may start a new read after the old ticket settles;
no additional poll, retry, timeout, cap or new tool permission was added.

Added costs include a preformed scoped cancellation message per observation,
a closed publication policy plus cancellation closures/branches in the common
registered launcher, and wrapping an available incomplete-read reason in the UI.
The shared list/CAS retention and normal result preparation remain unchanged.
The common launcher is also used by ordinary operations, so its added branch
and closure costs must remain in a future comparison even though those APIs
keep their existing cancellation-result policy. No performance percentage,
input latency reduction or runtime result is inferred from this source count.

A matched actual comparison must keep failed, cancelled, interrupted, unstarted
and unfinished attempts, cleanup waits, queue/source preparation, read-ticket
admission and visible-input timing. No such run was authorized or performed.

## Authored actual protocol/resource cases (unexecuted)

Two cases extend the existing private actual workspace/canonical Ask/answer,
real wake delivery and production follow-up frame/strict-decoder scenarios:

1. An actual follow-up receives its original Task while a real reaction source
   is held. Cancel the exact observation job and hold cancellation-protected
   producer cleanup. The original ticket/registration remain while cleanup is
   outstanding, then the retained cancellation settles only that original read.
   Received Task facts and operator input remain; missing reaction stays
   unconfirmed. A fresh actual read can complete, and the old cancellation cannot
   settle it. Actual Task resources are preserved.
2. Cancel the actual source switch before dispatch. Raw cancellation still
   propagates, the unstarted original observation settles without fabricating
   source identity/Task facts, and the next actual original read completes with
   unchanged Task resources.

These are protocol/resource cases, not helper-count, wording/layout, snapshot
or PTY checks. They were authored but not executed. Existing source scenarios
were adapted to the required cancellation message. No local build/typecheck/test,
CI, native/model/controller/audio/PTY run, install, restart, live writes,
self-approval or merge was performed. Only parsing and source inspection apply.

## Preservation and resume

- Same original Ask submission, follow-up request and workspace envelope.
- Same strict server frame producer/decoder and received source timestamps.
- Same current-ticket/owner admission, partial FIFO and original EOF failures.
- Same physical job registration, cancel request and actual cleanup ownership.
- Same normal operation/session cancellation policy and domain resources.
- Same original input, Task/history/proof and Goal-completion boundaries.
- Previous 50 native-stack heads/bases are preserved when publishing this leaf;
  historical lower ancestry/review issues are not repaired or cleared here.

Independent current-head source review, actual execution, installed binary,
visible TUI, useful-work outcomes and matched actual measurements remain separate.
Continue implementation across the unchanged full six-axis objective after this
bounded source unit, without substituting this ticket repair for goal completion.

## External publication changes

The first source push guard detected external updates to #44569/#44580/#44597
and refused publication before any remote write. Exact old/new tree differences
are only the three numbered changelog headings. Latest remote heads were
preserved, and the owned clone's three local refs were refreshed with backups.
Those exact heading fixes are also carried into this leaf's tree. No lower
remote ref, history or main was rewritten by this unit.

Canonical ancestry checks still find #44199 -> #44211 and #44597 -> #44605
without parent ancestry. These are source/ref ancestry gaps, not a newly verified
GitHub merge-conflict verdict. They require separate whole-stack integration
work; this publication does not claim it has been done. Original/canonical stack
snapshots, exact tree deltas, ref backups and final identities are retained in
`/tmp/masc-ask-followup-cancellation-evidence-20261021`.
