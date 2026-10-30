# File-writer cache counterfactuals

The 0.1 ms product goal is still unmet. These are standalone native component
studies, with no installed binary or product source change. Removing the writer
cache regresses the small working set; moving only descriptor validation outside
the global mutex has mixed results. Neither counterfactual is accepted as a
production optimization.

## Source, inputs and observation

The actual `lib/fs_compat/fd_cache.ml/.mli` at source head
`8659e73b8bb077ef4bcef3656b21f928b953e648` is frozen in all three versions.
The companion native executable composes JSON encoding and append/flush around
that module; it does not link the whole Fs_compat module. Compiler OCaml 5.5.1,
Yojson 3.0.0, Mtime 2.1.0, Darwin arm64. The shared host was not quiesced.
These standalone processes use the runtime defaults, without the server
`Minor_heap.tune` setup; they do not measure the configured production pools.

Two private JSON trees were selected by line-byte size from the completed
instrumented 300-owner packet. Its 25,393 daily-ledger rows have median size
570 bytes and p99 size 9,812 bytes. These are **input-size quantiles**, not
latency percentiles. Each shape repeatedly encodes one of those trees, so the
study does not replay the full event mix or its arrival pattern. Inputs and
exact digests are recorded in `input-distribution.json`; the input bytes can
contain captured prompts and stay ignored.

Each shape has four alternating AB/BA batches. Reports retain every batch and
allocation, process CPU and monotonic wall measurements. The tables are medians
of **batch wall time divided by number of writes**. With concurrent workers this
is inverse throughput, not individual write latency; no table certifies 100 us
request latency. Warm/cold distributions, confidence intervals, per-call tails
and performance under a quiet host have not been established.

The frozen bench source checks every output byte and expected row count outside the
timed section, closes owned cached channels, and removes its generated
files after validation; the retained results report the corresponding validated
counts. Historical v1/v2 receipts do not record `bench.exe` digests before/after
execution, so their executed binary bytes are not independently bound to the
recorded source/build receipts. Post-run binary hashes cannot repair that gap.
The v3 driver source compares executable SHA before/after every case using
Python `assert`; its receipt records the compiled SHA and final equality, not
a per-case digest ledger. The invocation used `python3` without an explicit
`-O`, but Python optimization flags were not snapshotted, so receipt records
alone do not prove those assertion checks ran.
Detailed per-file readback hashes remain ignored. MD5
there only identifies generated file bytes; provenance here uses SHA256.

## v1: remove the cache

The fresh-writer alternative opens/appends/flushes/closes on every write. The
baseline uses the frozen cache with its normal inode validation and 32-entry
capacity. Both include repeated JSON encoding and initial file creation. This
single-domain version excludes per-path mutex and mkdir overhead in both
variants. Final cache drain and byte verification are outside timing.

192,000 writes pass exact-byte/count verification. At 30 paths, removing the
cache costs about 4.9–5.2 times the batch wall time. Small-row gains at 300/1,500
paths and the large-row 1,500-path gain do not erase those regressions.

| Row bytes | Paths | Cached wall us/write | Fresh wall us/write | Fresh/cached CPU | Allocation change |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 570 | 30 | 7.391 | 38.754 | 4.130 | -12.819% |
| 570 | 300 | 36.054 | 33.400 | 0.953 | -13.618% |
| 570 | 1500 | 39.449 | 37.323 | 0.955 | -13.733% |
| 9812 | 30 | 33.531 | 164.808 | 3.018 | -0.909% |
| 9812 | 300 | 115.546 | 119.961 | 1.121 | -0.992% |
| 9812 | 1500 | 173.172 | 119.061 | 0.951 | -0.980% |

## v2: validate a leased descriptor outside the global mutex

`fd_cache_split.ml` is an experimental copy, not product code. It leases the
writer under the cache mutex, performs `fstat/stat` after unlocking, and retries
an invalidated entry without invoking the write callback first. Opening,
eviction and release-time close still occur under the global mutex. No claim is
made that this completes cache isolation or preserves every failure/interleaving
contract; replacement/invalidation, callback failures and close-all races need
separate functional verification before adoption.

Both variants use the same per-path mutex, with one or eight worker domains
plus an idle coordinator. In v2, JSON encoding also occurs inside that mutex;
the product encodes before acquiring it. This changes shared-path contention,
so v2 does not reproduce product lock placement. v3 corrects this below.
This differs from v1; compare variants within a
version. Domain creation/join, cache drain and readback are excluded. Controller
polling is inside the timed window. Process CPU includes GC and coordinator
work. Worker allocation deltas are sampled before any worker exits, so returned
counters from terminated domains cannot be adopted by another measured worker.

384,000 writes pass exact-byte/count verification. The 570-byte/30-path/eight-
worker shape moves from 11.417 to 3.811 us/write of normalized batch wall time,
with process CPU/write decreasing about 28%. The one-worker/300-path small-row
shape increases wall time about 21%; the eight-worker/1,500-path large-row shape
increases wall time about 17.6% and CPU about 7.7%. Allocation increases in all
shapes. Causes and repeatability of the slower shapes remain unresolved; a
single favorable shape is insufficient for adoption.

