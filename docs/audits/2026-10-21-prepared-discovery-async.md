# Prepared-continuation discovery shared by maintenance and result demand

| Boundary | As-Is | To-Be |
| --- | --- | --- |
| Maintenance | Completes discovery before returning to later recovery work | Records demand and returns without joining discovery |
| Result-ready notification | Own discovery drain, independent of direct maintenance discovery | Same drain as maintenance; no parallel scan paths in one controller |
| Demand before a read | Notifications share their first read | Both trigger kinds share the next read |
| Demand during read or observation | Notifications request a fresh pass; direct maintenance scans independently | Both trigger kinds request a fresh pass after the current observation |
| Actual result | Maintenance return; notification error log | Each actual typed result and original base path reach `on_discovery` |
| Declaration projection | One lazy immutable projection per pass | Same ownership, fresh for each subsequent pass |

`pulse` and `notify_result_ready` now call the same request handler. The first
admission reserves a drain on the supplied lifetime switch; the child yields
before discovery. The controller keeps this reservation through observation and
pure cancellation cleanup. Demand arriving before the next pass starts shares
that pass. Each pass consumes only prior demand, so demand arriving during its
I/O or observation remains due after an ordinary observer failure. There is no
timer, limit, pool, new switch, cached discovery or automatic retry without new
demand. A failed scheduling attempt releases its reservation; cancellation stays
structural and does not become a journal error or successful return.

The original discovery/intake-reservation body is renamed only. Directory
listing and canonical marker/journal/terminal/dependency checks still produce
validated original candidates in their original order. Their reservations,
entry yields, held-evidence probes, explicit-recovery holds, exact request/Task/
Skill/publication/root authority and canonical CAS are unchanged. Each pass
creates its own original lazy declaration projection, shared on first actual
intake demand and restartable after cancelled acquisition. A new pass never
borrows that projection. Prepared intake still releases active before its result
observer; that does not prove the downstream DAG worker has physically exited.

`pulse` and its controlled-intake testing entrypoint now return `unit` for
scheduling only. Each actual `(unit, Journal.error) result` reaches
`on_discovery` with the original base path. Partial marker failures keep their
original diagnostics alongside a successful whole-pass return. Unexpected
exceptions are recorded as raised without fabricating a typed result. Returned
pass/error counts now exclude raised passes; separate raised observations retain
that evidence. Drained means no demand remains in this burst, not that reads,
intakes, jobs or the logical DAG succeeded. Ordinary observer failure is logged;
it neither consumes subsequent demand nor cancels admitted original intakes.

Observations distinguish reservation, actual pass start/return, interruption,
raised work and drain boundary, with monotonic timestamps and maintenance/result
demand counts. Counters do not control retries or execution. Reservation release
is pure; best-effort summary logging follows cleanup and does not establish
physical worker exit. Original discovery I/O, canonical revalidation, serialized
resource waits and protected physical cleanup remain. A slow observer delays
the next scan in this controller while the maintenance caller remains free.

Before/After source quantity is two independently entering discovery paths
changed to one common drain, not a measured concurrency or speedup statistic.
Additional maintenance work includes child admission, entry suspension and
observations. Demand arriving during a pass can require a fresh scan with fresh
declaration capture. Removing duplicate scan paths does not remove original
authority checks or make the whole scan precede intake work. Continuous new
demand can keep the drain active; no numerical cap is introduced.

A new unexecuted protocol/resource scenario parks a real named child and its
prepared parent on the original accepted job. After collecting complete output,
it faults the actual pending directory, schedules maintenance and a result hint,
and commits independent durable queue work before joining discovery observation.
It preserves the actual typed error and original marker bytes. While that error
observer remains blocked, it restores the directory beside a malformed marker
and submits both demand kinds; the observer then fails ordinarily. Fresh
discovery must admit the original child, publish its real terminal result, and
use further result demand to resume the original parent. The scenario reads
usable original stdout, checks original request/Task identities and parent
consumption, and retains independent work and partial damage. This exercises
demand during observation; it does not prove a particular physical read point
was blocked. The CLI peer is synthetic, not real Docker isolation proof.

Existing direct/controlled pulse consumers are migrated to scheduling-only
returns. Selected switch rounds still join their actual children, while ordinary
continuation scenarios await actual intake or canonical result observations.
The original held-reactivation, shared-declaration, dynamic/nested/effectful DAG
and cancellation scenarios remain unexecuted. No helper/count-only or TUI
wording/layout/snapshot/PTY test is added.

The OCaml Skill description now states its repository/file trigger and main
boundaries concisely; detailed rules stay in the body. Description size is a
metadata comparison only, not a token count or measured preparation speedup.

Verification is parsing only for the implementation/interface, server consumer
and changed scenario file, whitespace checking and original-body/core-preservation
comparison. Existing direct Eio and monotonic-clock library dependencies remain.
No typing/warnings/link/build/test execution, CI, controller/native/model/TUI run,
live installation/restart, independent approval or merge is established. Actual
preparation latency, useful work and visible loading/input remain unverified.

All six original axes remain open: original Ask/Task useful work, exact
preparation/frozen discovery, ordinary/nested/dynamic/effectful Composition
continuity, held-job/shared-backend reactivation, cold usable input/TUI
readability/visibility, and matched actual cohorts retaining failed/cancelled/
interrupted/not-started/unfinished attempts. This source scheduling change does
not establish whole-goal completion.
