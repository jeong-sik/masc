# Original Task history continuation protocol

Relates #42799 and follows #44013. The original Task reader currently asks the
legacy history endpoint for 50 events. That array has no continuation metadata;
larger original histories cannot be read through that TUI path. This unit adds
the actual source-bound event producer and both HTTP transports. **TUI Work and
Tools still use the legacy slice until the consumer change.** This is not a
claim that the visible history gap is already closed.

## As-Is / To-Be

| Boundary | Before | Source behavior in this unit |
| --- | --- | --- |
| Response | The legacy endpoint returns only a recent bounded array, without an older boundary. | `/api/v1/dashboard/tasks/history/page` requires exact Task ID and positive per-response limit, and returns Task, request-cursor echo, event rows and an optional next cursor. No total history limit is added. |
| Storage read | The legacy matching scan loads whole day files and lexically orders filenames. | The new producer traverses validated date/rotation layout using shared numeric segment ordering, reads backwards in reusable transfer blocks, and reconstructs records across any number of blocks. Block size is not a record or history limit. |
| Continuation | Increasing the fixed count still leaves an invisible end. | A canonical opaque cursor binds original Task, physical workspace, dated prefix membership, original file identity and exact row offset/hash. Subsequent reads exclude later appends and do not rescan already transferred file contents. |
| Failure | Legacy malformed rows can be skipped. | The new reader refuses invalid JSON/non-object rows, conflicting original Task identities, changed anchors, replacement/removal or unavailable storage. Errors return no advanced cursor; they are not empty completion. |
| HTTP | HTTP/1 uses a legacy cached slice while H2 calls the array producer. | Both new routes call the same typed producer inside their existing public workspace-bound read and shared I/O path, without caching cursor pages. |

The old endpoint remains an existing array resource used by dashboard/tool and
TUI consumers. The new resource is a contiguous physical event-prefix protocol,
not an adapter that fabricates cursors for old arrays. The next consumer unit
must use it directly and keep incomplete, exhausted, earlier and failed reads
distinct. No compatibility fallback should turn a failed page into the old slice.

## Actual ownership and storage boundaries

The request holds an owned inventory root. Directory names come through owned
no-follow enumeration, and files are read through the existing owned regular
range reader. Non-hidden invalid month, calendar day or rotation entries
refuse the page with a typed invalid-layout error and relative entry. The shared
layout authority alone classifies foreign dotfiles; corrupt membership is never
silently removed from the observed inventory. The existing dated-layout module is exposed as the sole calendar
and segment-order authority; no second filename grammar is introduced.

The cursor records a dated ceiling and an inventory fingerprint. Files above
that ceiling are outside this observed prefix. Membership/physical identities
and closed-file metadata below it must still match. The ceiling file permits
append, while its continuation verifies device/inode, newline boundary and the
original raw row hash. Removal/replacement, a changed anchor or changing closed
file refuses the whole page before publication. Every actual byte-range read
also retains the owned reader's before/after descriptor validation. Workspace
identity includes canonical root spelling and physical device/inode; raw host
roots are not serialized into a cursor or public failure.

This is an observed prefix, not an atomic snapshot of the whole event store.
Existing retention can remove history and make a cursor stale. In-place mutation
outside the validated anchor of the active append file is not a full-file
content proof. The event writer's append behavior is retained, and the reader
does not claim cryptographic conservation of every unread byte. Empty pages can
still have a next cursor because remaining storage may contain other Tasks;
only a null next cursor means that this observed stored prefix was exhausted.

One requested limit controls matching Task records in a response. It is neither
a runtime scheduling cap nor a timeout, and no total event/record-size cap,
snapshot file, new setting, cache, timer, retry policy or runtime write is added.
Enumeration is metadata work over the available dated files. Finding a rare
Task can still scan unrelated records; source paging is not proof of a measured
latency improvement.

## Authored scenarios and evidence limits

The existing real first-loss Composition/resource scenario now continues from
the original durable request/run/Task into this actual event producer. It reads
an original prefix over multiple pages, preserves older original events,
excludes a later same-Task append, refuses a different Task borrowing its cursor,
roundtrips the canonical producer cursor, reads the shared HTTP/H2 response and
refuses a replacement event store instead of reporting an exhausted history.
The scenario also refuses invalid month, calendar day and rotation entries
beside valid history and in an otherwise empty replacement store, while allowing
foreign dotfiles under the shared layout rules. The HTTP producer returns the
typed failure rather than a successful exhausted prefix.
These are resource/protocol assertions inside the original scenario, with no
layout, wording, row-order, snapshot, PTY, helper-mirror or call-count assertions.
The scenarios are authored and **unexecuted**.

The same scenario's earlier server-producer references now name the actual
unwrapped `masc.server` modules rather than nonexistent `Masc.Server_*` aliases.
The existing test dependency already re-exports that server library. This is a
source namespace correction, not evidence that the scenario typechecks or ran.

Validation is parsing and whitespace inspection only. No local build,
typecheck/test, CI dispatch/watch, model/native/PTY/controller/coordinator/report
run, install, restart, live prompt/configuration write or own merge is performed.
The legacy TUI reader still has its 50-event boundary. Visible history
continuation, input/paint, runtime usefulness, complete retained telemetry and
matched actual Before/After remain unverified and unfinished. Future actual
cohorts must include enumeration, scanning, preparation and diagnostic costs,
including failed, cancelled, interrupted and unfinished attempts.

All six original axes remain active: Ask to original Task/useful work, exact
preparation attribution/frozen discovery reuse, ordinary/nested/dynamic/effectful
Composition, held/shared-backend continuity, cold-start/TUI visibility and
matched actual cohorts. Publishing this source protocol completes none of those
whole feature/evidence requirements by itself.
