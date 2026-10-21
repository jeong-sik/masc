# Original Ask follow-up provenance across TUI/workspace lifetimes

Parent: `e44fc95f0f8f17f47d0325f3fceb7e5bdd619ca9` (#44633).
This is a source implementation. The full six-axis goal, matched actual
Before/After, visible TUI/input and runtime speed remain unproven/incomplete.

## Confirmed source gap and existing owners

`Log.Transport.info` uses `Log.Make`'s module logger. Its emitted console prefix
contains timestamp/level/module (and explicit optional Keeper), and this caller
supplies no TUI instance/workspace/build envelope. The original JSON has
Keeper/Ask, local source request number and submission clock. Those are scoped
to one state/process and can collide across real TUI lifetimes/workspaces.

MCP session identifies a server protocol connection and may rotate; it is not
reused as a TUI lifetime identifier or logged as provenance. The existing
`Random_id.uuid_v7` producer supplies an opaque instance ID per TUI state.
`Build_version.current` is the linked build-version owner already used by
`Runtime_build_version.current`; it can report `dev`. No duplicate version
literal, inferred client source SHA or new build metadata protocol is introduced.

## As-Is / To-Be

| Boundary | Parent source | This source |
| --- | --- | --- |
| TUI lifetime | No explicit instance in this observation | Immutable instance ID and linked reported client version created with state |
| Workspace | Confirmed identity captured separately for HTTP | Same original identity supplies immutable trace metadata and the existing HTTP expectation |
| Server admission metadata | Not in this trace | Reported version/binary commit labelled server_identity_at_admission |
| Original message | Ticket + submission repeated in each part/terminal | Private read capsule bundles original ticket/submission/origin/admission-start clock |
| Late producer/cleanup/UI | Original request ids but no immutable environment envelope | Same capsule used for start, worker, job cleanup, cancellation, part and terminal logs |
| Preparation cost | Started log clock after existing model admission | read_admission_started_ns captured before model admission/provenance preparation; observed/UI clocks remain separate |
| Repeated formatting | No environment JSON | Small immutable origin JSON prepared once per admitted read; event serialization still includes its bytes |
| Authorization | Existing workspace/read owner/ticket checks | Unchanged; provenance is observation data, not a credential or new gate |

The pure `Masc_tui_observation_origin` prepares a small immutable JSON value from
the TUI instance and original server identity observation. It retains only the
selected identity strings, without extending the lifetime of full GC/scheduler
health payloads through queued UI messages. The existing producer still uses its
original full HTTP expectation. The origin JSON includes instance ID, reported client
version, both original workspace paths and reported server version/binary commit
at admission. The protocol's private read capsule carries this value alongside
the existing ticket/submission. All result paths retain it, including failed,
cancelled and unstarted observations. UI handlers unpack the original ticket
and submission for existing admission; they log the capsule rather than current
replacement state. Physical job logs also keep the original origin after scope
withdrawal/replacement. No original question/answer body, error explanation or
MCP credential is added to provenance.

A client version is not a source commit or executable identity. The server
identity observation at admission does not prove which binary later served a
response, nor a deployment/restart. Existing HTTP/frame workspace checks remain;
no new version gate, health read, filesystem normalization or live endpoint was
added. Unknown/reported values are retained without parsing version strings into
control flow. The context must be combined with separate actual build/install
and run evidence for a matched comparison.

## Before/After and costs

Source topology only: per-state source numbers/submission clocks are now scoped
by immutable instance/workspace metadata. Different TUI instances with the same
Ask/Task names and source counters remain distinct. Same-instance health changes
produce new admission observations while earlier messages keep their earlier
identity. No elapsed time, percent speedup, useful-work rate or actual cohort
comparison is inferred from this change.

Added costs: one existing UUID-producer call/instance value per state; its mutex,
clock/formatting costs remain startup work. Each admitted read allocates a capsule,
origin and small cached JSON. A clock before the read-admission attempt includes
that preparation in later timing; even a pending-sharing poll with no new ticket
has this clock cost. Each emitted event serializes the extra origin bytes.
No source facts, numeric cap, retry, timer, permission, cache lifetime or input
policy is changed. Cached JSON belongs only to one original read and authorizes
no current/foreign-workspace action.

Matched cohorts must preserve original scopes and failed/cancelled/unstarted/
unfinished attempts. Read request/admission, actual worker entry/return, physical
job release and UI application stay separate. Monotonic clocks cannot be
subtracted across processes just because two request numbers match. All six axes
and actual failed/unfinished denominator requirements remain open.

## Authored actual protocol/resource scenarios (unexecuted)

Two cases extend the existing private actual workspace/canonical Ask/answer,
real wake/Task, server frame/strict decoder and retained result scenarios:

1. Two real workspaces and independent TUI states use the same Ask name and
   colliding source counters. Actual partial/terminal messages keep different
   instance/workspace provenance. Replacing the first scope refuses its old
   results without relabelling their origin; the second applies its own actual
   Task observations. Both actual Task resources remain unchanged.
2. A held actual read retains its original admission identity after controlled
   protocol health metadata changes. A later actual read captures the new
   reported identity while retaining the same TUI instance. Earlier origin
   stays immutable, current ticket admission still works and Task resources stay.
   The changed metadata is a fixture observation, not an installed-binary test.

Cases were authored, not executed. Existing actual cases were adapted to the
private capsule; no wording/layout, snapshot, helper-count or PTY test added.
Interfaces were changed first. Direct Dune consumers (types, protocol, executable
and actual scenario) depend explicitly on the origin library; the types library
also declares the canonical build-version owner. Source counts/identity cases
are not native/UI/build/runtime proof.

Only parsing and source inspection apply. No typecheck/build/test, CI,
native/model/controller/audio/PTY run, install/restart, live write, self-approval
or merge. Existing lower native-stack identities/ancestry/review issues are
preserved, not repaired or cleared by this leaf.

## Next observation transport boundary

The typed JSON is still serialized inside the `Log.Transport.info` message.
`Log.Make.log_module` does not forward structured `details`, so its current
ring event receives the default null details. Direct structured-details/lazy
Info emission and downstream cohort consumption remain separate implementation
work. This source does not claim that a machine cohort reader or matched actual
report has been produced.
