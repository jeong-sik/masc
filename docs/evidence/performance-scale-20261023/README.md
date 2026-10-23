# Scale investigation, 2026-10-23

Tracking: #45544. The goal remains 0.1 ms across server, TUI and file reads,
with sustained continuity at 350 agents. No completed scale claim is made here.

## TUI tool identity lookup

Base: `68ec8fb2c52545c68600928524dcc12945e55ee7`.
`project_trail` searched the full call list for each `Node_tool`. The change
indexes the current records once per projection. IDs are allocated monotonically
within a transcript and remain stable through late results and retry boundaries.
The trail, not table iteration, still determines order.

`trail_lookup.ml` contains the exact before/after lookup expressions extracted
from the source, with minimal record types and synthetic integer IDs. It checks
lookup equality, unknown IDs and a late result, then measures nine alternating
before/after rounds. Index construction and result allocation are included.

Reproduce without building MASC:

```sh
ocaml -noinit -I +unix unix.cma docs/evidence/performance-scale-20261023/trail_lookup.ml
```

OCaml 5.5.1 interpreter on macOS arm64, milliseconds (median):

| Calls | Before | After | Before allocated bytes | After allocated bytes |
|---:|---:|---:|---:|---:|
| 35 | 0.010967 | 0.008821 | 2,760 | 3,352 |
| 350 | 0.864983 | 0.056982 | 25,440 | 29,616 |
| 3,500 | 86.205959 | 0.546932 | 252,240 | 285,088 |
| 10,000 | 770.675182 | 1.529932 | 720,240 | 851,392 |

These are **interpreter lookup measurements**, not complete projection, native
render, terminal paint or installed TUI measurements. Call count is not agent
count. Raw rounds are in `trail_lookup.csv`; wall-clock microbench timings are
observations, not a gate. The new transient table uses O(N) extra memory.

Validation: source parsing (`ocamlc -stop-after parsing`), `git diff --check`,
and independent adversarial source review found no P0/P1/P2 issue in the lookup
change. No local Dune build or native TUI measurement was run in this initial
experiment. The later native CI receipt below records the existing transcript
suite, including late results and superseded attempts.

## Initial live server baseline

The installed server reported the base commit above, effective root
`<base-path>/.masc`, runtime instance
`01a16824-3a62-7000-bc5e-f64722d87325`. At uptime 34 seconds its measured RSS
was 21,223,227,392 bytes and scheduler p99 was 1,075.35 ms. This was startup,
not a steady-state performance result.

The existing `response_latency_probe.py` then sampled 10 anonymous HTTP/1.1
persistent-connection reads per path, spaced 0.25 seconds between rounds:

| Endpoint | Valid | p50 ms | p95 ms |
|---|---:|---:|---:|
| `/health/live` | 10/10 | 3.465875 | 12.752709 |
| `/api/v1/dashboard/shell?light=true` | 10/10 | 3.654833 | 17.574291 |

Identity stayed unchanged. Authenticated MCP was unavailable to this probe;
no authenticated, 350-agent, or TUI latency claim follows from these samples.
Private raw health, latency and CPU samples remain under `/tmp/masc-perf-*` on
the measurement host, not in this public evidence folder.

A three-second CPU sample included SHA256 and Memory OS journal validation on
a worker while the main thread mostly waited in poll. It does not identify the
owner or quantify a sole cause. No Curator architecture change follows from it.

## Incremental JSONL descriptor reads

One read previously opened the path for boundary validation, reopened it for
appended content, then reopened it for the next fingerprint. The candidate
uses one descriptor and its own `fstat`, closes it before folding, and reuses
the validated boundary for unchanged reads. It preserves the existing
512-byte boundary check; this is not validation of the entire file prefix.

The old fingerprint was read **after** `add`. Rewriting a file in place during
that callback attached the new boundary to old accumulated rows. The new test
reproduces this: expected `["y"; "x"]`, old source returned `["b"; "a"]`.
The candidate captures the fingerprint before the callback and reseeds on the
next read when the boundary differs. Short reads now fail without advancing
the cache. Exceptions from the fold still preserve the previous projection.

