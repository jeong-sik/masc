# Post-mutation first HTTP response comparison

This answers the request for same-input first-response median/p95 measurements.
It measures the first public `/api/v1/dashboard/execution` GET after a real MCP
Task mutation invalidates the execution cache. `cold` in the raw data means
**post-mutation first HTTP response / prepared-route miss**. It does not prove
that every internal cache was cold, or isolate projection or serialization cost.

## Controlled inputs and scope

- Baseline source `53f784617c1867b3ecadb300bc8bd1d0844dd233`, artifact
  `10905313235`, [build 36239521218](https://github.com/jeong-sik/masc/actions/runs/36239521218).
- Candidate source `887807abe0bfb2b3d2df7fbca7672faa199aa898`, artifact
  `10905529982`, [build 36241015541](https://github.com/jeong-sik/masc/actions/runs/36241015541).
- The server product diff is the two execution-surfaces files. Other source
  differences concern TUI instrumentation, tests and evidence. Those two server
  files match PR head `a488cf8b6b9ea142c3e551f4540737647570cbfc` byte for byte;
  `source-scope.json` records all changed paths and file hashes. This is not a
  new binary built from the later integrated PR head.
- Each binary manifest, all three binary hashes, source/run/artifact/repository
  identity, isolated runtime root, running executable hash, and zero Keeper
  fibers were checked. Both manifests say `release_validated:false`.
- One macOS host; sequential isolated server sessions; no production restart,
  configuration change or deployment. Each session owns an empty workspace and
  a loopback model stub. The child receives only the recorded environment keys,
  synthetic runtime configuration and synthetic authorization. The sole model
  request was a local `GET /v1/models`; no generation was requested.
- For each of `identity` and `gzip`: three sessions per arm, alternating
  before/after, after/before, before/after. Each session creates the same 250
  tasks, then runs 20 cycles of add-task, first GET, warm GET. Task mutation is
  outside the GET timer. The corrected paths use equal-length `before`/`after_`.
- 12 completed sessions, **480 GETs**, 60 first and 60 warm samples per arm per
  encoding. All planned samples are retained. No outlier is dropped.
- Every first GET has `cache_compute`, increasing publication generation and
  exactly 250 + cycle tasks. Warm GETs lack `cache_compute`. The full parsed
  first/warm bodies agree within a cycle. Across all sessions, every task field
  agrees except the explicitly excluded `created_at` and `updated_at` times.
  Tool argument hashes and order match. All 12 servers were reaped with exit 0.
- Timing starts before a **new TCP connection's** request and ends after the
  complete body read. JSON parsing and gzip decompression happen afterward.
  This includes Python observation, loopback TCP and OS scheduling. It is not
  a browser, physical display, loaded production or deployment measurement.
- Samples within sessions are related, and the shared host was not CPU-isolated.
  Three sessions per arm do not establish a universal or statistically proven
  latency bound. Dynamic timestamps, diagnostics, ports and paths differ.

## Corrected experiment

Values are milliseconds. p95 is nearest rank, `sorted[ceil(0.95*n)-1]`.
All rows have 60 samples per arm. Complete per-session and wire-size statistics
are in `corrected/summary.json`.

| Request | Baseline median / p95 / max | Candidate median / p95 / max |
|---|---:|---:|
| identity first | 12.823875 / 14.863000 / 15.257375 | 12.362959 / 17.188667 / 30.551750 |
| identity warm | 0.498188 / 0.606959 / 0.702208 | 0.531626 / 1.139917 / 6.841917 |
| gzip first | 13.020604 / 13.743875 / 14.518417 | 12.206542 / 13.831209 / 18.291166 |
| gzip warm | 0.482813 / 0.570833 / 0.659541 | 0.498729 / 0.737541 / 2.166459 |

First-response medians fell by 0.461ms for identity and 0.814ms for gzip.
**First-response p95 and max increased for both encodings.** Identity first
median improved in two sessions and worsened in the third. Gzip first median
improved in all three. Both warm medians increased. This is mixed evidence,
not proof of a general latency improvement.

For gzip requests, baseline first responses were actually identity encoded
(median 146,108.5 wire bytes), while candidate first responses were gzip encoded
(median 16,142 bytes). The endpoint now uses its prepared gzip representation
on that first path. This comparison includes the encoding/wire-size change;
it cannot attribute the observed difference solely to duplicate serialization.
Server `cache_compute` medians were 11.6285 → 11.722ms for identity and
11.799 → 11.643ms for gzip. Those span the handler's measured work and are not
an isolated projection or serializer measurement. The 0.1ms goal remains unmet.

## Original experiment and review corrections

`initial/` retains the entire first 12-session/480-GET experiment. It used
unequal-length `baseline` and `candidate` directory names. It is not pooled
with the corrected experiment or silently discarded:

| First response | Baseline median / p95 / max | Candidate median / p95 / max |
|---|---:|---:|
| identity | 13.013167 / 14.969375 / 29.558334 | 13.029729 / 13.918833 / 14.271875 |
| gzip | 12.732854 / 13.408125 / 15.217708 | 11.813083 / 12.497083 / 14.073833 |

The review also found missing interrupted-process cleanup and an identity write
outside `try/finally`. The corrected experiment added signal cleanup and moved
the write. A follow-up review found identity *construction* still outside the
protected block; the standalone `session.py` here moves that inside too.
This last change occurred **after** the corrected measurement. Each archive
contains the exact as-run scripts and their hashes; the final rerun script is
kept separately. No timing result is attributed to that unmeasured cleanup edit.
`interrupt-result.json` plus `interrupt-identity.json` record a real SIGTERM
through driver → session → owned server: driver exit 143, server exit -15,
reaped and PID absent. Successful timing sessions all exited 0 independently.

The adversarial reviewer accepted the measurement scope; the response reviewer
independently checked all 480 corrected observations, input hashes, task/body
comparison, generation transitions, identities, cleanup and aggregate values.

## Retained receipts and verification

Each `receipts.tar.xz` contains 101 files: exact as-run scripts, plan, summary,
stdout/stderr/exit receipts, all tool results, identities, cleanup and all parsed
HTTP responses. To permit compact lossless archiving, `responses.json.gz` is
stored as its exact decompressed JSON receipt bytes. `receipt-files.json`
records both original-file and archived-member SHA-256. No real runtime data,
operator credentials, dev tokens, server runtime folders or raw server logs
are included. All response bodies are synthetic.

The request runner recorded hashes of decoded HTTP bytes and asserted first/warm
hash equality at runtime. Original HTTP bytes were not retained, so those hashes
cannot be independently regenerated from the parsed JSON receipts. Parsed-body
and task equality **can** be independently recomputed. Do not conflate them.

From this directory, restore and recompute either experiment:

```sh
python3 restore.py corrected /tmp/masc-http-receipts
python3 /tmp/masc-http-receipts/summarize.py /tmp/masc-http-receipts
```

The complete executed commands are in each `plan.json`. To repeat using already
verified/unpacked artifacts and the final cleanup correction (no local build):

```sh
python3 compare.py --repo "$MASC_CHECKOUT" \
  --baseline "$BASELINE_ARTIFACT" --candidate "$CANDIDATE_ARTIFACT" \
  --runner "$PWD/session.py" --output "$NEW_MEASUREMENT_DIR" \
  --cycles 20 --tasks 250 --repetitions 3
python3 summarize.py "$NEW_MEASUREMENT_DIR"
```

The checkout's `scripts/fixtures/release-evidence/runtime.toml` must match the
retained `runtime-fixture.toml`; each run records its hash. The artifact
metadata files must be present alongside each manifest and its three binaries.
`compare.py` fixes the source/run/artifact identities to the two inputs above.
