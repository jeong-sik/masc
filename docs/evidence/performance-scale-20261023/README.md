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
change. No local Dune build, whole-transcript behavioral suite or native TUI
measurement was run. Existing transcript tests cover late results and
superseded attempts; those still need execution on the candidate artifact.

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

Remaining evidence: native focused suites for both changes; matched installed
server/TUI measurements; file-read contention and memory profiling under the
active fleet; controlled 35/350-agent runs with continuity checks. Existing
Curator decisions, persistence validation and Keeper autonomy remain in scope
as invariants, not knobs to weaken for a lower latency number.