The exact module and the nine focused Alcotest cases ran in the OCaml 5.5.1
interpreter. The **only substituted dependency** is `Fs_compat.file_size`,
using synchronous `Unix.stat`; this does not validate Eio integration. The
baseline fails the rewrite reproduction (8/9); the candidate passes 9/9.
Raw outputs are `jsonl_tests_baseline.txt` and `jsonl_tests_candidate.txt`.

Reproduce tests and measurement, retaining source hashes and complete output:

```sh
python3 docs/evidence/performance-scale-20261023/run_jsonl_probe.py \
  --output /tmp/masc-jsonl-probe-new
```

Requires installed OCaml, findlib, Alcotest and mtime.clock.os. The output
directory must be new. Expected baseline failure is retained, not hidden;
read the logs for the failure's cause.

Synthetic workload: 35 or 350 distinct 75,000-byte files, each with 1,000
newline-terminated rows. Both modules are warmed, then read the same files in
nine rounds, alternating implementation order. Each append round adds one row
per file outside the timer. Timing uses a monotonic Mtime clock and includes
all reads and result-list allocation. Full GC runs before, outside each timed
batch. Both implementations must return the exact expected accumulated count.

| Files | Phase | Before median ms/batch | After median ms/batch | Before/after allocated bytes |
|---:|---|---:|---:|---:|
| 35 | unchanged | 1.082458 | 0.637000 | 68,848 / 51,488 |
| 35 | append | 1.546542 | 0.706709 | 91,528 / 82,848 |
| 350 | unchanged | 10.392958 | 5.787000 | 686,248 / 512,648 |
| 350 | append | 16.323625 | 6.918833 | 913,048 / 826,248 |

These are synchronous interpreter reads from a warm local filesystem, **not
350 concurrent Keepers**. `jsonl_probe.csv` retains raw rounds, and
`jsonl_probe.ml` defines the workload. No speed threshold is an approval gate.
Independent source review found no P0/P1/P2 issue; its P3 wording concern was
fixed to state the limited fingerprint scope explicitly.

## Later live observation (still the original binary)

At uptime 11m54s, the same runtime instance reported 31 Keeper fibers, RSS
13,735,952,384 bytes, and 60-second scheduler p50/p95/p99 of
1.090/6.690/73.621 ms (600 samples). The source changes above were **not
installed**. The difference from startup is not attributed to these changes.

Remaining evidence at this initial observation: native focused suites for both
changes; matched installed server/TUI measurements; file-read contention and memory profiling under the
active fleet; controlled 35/350-agent runs with continuity checks. Existing
Curator decisions, persistence validation and Keeper autonomy remain in scope
as invariants, not knobs to weaken for a lower latency number.

## Execution response observations and Candle clock equality

A later unchanged deployment sample (`68ec8fb2c52545c68600928524dcc12945e55ee7`)
measured the execution endpoint at p50 33.295 ms / p95 43.786 ms (10 anonymous
HTTP/1.1 requests). One response's Server-Timing was
`cache_lookup;dur=12.982, cache_compute;dur=14.283`, with 609,746 identity bytes.
Raw private result: `/tmp/masc-perf-latency-surfaces-20261023.json`.

The prepared-response lookup projected current Candle and Board-address data,
then discarded that projection on change. H1/H2 now accept the fresh JSON
from the same lookup, retaining prepared bytes only for equal observations.
Publication/source/workspace validity is checked again after observation I/O.
A changed source or invalidation falls back to the current publication. The
native tests now assert actual purchase/corrupt-ledger behavior through this
path and include mutation/replacement during observation. Source parsing and
independent adversarial review passed. Native/wire execution had not yet run
at this source-only stage; the later checks and comparison below extend it.

A separate reproduction found that structural equality included the internal
Candle balance replay clocks. With decay Off, observations one second apart
had equal wallet, supply, ownership and equipment but unequal internal balance
records. Comparing the policy, complete event history and monetary amounts
instead preserves the same observation sequence when only those clocks move.
All events remain compared, so a free purchase still changes the witness.
Address changes and out-of-order read admission retain their existing rules.

Verification used the **actual pure Candle modules**, preprocessing the two
portrait modules with their declared `ppx_enumerate`. The eleven balance
Alcotest cases passed, including wallet transfer at unchanged aggregate supply
and real decay. A source-extracted sequence probe checks both old/new sequence
functions: the old function changes identity across the clock-only observation,
the new one retains it. Free purchase, policy price changes, Disabled reason,
address changes, real decay and delayed older reads remain distinguished.

