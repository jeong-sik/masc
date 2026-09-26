# JSON-only cache preparation: isolated native comparison

## Scope and identity

Baseline `c60d967b19a96d01523d830a777df0c39703c7cc` is artifact `10908567580` from [Release 36249065961](https://github.com/jeong-sik/masc/actions/runs/36249065961). Candidate `e45b749a7cd8e2cbdcbec85cca60b86e4c9915be` is artifact `10909571599` from [Release 36251445720](https://github.com/jeong-sik/masc/actions/runs/36251445720). Download metadata, ZIP size/digest/members, embedded source and all three binary hashes were verified before execution. Both manifests say `release_validated: false`; this is a runtime probe, not a release validation or deployment.

Only `lib/dashboard/dashboard_cache.ml` and `.mli` differ in product source between these arms. Both candidate files exactly match PR source head `343af811a81dae76d0f4844bec1d92b115a64264`. The probe inherits 16 lines of earlier prepared-snapshot test coverage absent from that PR base; `inherited-test-difference.patch` retains that difference. New JSON cache scenarios are identical. `source-scope.json` records every changed path. Both arms include earlier inline sanitizer and first-response preparation changes; neither includes shared backlog encoding. Whole repository identity with the PR base is not claimed.

## Workload and measurement

24 fresh owned server sessions: ASCII or Korean/ASCII descriptions, identity or gzip GET requests, three repetitions per arm. Order is baseline/candidate, candidate/baseline, baseline/candidate. Each session seeds 250 tasks through 13 batches, then performs 20 add-task / first GET / warm GET cycles: 480 mutation acknowledgements and 960 GET responses, 60 samples per text/encoding/phase/arm. Servers have zero Keeper fibers and use a local model-list stub. No operator runtime data or credentials are used.

Each request opens fresh TCP. `wire_ms` starts before the HTTP request and ends after reading the full body; request JSON construction and response JSON parsing/decompression are excluded. The encoding column applies to GETs; MCP mutation acknowledgements are identity encoded in every group. The shared host was not CPU-isolated. Earlier DEBUG phase observations are a separate instrumented diagnosis and are not pooled here.

Inputs and projected task fields match within text kind after removing creation/update timestamps. Every first response includes the new task and `cache_compute`; generation increases. Its warm response has no compute and the same parsed body and runtime body hash. Full stored primary/recovery backlogs were also checked: 270 tasks, revision 34, exact full seed descriptions, matching normalized fields, and identical primary/recovery bytes. GET projection truncates descriptions, so it alone is not that persistence proof. All 24 servers and local stubs were cleaned up; servers exited zero and were reaped.

## Observations

Numbers are milliseconds, baseline → candidate. Each aggregate has 60 observations. p95 is nearest rank `sorted[ceil(.95*n)-1]`. The final column counts repetitions whose candidate median was lower (each repetition has 20 observations).

| Text / requested GET encoding | Phase | Median | p95 | Maximum | Lower repetition medians |
|---|---|---:|---:|---:|---:|
| ascii / identity | MCP add | 19.242854 → 18.612521 | 36.494500 → 26.584833 | 70.018250 → 50.885750 | 2/3 |
| ascii / identity | First GET | 12.218084 → 11.625875 | 17.938625 → 13.614542 | 25.371000 → 21.246792 | 3/3 |
| ascii / identity | Warm GET | 0.572437 → 0.557833 | 0.853666 → 0.798666 | 2.140084 → 0.962500 | 2/3 |
| ascii / gzip | MCP add | 18.339334 → 19.175125 | 28.756667 → 30.335292 | 34.795000 → 44.401083 | 2/3 |
| ascii / gzip | First GET | 12.253270 → 11.595083 | 13.694625 → 13.309416 | 24.546000 → 21.460584 | 3/3 |
| ascii / gzip | Warm GET | 0.529937 → 0.534896 | 0.763625 → 0.718667 | 2.261333 → 1.245125 | 1/3 |
| multilingual / identity | MCP add | 20.188729 → 19.504104 | 26.667583 → 31.214125 | 33.208708 → 51.309500 | 2/3 |
| multilingual / identity | First GET | 13.318938 → 12.163062 | 15.675958 → 17.351500 | 26.873584 → 23.450709 | 2/3 |
| multilingual / identity | Warm GET | 0.585542 → 0.582562 | 0.775042 → 0.859583 | 3.855625 → 3.890875 | 1/3 |
| multilingual / gzip | MCP add | 20.669229 → 19.216979 | 31.262875 → 23.344208 | 67.096667 → 31.815541 | 2/3 |
| multilingual / gzip | First GET | 13.413521 → 12.263563 | 15.191792 → 14.140584 | 15.880917 → 18.299833 | 2/3 |
| multilingual / gzip | Warm GET | 0.544917 → 0.552833 | 0.704584 → 0.749583 | 1.754792 → 0.978458 | 1/3 |

First-GET aggregate medians are lower by about 4.8–8.7% in all four conditions. Repetition medians are lower in all three ASCII repetitions but only two of three multilingual repetitions. Multilingual identity first-GET p95 is worse (15.675958 → 17.351500ms), and multilingual gzip first-GET maximum is worse (15.880917 → 18.299833ms). Thus lower central values do not establish uniformly improved tails.

Mutation and warm-response changes are mixed: ASCII gzip mutation median/p95/maximum are worse; multilingual identity mutation p95/maximum are worse; gzip warm medians are slightly worse. These observations do not establish a general speedup, causal per-function CPU savings, or allocation-volume reduction. Every candidate wire observation exceeds 0.1ms. No production deployment or improvement is established.

## Reconstruct and audit

`receipts.tar.xz` retains 197 files: the exact measurement scripts, plan, summary, and eight receipts per session. Response JSON is stored decompressed. `persisted-backlogs.tar.xz` separately retains all 48 full primary/recovery files, indexed by `persisted-backlogs.json`. `receipt-files.json` records original local hashes and published archive-member hashes.

Host-specific checkout, temporary-directory and Python executable paths are replaced with stable placeholders in 49 comparison receipts and two earlier diagnostic files. `redaction.json` describes the changed files and both hashes. Numeric observations, source/artifact/binary hashes, scripts and persisted backlogs are unchanged. Runtime body/config hashes refer to original runtime bytes, not path-redacted JSON. Original hashes are provenance; omitted paths cannot be reconstructed from the public bundle.

```sh
python3 restore.py . restored
python3 restored/summarize.py restored
cmp summary.json restored/summary.json
```

Restore verifies archive members and writes the published normalized receipts. Gzip byte streams may vary by Python/zlib; decoded published JSON is exact. The generated summary must match byte for byte. For a new run, pass actual local paths to `compare.py`/`session.py` in place of the recorded placeholders; download the anchored artifacts and supply a checkout with the retained runtime fixture.

## Compiled checks

At source head `343af811a81dae76d0f4844bec1d92b115a64264`, [PR check 36251389478](https://github.com/jeong-sik/masc/actions/runs/36251389478) passed all five gates. Its debug job ran ten selected suites with zero skipped, including all 58 Dashboard_cache tests and the four new materialization scenarios. `source-ci.json` retains selected log coordinates and the full local log hash. Focused [PR run 36251389423](https://github.com/jeong-sik/masc/actions/runs/36251389423) also passed 204 tests (58 cache + 132 HTTP core + 14 namespace); [probe run 36251447158](https://github.com/jeong-sik/masc/actions/runs/36251447158) passed 205 (58 + 133 + 14). The probe baseline already contains one additional HTTP core test. Both logs explicitly pass the four new materialization scenarios. This documentation commit receives its own current-head PR check. No local OCaml build was run.
