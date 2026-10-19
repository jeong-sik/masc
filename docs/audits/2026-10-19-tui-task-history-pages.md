# TUI original Task history continuation

Follows #44022. This consumer connects actual Work Task detail and Tools original
Task detail directly to the source-bound page resource. The server protocol's
storage, retention and physical prefix limits still apply. No live installation
or visible behavior is established by this source unit.

## As-Is / To-Be

| Boundary | Before this consumer | Source behavior after this consumer |
| --- | --- | --- |
| History access | Both TUI readers used the legacy `limit=50` array with no older boundary. | Both use `/api/v1/dashboard/tasks/history/page`; per-response event demand comes from terminal height, with the protocol minimum of one. `H` requests the known earlier cursor. There is no total history cap. |
| Identity | Body and history were keyed by original Task, but the array carried no cursor echo. | Strict page schema, exact Task, request-cursor echo, response demand and noncyclic cursor are validated on the shared CPU path before joining the captured immutable prefix. |
| Refresh | Tools cadence could read a fresh slice after every completed read. | Cadence shares initial pending work and leaves settled prefixes and older-page failures intact. Explicit `r`, opening an original Task and authority revalidation request a fresh latest prefix. Earlier observations remain visible during that read. |
| Failure | A recent array could look like the whole history. | Earlier-page failure keeps the prefix and its retry cursor. `H` retries that boundary; no failed page falls back to a legacy slice. Missing next cursor means only observed stored-prefix exhaustion. |
| Ownership | Work history used an anonymous workspace job and a bare fetched ticket. | Both consumers carry original read epoch, exact fetched ticket, immutable page request and distinct physical job key. Retired replies cannot finish a successor. Work exit and Tools close cancel their own jobs; common executor cleanup retains registry ownership. |
| Preparation | The independent history document prepared the fetched event list. | It prepares the typed prefix's immutable event list using the existing independent CPU preparation and source/width guard. Extending history does not reload the original Task body. |

Empty pages may still expose an earlier boundary. Exhaustion does not assert
that retained-away history never existed, nor that the Task succeeded. A changed
or unavailable source remains a failed observation. An explicit refresh can
read a new prefix but does not repair or silently continue an invalid old cursor.

The old array endpoint remains used by other existing consumers; this TUI path
has no compatibility fallback. Page decoding and prefix concatenation run in the
CPU worker. Prefix concatenation and full display preparation still incur work
as history grows; no measured speedup or constant-cost claim is made.

## Authored resource scenarios

The existing first-loss Composition/resource scenario continues through the
actual Task history producer, typed TUI requests and completion handlers. It
retains an original observed prefix on an older-page failure, explicitly retries
the captured boundary, rejects a late predecessor result, reads original earlier
transition evidence and retains independence from pending body reads. Existing
workspace-admission and same-identity replacement scenarios now use the actual
page contract and owned requests. No layout, wording, row-order, snapshot, PTY,
helper-mirror or invocation-count tests are added. All scenarios are authored
and **unexecuted**.

Only OCaml parsing and whitespace/source inspection are performed. No local
Dune build, typecheck, test, CI dispatch/watch, native/model/PTY/controller/
coordinator/report run, install/restart, runtime prompt/config write or own
merge is performed. Parsing is not type correctness or runtime evidence.

## Actual Before/After remains open

This closes the source connection from the TUI readers to the server's older
boundary. It does not complete the six-axis goal: original Ask to original Task
and useful work; preparation attribution/frozen discovery reuse; ordinary,
nested, dynamic and effectful Composition continuity; held/shared-backend
continuity; cold-start/readability/visibility; and matched actual cohorts.

Future actual observations must keep the same build/source/workspace and source
demand, and include enumeration, scanning, decode, prefix assembly, independent
display preparation and diagnostic costs. Failed, cancelled, interrupted and
unfinished attempts stay in the denominator. Worker/result/UI-application facts
remain distinct from input response, first paint and useful Task progress.
