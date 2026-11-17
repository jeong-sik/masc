# Librarian range work on the CPU pool

Five Consumer call sites computed atom selection, recovery selection, unread
counts or cut lines directly after loading their checkpoint. Those pure calls
can serialize message JSON, scan UTF-8 and hash opener bytes. They now submit
the same computation and captured immutable arguments to the existing shared
CPU pool. Calls already on a worker, without a pool or outside Eio retain the
shared adapter's inline policy.

The functional Range implementation is unchanged. Every previously demanded
opener is still encoded and hashed in the same order. There is no cursor-based
prefilter, skipped invalid old cut, eager hash, digest memo or global cache.
Media references are encoded as metadata; this path does not fetch their bytes.
The separate source-validation selector already inside the locked I/O job is
unchanged. None of the five new CPU closures reads current storage, commits
Memory, acknowledges external input or writes a cursor.

Moving a calculation introduces a scheduling suspension. It does not make the
captured source fresher or authorize a later commit. Existing source, Memory
revision and cursor checks retain their original ownership and order.

## Evidence scope

The product unit is `30b63a25131f910d07d884b425a69c8ad782faef`, based on actual
main `b970e1e2df1436cd6b524202782cfee9e9654a3d` including the separately owned
capacity-wait removal. The independent source review inspected the two-file
delta and relevant codec, worker, cancellation and single-writer contracts.
It found no P0/P1/P2 within that scope. Its source conclusions about cancellation
are not an executed cancellation scenario or formal GitHub account approval.

The first whole-interface native compile stopped because an actual dependency
CMI was missing. That failure is retained. When the real dependency appeared,
the same complete Consumer MLI and ML bytes compiled with the same dependency
prefix and fatal warnings 4, 8, 32 and 69. The changed dependency's observed hash
is recorded. No signature stub, warning suppression or local Dune build was used.
The broad shared prebuilt dependency graph is not attested as a complete build
of the source head.

Four unchanged maintained Consumer test declarations then ran in three contexts:

| Context | Cases passed |
| --- | ---: |
| No pool | 4 |
| Caller with one worker | 4 |
| Already running on that one worker | 4 |

The cases cover delivering intermediate turns, counting unread turns before and
after a pass, preserving a refused range across retry, and a quiet pass not
requiring the checkpoint again. All twelve passed. The common fixture prelude
binds the freshly compiled Consumer and actual TestDeps; its callback is wrapped
in an owned one-worker helper for the two pool modes. Product logic and the test
declarations are not substituted. The complete actual TestDeps implementation
includes the separately reviewed explicit Unix.file_kind cleanup match. Its
unchanged real C stub was compiled and linked. Source derivations and hashes are
in `selected-consumer-r1/source-map.json`.

`validation.json` is a curated derivative retaining command labels, terminal
results, elapsed times and raw-record hashes. Host-specific compiler argument
lists are omitted. Retained source maps and logs keep their own original hashes.
These are selected native scenarios, not the full Consumer suite, cancellation,
concurrent replacement, purge, installation or fleet verification.

An earlier operator-owned one-second availability sample was the lead for this
audit. It showed range/digest work on the main thread; it did not establish CPU
share, a performance baseline or exclusive causality. This unit collected no new
live sample, runtime request, provider call, restart or GC. Total CPU, RSS,
throughput and live response recovery remain unmeasured. Moving work off the
caller does not itself reduce the amount of serialization or hashing performed.
