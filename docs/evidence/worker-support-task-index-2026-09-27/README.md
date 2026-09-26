# Worker task index: controlled Linux comparison

Run [36264755621](https://github.com/jeong-sik/masc/actions/runs/36264755621)
used observer `f0349b29fe7fd44ff4b5de53646799840771ee60`. It compared baseline
`63b6a34a2e5d8a5388ff8da6088fb6755e81506f` (probe run 36263898895, artifact
10913715720) with source candidate `6420fbe9e7e15a1cd24d95cda83b1a385f008a58`
(probe run 36263900169, artifact 10913895110). The comparison artifact is
10913590943, ZIP SHA-256 `1b6041cf5ce3573c8b362e2f60cdc93e66642c3acc25914d1dbee5fc6e1dcef8`.
Both manual builds, source/repository/attempt, ZIP and four ELF executable
hashes were independently verified before interpreting the observations.

## Protocol and correctness

Three pairs alternate AB/BA/AB per ASCII/multilingual and requested identity/gzip
condition: 24 sessions, each with 25 synthetic active agents and 816 initial
Todo tasks. There are 20 mutation/cold/warm cycles and 20 separate concurrent
mutation/liveness pairs per session. All 3,456 HTTP receipts and 2,400 timed
requests passed the reviewed strict validator. The 480 concurrent request
pairs overlap at the client; overlap with a particular server computation is
not established.

All 12,600 checked worker briefs (prime plus cold projections) preserve fixture
names, active status, quiet state and zero owned-task counts. Cold and warm
bodies are byte-identical within each cycle. Worker records remain unchanged
at shutdown. Full agent and brief fields/order compare across both builds and
repetitions, excluding only the clock-derived `last_signal_age_sec`; original
ages remain in raw receipts. All persisted copies have 856 Todo tasks and
revision 82 from initial 1, and primary/recovery bytes match per session.
All server children exited zero and were reaped. Model stubs stopped after a
total of 24 discovery GETs and no POSTs; there were no Keeper fibers.

This all-Todo workload exercises repeated task scans, not updates for claimed
or in-progress tasks. A real runtime had 25 agents and 816 total tasks; only
those counts informed this synthetic fixture. The actual task/agent contents
and task-state distribution were not copied.

## Measured results

Each arm/cell below has 60 observations. Times are milliseconds; p95 is nearest
rank. `Pairs lower` counts the three repetitions whose candidate median is
strictly lower than its paired baseline. Pooled and paired medians can disagree.

| Text | Requested encoding | Phase | Baseline median | Candidate median | Baseline p95 | Candidate p95 | Pairs lower |
|---|---|---|---:|---:|---:|---:|---:|
| ascii | identity | mutation | 50.432516 | 50.742843 | 56.135243 | 58.912744 | 2/3 |
| ascii | identity | cold | 45.706491 | 46.262851 | 50.135484 | 54.047798 | 1/3 |
| ascii | identity | warm | 0.785124 | 0.784647 | 0.992796 | 0.990011 | 1/3 |
| ascii | identity | concurrent_mutation | 63.635803 | 62.407629 | 74.361256 | 67.080053 | 1/3 |
| ascii | identity | concurrent_liveness | 0.737283 | 0.704092 | 0.826726 | 0.890326 | 3/3 |
| ascii | gzip | mutation | 50.354440 | 50.535756 | 54.015686 | 57.564364 | 1/3 |
| ascii | gzip | cold | 45.042849 | 43.886444 | 49.340056 | 48.466939 | 2/3 |
| ascii | gzip | warm | 0.553024 | 0.535837 | 0.606814 | 0.614450 | 2/3 |
| ascii | gzip | concurrent_mutation | 61.525659 | 60.533754 | 65.864831 | 66.449117 | 2/3 |
| ascii | gzip | concurrent_liveness | 0.698766 | 0.665249 | 0.847888 | 0.781225 | 2/3 |
| multilingual | identity | mutation | 52.376373 | 51.968451 | 56.568042 | 55.782789 | 2/3 |
| multilingual | identity | cold | 43.145810 | 43.491254 | 46.385667 | 46.067259 | 2/3 |
| multilingual | identity | warm | 0.666477 | 0.669782 | 0.873685 | 0.828300 | 1/3 |
| multilingual | identity | concurrent_mutation | 61.954007 | 63.521626 | 67.077005 | 69.367012 | 0/3 |
| multilingual | identity | concurrent_liveness | 0.663621 | 0.690032 | 0.775392 | 0.824263 | 0/3 |
| multilingual | gzip | mutation | 51.933391 | 53.028146 | 56.137961 | 56.546122 | 0/3 |
| multilingual | gzip | cold | 43.442103 | 43.019977 | 46.651974 | 46.522345 | 0/3 |
| multilingual | gzip | warm | 0.509994 | 0.518199 | 0.566991 | 0.565368 | 1/3 |
| multilingual | gzip | concurrent_mutation | 62.746494 | 63.196111 | 68.400560 | 69.603039 | 1/3 |
| multilingual | gzip | concurrent_liveness | 0.684840 | 0.676104 | 0.818759 | 0.779428 | 2/3 |

Cold-GET pooled medians fell in two of four conditions and p95 fell in three,
but no condition had all three paired medians lower. Mutation and warm/liveness
results also vary. **This does not establish a consistent end-to-end benefit;
PR #39412 remains draft.** It does not establish a general causal regression
either. No identical rerun is scheduled to seek a more favorable sample.

All 1,200 candidate observations exceed 0.1 ms; minimum is 0.434993 ms. Baseline's
maximum is 575.375807 ms (ASCII/identity repetition 1 concurrent mutation cycle
20, mcp_dispatch 573.740 ms). Candidate's maximum is 72.759337 ms (multilingual/
identity repetition 3 concurrent mutation cycle 10, mcp_dispatch 71.059 ms).
Those outliers remain included; their causes are unknown. See full session
metrics and raw observations for spread. No CPU profile or dedicated task-scan
or index timing was captured; retained Server-Timing describes route components.
Removed task visits are not assigned a measured time saving.

Fresh TCP, client/OS scheduling and complete body transfer are timed; JSON/gzip
decoding and evidence writes occur afterward. Shared CI scheduling, request
order and limited repetitions constrain inference. Actual response encodings
are recorded independently: requested gzip can receive identity on a cold GET.
This is not a physical-display, deployment or broad Keeper-continuity proof.

## Source, tests and retained records

`source-scope.json` limits the product diff to the two execution-builder files.
Focused run 36263884592 at candidate source passed 169 selected compiled cases:
24 dashboard briefing (including the new exact-ownership scenario), 13
continuity briefs and 132 HTTP core. The job's actual log is identified by
SHA-256 and job coordinates. Later evidence-head PR gates remain separate.

All 341 original artifact members are retained as deterministic gzip under
`raw/`. `redaction.json` maps every original and published decoded hash.
Only owned-workspace/artifact and CI checkout/home path prefixes are normalized;
full synthetic response bodies, worker inputs, persisted copies and health
remain. Original body hashes, JSON sizes, wire sizes and times remain intact.
Path-normalized bodies have separate `published_body_sha256` and
`published_json_bytes`. `files.json` hashes committed files. Root validated
original private receipts before normalization; these public paths do not
reconstruct the omitted host paths.
