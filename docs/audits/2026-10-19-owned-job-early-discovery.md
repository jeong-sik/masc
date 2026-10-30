# Start original-job recovery before later marker reads

Comparison base: `730f0bd43afc96dd14e31b50e2ab48c51a944ebf` (#43936).
This is a source comparison. No runtime, UI or timing trial was executed.

## As-Is / To-Be

Owned-job maintenance already used independent lifecycle fibers and shared a
non-authoritative presence inventory for equivalent frozen backend routes.
However, `pulse` first waited for `Store.pending_deliveries` to read and validate
every marker body. Only the complete report then reached worker reservation.
A ready early job therefore still depended on unrelated later discovery reads.

| Boundary | Before | Implemented behavior |
| --- | --- | --- |
| Private directory listing | Complete original name list first | Same listing and ownership refusal |
| Validated pending marker | Retained until all marker bodies were read | Published to the caller before the next body read |
| Maintenance recovery | Reserve workers after the full report | Reserve each eligible original job from its validated hint |
| Effect authority | Exact recovered owner journal | Same phase/source/channel/result/CAS authority |
| Explicit marker refusal | Retained in the discovery report | Same refusal and report order; no callback for rejected rows |
| Unexpected filesystem exception | Whole discovery error | Same error; earlier reservations can already exist |
| Callback exception/cancellation | Reservation occurs outside store read | Still propagates outside filesystem exception conversion |
| Missing held hints | Prune after successful discovery, before reservations | Prune after successful discovery; keep hints on an incomplete scan |
| Shared presence round | One lazy inventory per equivalent route in a pulse | Same pulse-local round across early and later validated jobs |
| Report-only pending read / explicit reconciliation | Full selected discovery and round report | Same full-scope public contracts |

`discover_pending_deliveries` runs callbacks in its caller's context. Native
directory/marker work retains the existing filesystem wrappers; scheduling is
not moved into a system thread. Filesystem exception conversion covers the
directory acquisition and each read, never the callback. An explicit read
refusal remains a per-marker failure, while an unexpected filesystem exception
still ends discovery. Cancellation is not converted into a store error.

The controller checks its lifetime switch before discovery and again immediately
before each non-yielding active reservation. The original fork/finally cleanup
removes only that job's reservation. Already-active owners remain suppressed.
No callback can launch from a marker alone: recovery rereads the canonical owner,
and original phase intents, output readiness, durable notification, delivery ACK
and cleanup retain their existing order. Late scan errors do not undo an already
durable result/notification or prove that no worker started. Durable markers and
a later maintenance pulse remain the recovery source after cancellation.

Full successful discovery supplies held-hint pruning. An incomplete scan does
not erase hints for unvisited jobs. Every reused held hint still requires exact
equality with its freshly recovered original owner. A hint is neither a phase
transition nor execution/relaunch authority. Positive presence still requires
full reconciliation, and changed owners bypass held reuse.

## Quantitative Before / After

For `N` listed markers and the first eligible validated marker at original
position `K`, reservation previously depended on all `N` marker-body reads.
It now depends on the first `K`. The remaining `N-K` reads can overlap the
already-reserved lifecycle. Directory enumeration, earlier rejected markers and
each original validation remain. There is no saving at this boundary when
`K=N`; no eligible marker means no worker reservation in either version.

This is a removed source dependency, not an executed call count, time bound or
speedup. Total scan work, selected jobs, backend effects, provider calls and Task
transitions are not reduced. The report still retains all selected entries and
failures. Callback/recursive traversal and earlier fiber/round lifetimes have
unmeasured cost. A shared presence inventory can be captured earlier within the
same pulse; a later job still sees only a non-authoritative hint. An absent hint
can defer positive reactivation to a fresh pulse, never authorize an effect.

Any later matched trial must retain discovery failures, cancelled/interrupted
scans, unfinished workers and held jobs. Measure first reservation, actual
backend/result/delivery settlement and original Task progress separately.
No TUI Loading, usable input, visible paint, end-to-end latency, memory or
throughput improvement is established here.

## Evidence and remaining scope

The existing real owned-job scenarios cover a blocked backend with independent
new job recovery, original result/queue/ACK ordering and observer failure,
cancelled recovery scopes, refused/corrupt owners, absent-owner reactivation,
changed cancellation and shared versus different backend routes. Their direct
production pulse consumer now uses incremental discovery. They were read, not
executed. No helper-mirror, invocation-count, wording/layout/row-order, snapshot
or PTY test is added. Early marker publication and late scan failure still need
independent source review and eventual behavior evidence.

Changed OCaml interfaces/implementations are checked with parsing only. No
build, typecheck, test, CI dispatch/watch, native/model/PTY/controller/report run,
install/restart, live config/prompt write or own merge is performed. Original
Ask/Task/useful work, preparation attribution, nested/dynamic/effectful
Composition, held/shared-backend continuity, cold-start TUI visibility and
matched Before/After remain the full active objective (#42799).
