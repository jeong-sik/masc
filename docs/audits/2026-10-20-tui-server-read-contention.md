# TUI loading delay: repeated continuity source preparation

## Observation

Observed on 2026-10-20, 10:26:00–10:30:15 UTC (19:26–19:30 KST).
The running server identified its embedded commit as
`73bcae67d657a9ae73b8bb7b90ef77c787a24901`. These observations precede
the change and do not describe the PR candidate running in production.

- TUI transport logs recorded 10-second timeouts for Keeper roster and turn
  reads. One logical full refresh lasted 16.921 seconds with partial failures.
- Server logs recorded 25–30-second compute timeouts across mission,
  briefing, goals, chat history and tools. Shell refreshes took 65.986 and
  65.596 seconds. Readiness still answered HTTP 200 with `ready:true`.
- A three-second macOS `sample` at 19:30:22 KST observed a 34.1 GiB physical
  footprint. The main thread spent 1,137 of 1,553 samples in `poll`.
  Several workers visited `Librarian_continuity_snapshot.feed` (JSON encoding
  and prefix hashing); another spent 1,552 samples in memory-search SQLite
  execution. These are per-thread sample counts, not request durations or
  percentages of all process CPU time.

Raw evidence remains in the operator's runtime logs and local sample capture,
outside the source tree. The sample file SHA-256 is
`b6c9713a15851254b4a699b3f2e2d3987fa20bc3dd4b12cd4d72c20bf1b8a42d`.
No conversation bodies or checkpoint payloads are copied into this report.

## Confirmed duplicate work and change

The continuity queue first prepared a source, then called `prepare_source`
again when a previously learned width was smaller than that source. The second
call reloaded the exact checkpoint and repeated previous-continuation prefix
validation solely to choose a smaller endpoint.

The queue now selects that endpoint from the original immutable prepared
source. Its validated full cut list is retained with the checkpoint and used
by attribution, counterpart-window selection and ordinary Memory coverage
checks. A recovery receipt keeps its exact interval, even when it exceeds the
learned width. A normal prefix uses the first cut covering its new endpoint.
The existing halving operation keeps its original covering anchor.

Publication still rereads the locked checkpoint and boundary prefix and checks
the continuation snapshot CAS. Reusing a prepared source does not authorize
publication after the original source changes. No global cache, polling cadence,
timeout or pool-weight policy is changed.

## Validation and limits

`git diff --check` and OCaml 5.5.1 parsing of the changed interface,
implementations and test source passed. Added behavior coverage compares a
frozen prefix with explicit preparation, checks its attribution/window/receipt,
and verifies that changed source refuses publication. Existing recovery coverage
also checks that prefix selection cannot split an exact receipt.

The behavior tests have not been executed. No local Dune build or CI wait loop
was run, following `constitution.xml`'s external coding-agent protocol.
The direct change is removal of a second preparation on the learned-width
branch and repeated validation of frozen cuts. Its effect on HTTP latency,
memory pressure and the visible TUI remains unmeasured. Memory-search cost and
other checkpoint encoding/hashing paths remain separate follow-up work.
