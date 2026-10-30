# Recovery child entry and original-result continuity

| Boundary | As-Is | To-Be |
| --- | --- | --- |
| Validated owned-job marker callback | Fork can immediately enter canonical recovery/backend work | Child yields before recovery, inside its original reservation cleanup |
| Validated prepared-continuation callback | Fork can immediately probe held evidence or acquire declarations | Child yields before those reads and original intake, inside its original cleanup |
| Discovery caller | Complete scan remains synchronous | Same scan; caller gets a scheduling opportunity at each newly admitted child |
| Cancellation at child entry | Original cleanup surrounds recovery | Same cleanup also surrounds the new cancellation point |
| Shared evidence | Presence round and lazy declarations belong to their original pulse | Same ownership, original validation and fresh later rounds |

The installed Eio POSIX scheduler (`eio_posix/sched.ml`, Fork handler) puts the
parent at the queue head and runs the new child. The mock backend documents and
implements the same order. `eio/core/fiber.ml` implements `yield` by suspending
and checking cancellation when resumed. Forking alone therefore does not defer
the child's synchronous prefix until after the discovery callback returns.
This source finding establishes scheduling behavior of those implementations,
not a measured maintenance stall or a guarantee for every Eio backend.

Each controller now yields once at entry to each newly admitted child. Both
yields are inside the existing `Fun.protect`, before canonical recovery,
held-evidence probes or lazy profile acquisition. Cancellation remains structural
and the original active reservation is released. The outer fork-failure cleanup
and the pre-discovery/pre-reservation switch checks remain. Prepared intake
continues to release its active reservation before its result observer; this
reservation does not cover downstream DAG worker exit or observer completion.

Discovery itself still completes in the caller. Its later filesystem I/O may
yield to a previously admitted child before the scan finishes. This change does
not guarantee all reservations precede any child work, make scans asynchronous,
or remove backend locks, I/O, revalidation or protected cleanup waits. There is
no pool, timer, cache, new limit, runtime knob or alternate recovery authority.

Owned-job discovery still delivers validated markers in their original order,
retains earlier workers on late discovery failure and prunes held hints only
after a successful complete scan. The original per-pulse shared backend presence
round remains read-only; private owner/CLI checks still govern each job. A hint
removed during admission can be lost if entry is cancelled, requiring full
inspection in a later round. This affects process-local reuse cost; it does not
discard the durable owner, completed output or notification obligation.

Prepared continuations retain their original candidate/request identity,
explicit recovery holds, exact evidence probes and canonical intake. Eligible
children still share the original pulse's lazy immutable declaration projection;
cancelled acquisition can restart for a remaining caller. A later pulse captures
fresh declarations. Original Task/Skill/publication/root/owner validation,
durable CAS, actual result delivery/ACK and cleanup remain in their existing core.

Before/After source quantity is two added yield sites, with one suspension and
cancellation check per newly admitted child at the corresponding site. Active
or explicitly held candidates do not acquire another child entry. Added
scheduling latency and any lost held-hint reuse belong in the cost denominator.
No milliseconds, throughput or speedup are inferred from these source counts.

A new unexecuted protocol/resource scenario starts a real accepted fixture job,
collects its actual complete output, holds the real Keeper intake mutex, admits
recovery and cancels/joins that selected scope. It checks that no completion
commits through the held intake, the original terminal result/source/channel and
output bytes remain, a fresh scope using the same supervisor delivers exactly
one original notification, and a later round cleans and retires its marker
without losing output or duplicating that notification. The CLI peer is
synthetic; the scenario is not real Docker isolation proof. It does not claim
which exact physical read the cancelled worker reached. Existing blocked-backend,
shared presence, held reactivation, declaration sharing and nested continuation
scenarios remain unexecuted. No count-only or TUI wording/layout/PTY test is added.

Verification is parsing only for the two implementation/interface pairs and the
changed scenario file, whitespace checking and comparison of the original worker
bodies after removing only the added comment/yield blocks. No typing, warnings,
linking, local build, test execution, CI, controller/model/native/TUI run, live
installation/restart, independent approval or merge is established. Runtime
latency, physical worker cleanup and visible input/paint remain unverified.

All six original axes remain open: original Ask/Task useful work, exact
preparation/frozen discovery, ordinary/nested/dynamic/effectful Composition
continuity, held-job/shared-backend reactivation, cold usable input/TUI
readability/visibility, and matched actual cohorts retaining failed/cancelled/
interrupted/not-started/unfinished attempts. This unit changes a scheduling
boundary; it is not whole-goal completion.
