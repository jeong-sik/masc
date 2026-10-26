# Keeper scale evidence retention and original input checks

The previous scale harness deleted its owned base before validating durable
operation semantics, and its fallback deleted the original after a failed
backup. It also compared copied rows without recomputing the original source,
input and admission digest. Evidence v3 retains `OUTPUT/owned-base` on success
and failure, captures both operation tables in one read transaction per Keeper
before provider release, and checks original inputs through terminal settlement.

Batch leaders use the combined execution input; followers keep their original
input digest and project the leader's public state. The independent reader
reconstructs messages from the workload and successful raw RPCs, then reopens
both the retained original and backup SQLite databases. It accepts v3 only.

The production binary is unchanged by this harness layer. The parent is
`4ac6dce147d735d74440263ad79071da34d77878`; tested application source is
`c3cb3715e3a36b56ae17c23820b6b7c83914a602`, server SHA256
`06ee93c99b31a6fca6786c2c6a676c8023b62b0fc854da6616518c21202ad3a8`.

## Validation

- [25 synthetic fault cases](faults.json) passed without starting MASC. These
  include source/admission/member drift, a merged leader, projected follower
  state, terminal input clearing and failed-copy DB/WAL/log retention.
- [Canonical subset receipt](canonical-subset/receipt.json): eight generated
  ASCII/null/list/object payload values matched the exact c3cb canonicalizer
  interpreted by OCaml 5.5.1 with installed Yojson. This is not a general JSON
  serializer equivalence proof or a local Dune build.
- [Independent full source review](reviews/v2/README.md) found a public-state
  projection error; [the exact correction review](reviews/v3/README.md) passed.
  Current four-file diff SHA256 is
  `d40158cb9438fab13b8ce23776ec05421f6129bb032a763134a796654abce584`.
  Reviews use the same inherited model and are not formal GitHub approvals.
- [Qualified native pair](qualified-native-pair.json): both application commits
  were built by workflow source `6a2d8dd6171e1d732ca15f918fb084e462e4d371`;
  downloaded bytes and isolated embedded commit commands matched. The four
  selected native resource tests passed for each artifact. This does not prove
  shared-runtime installation or visible TUI behavior.

## Candidate native observations

[Selected numeric derivative](native-cohorts-derivative.json) binds the binary,
runner, independent reader and raw receipt hashes for three separate runs.

| Keeper owners | Original operations succeeded | Actual held provider peak | Valid health/live samples | HTTP 429 | Recorded rate wait |
|---|---:|---:|---:|---:|---:|
| 2 | 4 | 2 | 6/6 | 0 | 0 s |
| 30 | 60 | 30 | 71/71 | 5 | 5.034 s |
| 300 | 600 | 300 | 1041/1041 | 70 | 70.390 s |

All three workload runs and their independent packet-reader checks passed.
Owned servers exited 0 without forced kill; samplers, provider listeners and
handlers stopped. Original bases and SQLite backups remain local. These are
real native Keeper owners and durable queued operations against one scripted
loopback text provider, with a 10 ms reply delay and the first requests held
until every owner has entered. One admin producer and sequential status reads
encounter the existing rate limiter. No external model throughput, guest tools,
peer business calls, Add-on execution or TUI result is demonstrated.

The 300-owner released phase had health/live wire p50 0.958 ms, p95 7.548 ms
and maximum **3599.316 ms**. The final scheduler window recorded maximum
1158.108 ms and one stall. End RSS was 2,097,364,992 bytes. A denied read-only
volume inventory attempted 600 commands over an 18.040 s timestamp span;
overlap is not causal attribution. The 0.1 ms goal is **not achieved**.

Runs occurred sequentially on a shared host, once per population. This is
capacity and evidence qualification, not an attributable performance gain.
Latency includes hold, pacing, queue, runtime work, client and OS overhead.
The full private packets remain under
`artifacts/runs/extreme-perf-20261026/owned-concurrent-c3cb371-{2,30,300}-v3`.
Raw RPCs, runtime credentials and copied executables are intentionally absent
from this versioned derivative. Frozen review files retain their original
paths and hashes; their scripts and receipts describe the captured source,
not permission to rewrite this retained bundle.
