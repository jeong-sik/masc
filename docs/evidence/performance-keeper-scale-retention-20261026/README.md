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
  This frozen pair receipt predates the native population experiments below.

## Candidate native observations

[Selected numeric derivative](native-cohorts-derivative.json) binds the binary,
runner, independent reader and raw receipt hashes for three separate runs.

| Keeper owners | Original operations succeeded | Actual held provider peak | Valid health/live samples | HTTP 429 | Recorded rate wait |
|---|---:|---:|---:|---:|---:|
| 2 | 4 | 2 | 6/6 | 0 | 0 s |
| 30 | 60 | 30 | 71/71 | 5 | 5.034 s |
| 300 | 600 | 300 | 1041/1041 | 70 | 70.390 s |

All three workload runs and their independent packet-reader checks passed.
The [independent candidate evidence audit](evidence-audits/v1/README.md) checked
the raw 2/30/300 packets; [the additional audit](evidence-audits/v2/README.md)
checked baseline/batch packets and all four numeric/document derivatives.
These are offline evidence audits, not formal GitHub approvals or new native
runs. Selected audit summaries are retained here; their full local receipts
and original packets remain under the recorded artifact paths.
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
Exact-status settlement RPC maximum was **13209.663 ms**, which is distinct
from durable turn completion. These three native cohorts had no batch members;
the batch projection evidence above is source and synthetic Python execution.
Full health reported `degraded` with `keeper_memory_execution:addon_unattached`
and `operator_action_required=true`; valid health/live samples do not prove
full product readiness or attached Add-on Lanes.

[A separate native batch qualification](native-batch-qualification.json) used
2 Keepers with 3 messages each: all 6 operations passed through 4 model calls,
and terminal SQLite contained 4 batch members. Original/member/merged leader
digests and complete reply coverage passed. Its held snapshot had no members,
so the held Running follower projection remains source/Python evidence.

## Same-builder baseline observations

Baseline application `1ce158d50d3eb48648e6deea7f668172f914fea3` also passed
separate 2/30/300 runs, including all 600 original operations and peak 300 held
requests at the largest population. The baseline uses the exact same release
runtime fixture bytes from the c3cb support checkout. The application sources,
artifact hashes and support fixture provenance remain separate identities.

[All six population observations](native-cohort-before-after-observations.json)
retain favorable and unfavorable values. At 300 owners, baseline/candidate
admission wire p50 was 22.478/22.229 ms, exact-status maximum 9582.334/13209.663
ms and released health/live maximum 2546.932/3599.316 ms. GC-counter-derived
process allocation was 67.548/67.545 GB. There is **no established native
performance gain**: one sequential run per source/population on a shared host
cannot isolate a stable effect, and this workload does not prove execution of
the changed large retained Lane read path. The earlier extracted-helper
allocation result is a separate evidence layer.

Population runs occurred sequentially on a shared host, once per source and
population; the native batch qualification is separate. This is
capacity and evidence qualification, not an attributable performance gain.
Latency includes hold, pacing, queue, runtime work, client and OS overhead.
The full private packets remain under
`artifacts/runs/extreme-perf-20261026/owned-concurrent-c3cb371-{2,30,300}-v3`.
Raw RPCs, runtime credentials and copied executables are intentionally absent
from this versioned derivative. Frozen review files retain their original
paths and hashes; their scripts and receipts describe the captured source,
not permission to rewrite this retained bundle.