| Row bytes | Paths | Workers | Cached wall us/write | Split wall us/write | Split/cached CPU | Allocation change |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 570 | 30 | 1 | 8.096 | 8.062 | 0.968 | +0.367% |
| 570 | 30 | 8 | 11.417 | 3.811 | 0.719 | +0.367% |
| 570 | 300 | 1 | 39.358 | 47.651 | 1.003 | +0.811% |
| 570 | 300 | 8 | 38.416 | 37.479 | 0.984 | +0.722% |
| 570 | 1500 | 1 | 44.410 | 41.360 | 0.956 | +0.696% |
| 570 | 1500 | 8 | 37.182 | 36.101 | 0.973 | +0.698% |
| 9812 | 30 | 1 | 42.308 | 39.289 | 0.949 | +0.026% |
| 9812 | 30 | 8 | 16.172 | 15.793 | 1.111 | +0.026% |
| 9812 | 300 | 1 | 115.584 | 109.774 | 0.978 | +0.060% |
| 9812 | 300 | 8 | 85.136 | 69.902 | 0.850 | +0.059% |
| 9812 | 1500 | 1 | 105.689 | 106.618 | 0.991 | +0.042% |
| 9812 | 1500 | 8 | 68.033 | 80.033 | 1.077 | +0.050% |

## v3: match the product's encoding/lock order

This separate run encodes before acquiring the per-path mutex in both variants,
matching that ordering in `Fs_compat.append_jsonl`. It retains the same two
captured trees and all 12 shapes with four AB/BA batches each. It does not add
mkdir/path-registry cost, Eio scheduling, server heap tuning, or fault/replacement
interleavings, so it still does not reproduce the whole product path.

The native build succeeds and 384,000 writes report exact-byte/count agreement.
The driver source includes assertion checks of recorded source/input hashes
before launch and executable SHA256 before/after each case. The receipt stores
the compiled digest and a computed final equality; the optimization-mode
limitation above applies to assertions.
This evidence applies to v3 only, and does not upgrade v1/v2 provenance.

For 570 bytes/30 paths/eight workers, normalized batch wall time changes from
8.305 to 3.606 us/write (about 2.30 times throughput), but CPU/write rises 4.4%.
For 9,812 bytes/30 paths/eight workers, wall improves about 13.5% while CPU rises
15.4%. At 300 paths, large-row one-worker wall time rises about 14.4%; small-row
eight-worker wall rises 8.4%. All shapes allocate more. The partial prototype
remains unaccepted. Moving descriptor checks alone does not remove global
opening/eviction/close serialization at larger working sets; the extent of that
cost in the actual server still needs direct attribution.

| Row bytes | Paths | Workers | Cached wall us/write | Split wall us/write | Split/cached CPU | Allocation change |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 570 | 30 | 1 | 6.549 | 6.561 | 0.996 | +0.367% |
| 570 | 30 | 8 | 8.305 | 3.606 | 1.044 | +0.367% |
| 570 | 300 | 1 | 31.394 | 30.652 | 0.991 | +0.807% |
| 570 | 300 | 8 | 31.402 | 34.045 | 1.022 | +0.647% |
| 570 | 1500 | 1 | 34.229 | 33.656 | 0.968 | +0.669% |
| 570 | 1500 | 8 | 31.041 | 31.361 | 1.010 | +0.701% |
| 9812 | 30 | 1 | 32.580 | 32.444 | 0.983 | +0.026% |
| 9812 | 30 | 8 | 11.877 | 10.270 | 1.154 | +0.026% |
| 9812 | 300 | 1 | 94.422 | 107.993 | 1.021 | +0.049% |
| 9812 | 300 | 8 | 68.657 | 71.064 | 0.993 | +0.043% |
| 9812 | 1500 | 1 | 93.610 | 95.905 | 1.073 | +0.046% |
| 9812 | 1500 | 8 | 67.012 | 67.504 | 1.009 | +0.053% |

## Reproduction and limits

Copy a frozen version into a **new ignored working directory** and compile with
its `identity.json` argv. That historical receipt is a recipe, not proof of the
new build: record the actual command, return status, compiler/libraries and
source/input/executable digests separately for a new run. Private historical
input bytes are required to replay the recorded trees. With another owned input,
treat it as a new dataset and do not label it a quantile without measuring its
input population. For example, after compiling the v3 source in the new folder:

```sh
mkdir "$NEW_RUN/cached" "$NEW_RUN/split"
./bench.exe cached "$NEW_RUN/cached" 300 3000 "$OWNED_INPUT" 8 > "$NEW_RUN/cached.json"
./bench.exe split "$NEW_RUN/split" 300 3000 "$OWNED_INPUT" 8 > "$NEW_RUN/split.json"
```

Each destination must be new and supplied by the operator. The native executable
refuses row/byte mismatches and leaves failed outputs for inspection. Frozen
`run.py` records the original alternating driver; it is not a general provenance
recorder. Do not reuse its historical `compile_identity` as certification of a
new build/dataset. Never compile or write new output into retained evidence.

There is no fsync, SQLite, HTML/Markdown, Eio/main-domain heartbeat, actual
Keeper scheduling, peer/broadcast, Add-on-lane or native TUI latency proof here.
The global-mutex candidate is motivated by source plus a controlled component
counterfactual; it does not establish causation for the 300-owner HTTP stalls.
No local product/Dune build or whole-project CI was run for this documentation
unit. `provenance.json` is a post-run retention manifest, not an execution-time
signature of a program or a production installation.
