# Reserve original Composition intake before later discovery reads

Comparison base: `cfeb6b2ce4f4cb69e680cfc3e6cffe9ff8c531d9` (#43944).
This is a source scheduling comparison. No runtime or timing trial was executed.

## As-Is / To-Be

Composition recovery previously collected the complete `pending.ready` report
before reserving any intake fiber. Each pending name can involve original
journal, canonical terminal, nested child and dependency-result reads. An early
ready original run therefore waited for unrelated later discovery work even
though its own validation had completed. Independent intake fibers removed
later intake waits, but did not remove this earlier discovery dependency.

| Boundary | Before | Implemented behavior |
| --- | --- | --- |
| Private directory names | Full original listing first | Same listing and ownership checks |
| Ready candidate validation | Original marker/journal/terminal/dependency proof | Same validation before publication |
| Candidate publication | All names inspected before controller received the list | Each ready candidate reaches the controller before the next name |
| Worker reservation | After the full report | From each validated, eligible original candidate |
| Callback error/cancellation | Controller reservation outside discovery conversion | New callback also runs outside filesystem conversion and marker transactions |
| Current admission | Exact source/owner/generation/node/child/current surface | Same canonical intake; discovery grants no execution authority |
| Declaration projection | One lazy immutable snapshot per pulse, first demand | Same sharing/lifetime; first demand can occur during discovery |
| Per-name failure / retirement | Retained failures and exact terminal-bound snapshot purge | Same failure and guarded retirement paths |
| Report-only / replacement-test discovery | Complete ordered report without dispatch | Same interfaces and behavior through an ignored ready callback |

The journal producer returns from all original per-candidate reads before
calling `on_ready` in the caller's context. It neither dispatches under a native
lock nor converts scheduling exceptions into journal I/O errors. Directory and
per-name filesystem failures keep their existing conversion. Cancellation is
re-raised. A later failure does not prove that no earlier reservation happened;
already-created workers remain subject to their original lifetime switch.

The controller retains its non-yielding active reservation, switch check before
discovery and each reservation, fork refusal cleanup and per-run `finally`.
Explicit recovery holds suppress reservation; original-evidence/publication
holds still run their original revalidation probes. A reserved probe can remain
held without reaching intake. Metadata, Skill publication, original activation,
Task and node/child snapshots remain separately validated. A stale candidate
cannot bind an already-replaced or completed owner. Serial/resource/Gate/effect
and completed-sibling reuse paths are untouched.

Ready callback publication is an observation of canonical readiness at that
point, not a durable dispatch ACK or successful Tool/Task action. The returned
report preserves original observation order; callbacks or other workers may
already have made a reported candidate stale. The controller's existing result
observer may run before discovery completes, but still reports only its original
intake result. Notification coalescing and fresh follow-up pulses are unchanged.

One pulse still owns one `Eio.Lazy` declaration projection. It is created before
discovery without reading files and forced only by an intake needing original
revalidation. Active-only or unreleased-held scopes do not force it. First
demand may capture declarations earlier within this pulse; later edits belong
to the next pulse under the same existing sharing contract. This projection is
neither a cached candidate/result nor execution authority. Current per-intake
metadata and published-Skill checks remain independent.

## Quantitative Before / After

Let `N` be the initial listed names and `K` the position of the first validated
candidate eligible for a controller reservation. The old first reservation
depended on all `N` name inspections; the new one depends on the first `K`.
The later `N-K` inspections can overlap that reservation's validation/intake
work. These units include retained lock siblings and waiting/retired/refused
names; they are not the report's `inspected` count, filesystem syscall counts,
actual intakes, jobs or effects. Each name may require many canonical reads.

Directory enumeration and every original validation rule remain. `K=N` removes
no later-name dependency; no eligible candidate creates no reservation. No
reduction in total read work, provider/Tool calls or actual effects is established;
the initial name cohort and effect authority remain. Callback/closure work and
earlier worker/projection lifetimes have
unmeasured cost. Readiness can change while callbacks run, so full reports are
observations rather than an atomic all-run snapshot.

No latency percentile, speedup, memory, input/paint or useful-work result is
asserted. Any matched trial must retain discovery failures, cancelled/interrupted
scans, held probes and unfinished workers. Measure reservation, revalidation,
canonical intake acceptance, actual effects/result delivery and original Task
progress separately. Permanent invalid-result resolution remains the existing
explicit follow-up; missing authority is never expiry, retirement or relaunch.

## Evidence and remaining scope

Existing real scenarios cover original job-result/child waits, completed sibling
reuse, original Task preservation, canonical owner loss/replacement and refusal,
cancelled recovery scopes, held original evidence repair, shared declaration
success/failure and changed projections, guarded marker replacement/retirement
and independent blocked backends. Their production pulse consumer now enters
through incremental discovery; report-only and replacement hooks stay intact.
They were read, not executed. No helper-mirror, invocation-count, wording/layout/
row-order, snapshot or PTY test is added. Early publication and overlapping late
discovery failures still need independent review and actual behavior evidence.

Changed OCaml interfaces/implementations are checked with parsing only, plus
whitespace and the unchanged changelog checker. No build/typecheck/test, CI
dispatch/watch, native/model/PTY/controller/report run, install/restart, live
config/prompt write or own merge is performed. The full original Ask/Task,
preparation, nested/dynamic/effectful Composition, held/shared-backend, cold-start
TUI and matched failed/unfinished cohort objective (#42799) remains active.
