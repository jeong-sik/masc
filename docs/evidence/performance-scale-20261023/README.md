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