Reproduce the recorded historical sources with installed
OCaml/findlib/Alcotest/yojson/ptime/zarith/digestif,
ppxlib and ppx_enumerate; no Dune build:

```sh
python3 docs/evidence/performance-scale-20261023/run_candle_probe.py \
  --output /tmp/masc-candle-probe-new
```

The runner records source hashes, PPX output and full test/probe output. The
pure configuration/observation prefix and the observation-sequence functions
are extracted explicitly; ledger filesystem I/O, Eio, native HTTP handlers,
response compression and installed runtime performance are **not** exercised.
The broader HTTP suite includes a clock-only complete-response equality case;
its later native execution is recorded below.

The current server uses the public inserted-field identity introduced by
[#45594](https://github.com/jeong-sik/masc/pull/45594). The proposed whole-Candle
equality helpers were removed during integration because this upstream identity
already avoids clock-only invalidation. `run_candle_probe.py` now reads its
explicit historical `--before` and `--after` sources from Git, including the
Candle dependencies and tests, so the original evidence remains reproducible
without leaving duplicate production helpers or mixing current code into it.

## Completed native CI checks

Two explicit focused runs completed; neither is a full regression or release gate.
No local Dune build was used.

| Run | Source head | Selected suite | Passed |
|---|---|---|---:|
| [39936085154](https://github.com/jeong-sik/masc/actions/runs/39936085154) | `eb8542c375a9ad327a74b2662c65d671b933843a` | JSONL incremental projection | 9 |
| same | same | Audit projection | 7 |
| same | same | TUI Keeper chat transcript | 106 |
| [39939550826](https://github.com/jeong-sik/masc/actions/runs/39939550826) | `196f1f7134dc0bb3835c5e1d74e19d4cd4c6871c` | Dashboard cache | 60 |
| same | same | Dashboard HTTP core | 156 |
| same | same | Candle balance | 11 |

The full logs were read for actual suite execution and individual counts, rather
than treating workflow success as evidence that a selected suite ran.

## Native HTTP observation fixture

`scripts/harness/perf/execution_observation_probe.py` creates its own temporary
workspace and config, seeds paused Keeper metadata and synthetic Candle grants,
and launches one exact-source native server on an ephemeral loopback port.
It uses the bundled real Candle appraiser package in Docker, with its image
pinned by the inspected digest. Exact model outputs are disabled for this
installation; no appraisal obligations are seeded. This measures wallet and
address observations, not appraisal or provider throughput.

The experiment verifies real Candle readiness, every wallet, portrait/revision
and Board address, unchanged metadata and ledger bytes, zero active Keeper
fibers in the opening/closing health observations, and no attempted model POST.
An atomic owned TOML edit must appear in the next measured address response.
Requests use one HTTP/1.1 connection and cross whole-second Candle clock ticks.
The unchanged and address-changed phases are reported separately, including
raw elapsed time, encoding, bytes, ETag and Server-Timing. Normal snapshot TTL
and refresh remain active. The server exits before its workspace is removed;
Docker cleanup verifies labels and exact resource names before deletion.

Prerequisites: Python 3.11+, local Docker, source-verified native binary and its
bundled dylibs. Build only the optional Python worker image if absent:

```sh
docker build -f addons/candle-appraiser/Dockerfile \
  -t masc-lane-candle-appraiser:0.1.4 addons
python3 scripts/harness/perf/execution_observation_probe.py \
  --binary /path/to/verified-runtime/masc --source-sha FULL_SOURCE_SHA \
  --keepers 350 --samples 10 --output /tmp/new-observation-directory
```

A small installed-binary smoke additionally exercised a non-ASCII temporary
root and verified actual UTF-8 Docker ownership and cleanup. Existing output
directories were proven unchanged on failure. Independent adversarial source
review found three P2 issues in the measurement driver; all were repaired and
reviewed again before the comparison runs.

The source-verified macOS arm64 artifacts came from runs
[39939554841](https://github.com/jeong-sik/masc/actions/runs/39939554841)
(base `68ec8fb2c52545c68600928524dcc12945e55ee7`) and
[39939559032](https://github.com/jeong-sik/masc/actions/runs/39939559032)
(candidate `196f1f7134dc0bb3835c5e1d74e19d4cd4c6871c`).
Both workflow heads are `376e0f1abdd03163f7af4b4791c24ad46dd043f0`; that is
not the built source. Artifact metadata, `probe.json`, all published SHA256SUMS,
packaged runtime provenance and actual server/TUI embedded source identities
were checked. The dependency lists differ only in CI host name. The candidate
contains exactly the four performance changes above and their evidence.

Six sequential experiments completed 120 measured requests, all with exact
wallet/address assertions, unchanged paused metadata/ledger, no model POST,
clean server exit and verified Docker cleanup. Each table cell is p50 / p95
in milliseconds, from ten samples; p95 is therefore the maximum observed.

| Metadata rows | Order | Phase | Baseline ms | Candidate ms |
|---:|---|---|---:|---:|
| 35 | baseline, candidate | unchanged | 34.166 / 287.510 | 28.190 / 105.648 |
| 35 | baseline, candidate | address changed | 142.835 / 215.469 | 66.157 / 289.355 |
| 350 | candidate, baseline | unchanged | 179.649 / 464.302 | 841.562 / 1,262.383 |
| 350 | candidate, baseline | address changed | 209.667 / 510.495 | 1,259.215 / 10,142.396 |
| 350 | baseline, candidate | unchanged | 206.463 / 579.809 | 78.098 / 135.063 |
| 350 | baseline, candidate | address changed | 169.790 / 349.409 | 96.546 / 145.998 |

**No stable latency improvement is established by these shared-host samples.**
The first 350-row candidate run was much slower; reversing order reversed the
result. Host load averages varied substantially and are retained in the raw
packet, but they do not establish the cause of any outlier. The slow run and its
10.14-second request remain evidence requiring follow-up, not excluded samples.

The response-path behavior did reproduce consistently: all 30 unchanged
candidate samples reused gzip bytes and one body hash per experiment, while all
30 baseline samples returned identity encoding and changed body hashes. At 350
rows, unchanged wire bodies were 62,560–62,563 bytes versus
1,391,442–1,391,443 bytes. All changed
addresses were current; most candidate changed responses used fresh JSON. Their
Server-Timing showed one observation lookup; one slow sample also entered the
fallback cache_compute stage and retained both timings. This does not prove a
new cache snapshot was published. The baseline retained both stages throughout.

`native_http_observations.json` retains source/artifact identities, input hashes,
all 120 timing/header receipts, descriptive summaries and cleanup receipts. Raw
synthetic response bodies and complete private health/log packets remain in
`/tmp/masc-native-execution-*-20261023` on the measurement host, with their
request-log hashes in the committed packet. These are not installed candidate,
active 350-agent continuity, full TUI rendering, or 0.1 ms acceptance results.

## Metadata schema validation

An eight-second CPU sample of the verified candidate, in a new isolated
350-paused-metadata workspace, mostly observed waiting: 5,929 of 6,225 main
thread samples were in the poll stack. Active stacks included metadata key
validation/list membership, JSON/TOML parsing, filesystem opens/stats and
Candle account-revision work. This does not attribute the earlier 10.14-second
outlier to one cause. `native_profile_identity.json` binds the private sample
to the actual binary/runtime and cleanup receipts; its intrusive timing run
is excluded from the previous latency comparison.

The current-key validator scanned association lists for duplicates, known
fields and required fields on every metadata read. It now removes observed
keys from an immutable schema set. An absent removal returns the same set
under the OCaml 5.5.1 Set contract; this distinguishes a first valid occurrence
without a second lookup. Previously seen outside keys are tracked only on
malformed input. The generic duplicate helper used by nested values remains
unchanged. No file freshness or metadata value validation is skipped.

The first repeated key still outranks outside/missing fields, outside keys
retain input order, missing keys retain schema order, and successful fields
retain input order and values. The existing schema suite now exercises those
boundaries together. Independent adversarial source review passed after the
final set-removal change.

`run_meta_key_probe.py` interprets both complete source modules against their
actual interfaces, with the repository's JSON-kind function. It compares exact
results across 5,105 reordered/malformed/current-object cases and measures nine
alternating before/after rounds. The baseline is
`5f1002b04848ca14506155a55211e099bdb916c9`. Fixture construction and full GC are
outside the timed region. Schema-set construction occurs once at module load;
its startup cost is not measured. All changed sources and input hashes are in
`meta_key_sources.json`; raw rounds and exact-result receipt are retained.

```sh
python3 docs/evidence/performance-scale-20261023/run_meta_key_probe.py \
  --output /tmp/new-meta-key-probe
```

OCaml 5.5.1 interpreter, valid metadata key validation only:

| Objects | Before median ms | After median ms | Before / after allocated bytes |
|---:|---:|---:|---:|
| 35 | 1.564792 | 0.345708 | 117,336 / 135,256 |
| 350 | 14.001167 | 3.410041 | 1,170,696 / 1,349,896 |
| 3,500 | 150.829959 | 35.388625 | 11,704,296 / 13,496,296 |

This component becomes faster in the interpreter but allocates an additional
512 bytes per valid object in this fixture. It is not a native server speedup,
a file-I/O improvement, or an active-agent capacity result. Native schema and consumer execution for this additional source change
completed in run [39945635957](https://github.com/jeong-sik/masc/actions/runs/39945635957)
at `0b4ebf61148ebc0f68844af9ed20ed3dd6f88400`: current schema 12, current
keyset 3, invalid recovery 6 and Dashboard HTTP core 156 tests passed (177 total).
These do not cover the subsequent optional-read change below.

## One descriptor for optional metadata reads

Metadata presence and byte capture previously used a separate existence check
and read, with another path check inside the safe read adapter. The new path
uses one optional descriptor read in one blocking job; JSON decoding, UTF-8
repair, schema validation and recovery logging stay in their original caller
context. Every request still opens the current file. There is no new cache,
freshness interval, or batch cancellation delay across multiple files.

The shared optional reader treats only `ENOENT` from open as absence. A successful
open owns the length/read/close result even when the path is later replaced or
unlinked. This also fixes a reproduced failure: the prior optional wrapper
turned a short read into `None` if the path disappeared before its error handler
looked again. The candidate retains the read error. A non-directory metadata
parent now produces the documented read error instead of an absent Keeper.

The focused probe executes actual before/after Fs helper source with installed
Eio. Only fixture write/removal helpers are supplied locally. A declared
after-length hook in the historical reader creates the same controlled
truncate-and-unlink boundary as the candidate test hook. The baseline returned
`None`; the candidate raised `Sys_error`. Six cases in each of inline/Eio mode
plus the Eio cancellation case passed (13 total), including permission errors,
symlinks, opened-file replacement, failed reads and worker completion before
cancellation returns. The cancellation check yields before releasing the
blocked reader so an early-return implementation could not pass it trivially.

```sh
python3 docs/evidence/performance-scale-20261023/run_optional_read_probe.py \
  --output /tmp/new-optional-read-probe
```

Nine alternating rounds, warm synthetic metadata files, OCaml 5.5.1 interpreter
with actual Eio handoffs. Full GC and input preparation are outside each timer.
The timer includes every read and returned list allocation; exact bytes are
compared after the timer. This does not measure native HTTP, full metadata
parsing, active agents or installed-runtime improvement.

| Files | Before median ms | After median ms | Before / after allocated bytes |
|---:|---:|---:|---:|
| 35 | 2.053458 | 1.230084 | 154,648 / 86,608 |
| 350 | 17.025042 | 10.868625 | 1,540,648 / 860,248 |

The baseline source is `0b4ebf61148ebc0f68844af9ed20ed3dd6f88400`.
`optional_read_sources.json`, `optional_read_checks.txt` and
`optional_read_probe.csv` retain hashes, checks and all 36 measurement rows.
The source-extracted test run is distinct from the full native Fs and metadata
consumer suites, which remain pending for this change.

The final optional-read probe also ran beneath a non-ASCII temporary directory
containing a quote. Paths and fixture contents use explicit OCaml byte escapes,
and every expected read is `Some` of the actual 898-byte fixture. A negative
check where both readers returned `None` failed instead of passing equality.
The final packet records the runner hash as well as its production-source hashes.

## Native metadata-key comparison

Run [39945639233](https://github.com/jeong-sik/masc/actions/runs/39945639233)
produced source `0b4ebf61148ebc0f68844af9ed20ed3dd6f88400` from workflow head
`9c2256fea8fad3bb8ca7e5aed8a92cd803fcbdda`. Artifact metadata, checksums,
packaged provenance and actual server/TUI embedded identities were verified.
This source contains the metadata-key change but **not** the optional-reader
change above. Its comparison source is `196f1f7134dc0bb3835c5e1d74e19d4cd4c6871c`.

Four sequential private-server runs (before, after, after, before) completed
80 requests at 350 paused metadata rows with all semantic and cleanup checks
passing. Each cell is p50 / p95 milliseconds from ten requests.

| Pair | Phase | Before | After |
|---|---|---:|---:|
| before then after | unchanged | 157.600 / 200.126 | 152.672 / 188.491 |
| before then after | address changed | 169.443 / 644.668 | 188.174 / 1,569.290 |
| after then before | unchanged | 174.548 / 318.084 | 138.934 / 780.161 |
| after then before | address changed | 224.841 / 347.008 | 176.638 / 196.486 |

The unchanged p50 decreased in both pairs, but changed-response and tail
latencies are inconsistent. This does not establish a uniform native HTTP
speedup or attainment of 0.1 ms. The raw 80 measurements are in
`native_meta_key_http.csv`; `native_meta_key_http.json` binds them to the
source, binary, driver, runtime and cleanup receipts. No candidate was deployed
to the operating workspace, and no active 350-agent or TUI-render claim follows.

## Retained record buffer transfer

A 60.215-second read-only Memprof window on operating source
`107c58401723313611f7c599bbe15225de5910da`, instance
`01a1686c-45de-7000-ac1e-3d8569e594c8`, recorded no new dropped samples and
estimated 52.132 GB allocated, including 33.179 GB reaching the major heap.
The final whole-buffer copies in the first and verification reads accounted
for approximately 1.593 and 1.575 GB in stacks present in both cumulative
Top 30 tables. These are sampled allocation estimates, not elapsed-time
attribution or an exhaustive subsystem split. Earlier dropped samples limit
whole-live-heap attribution. The GC live size fell during this window;
this observation does not establish a monotonic leak. See
`allocation_window.json` for timestamps, counters and source identities.

`Lane_addon_store.record_bytes` owns its fresh byte buffer exclusively. After
reading exactly the expected length and confirming EOF, it transfers that
buffer to the immutable string result with `Bytes.unsafe_to_string`. It makes
no later write and exposes no mutable alias. Each verification read still
allocates its own buffer. Both complete reads, file/parent sync, shrink/growth
errors and descriptor/path identity checks remain in place.

`run_retained_read_probe.py` interprets the actual selected reader helpers
before and after the change. The 46 checks compare complete binary bytes and
errors, retain earlier results across subsequent file changes/reads, and
exercise same-inode rewrite, shrink, growth and replacement during sync.
Nine alternating before/after repetitions measure durable double reads of the
same warm private regular file, including actual file/parent `fsync`:
The timed loop also compares every returned byte with the expected payload.

| Record size | Reads | Before median ms | After median ms | Before allocated bytes | After allocated bytes |
|---|---:|---:|---:|---:|---:|
| 64 KiB | 35 | 7.858 | 5.156 | 9,241,368 | 4,652,728 |
| 64 KiB | 350 | 69.620 | 39.518 | 92,411,448 | 46,525,048 |
| 1 MiB | 35 | 73.880 | 41.451 | 146,866,968 | 73,465,528 |
| 1 MiB | 350 | 766.122 | 412.416 | 1,468,667,448 | 734,653,048 |

The before source is `19eded8bc18c890e058dfc34123803431fcdb683`; complete
file/selected-helper hashes are in `retained_read_sources.json`, with all
72 timing rows in `retained_read_probe.csv` and checks in
`retained_read_checks.txt`. This is OCaml 5.5.1 interpreter evidence for the
reader boundary, excluding JSON decode, caller scheduling and HTTP. Counts
are record reads, not active Keepers. It is not a full-module native test,
installed-runtime improvement or proof of the 0.1 ms target.
