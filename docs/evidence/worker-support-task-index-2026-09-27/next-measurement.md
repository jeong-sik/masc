# Worker task index: diagnostic follow-up

Status: offline analysis completed; the proposed workload and instrumentation
below have **not** been implemented or run. Keep #39412 Draft. Review the
observer changes before building new probe artifacts or dispatching a comparison.

## Replay the retained phase measurements

From this repository, with an unused output pathname:

```sh
python3 scripts/harness/perf/summarize_server_timing.py \
  --evidence docs/evidence/worker-support-task-index-2026-09-27 \
  --output /tmp/worker-index-server-phases.json
```

This reads only committed files. It verifies all 341 archive members against
`raw-files.json`, reads all 3,456 HTTP receipts from 24 sessions, and retains
every duration with its session, repetition, phase, cycle and receipt ordinal.
It reports each repetition and pooled repetitions of each cell, preserving text
kind, requested session encoding, actual response encoding and build role.
Missing metrics stay absent; no observations or outliers are removed. The
original provenance and semantic audit remains separate from this analysis.

All 480 cold observations contain `cache_lookup` and `cache_compute`; all 480
warm observations contain only `cache_lookup`. None contains worker task scan
or index timing. Each row below has 60 observations per arm. Durations are ms;
p95 is nearest rank. Paired counts compare the three repetition medians.
All eight cold groups below actually received identity responses, including
the groups that requested gzip; these are not compressed cold-response timings.

| Text | Requested encoding | Baseline compute median / p95 | Candidate compute median / p95 | Candidate paired medians lower |
| --- | --- | --- | --- | --- |
| ASCII | identity | 41.6445 / 46.046 | 41.596 / 49.484 | 1/3 |
| ASCII | gzip | 41.4175 / 45.245 | 40.188 / 44.908 | 2/3 |
| Multilingual | identity | 40.015 / 43.069 | 40.2125 / 43.209 | 2/3 |
| Multilingual | gzip | 40.078 / 43.030 | 39.7455 / 43.229 | 1/3 |

These server wall times locate a substantial part of cold latency inside the
complete compute call. They do not establish a task-index benefit or CPU cost.
Do not sum arbitrary Server-Timing spans: spans can nest. Do not subtract pooled
medians and call the difference serialization, scheduler or network time.

## What the existing sources can measure

The source baseline is `63b6a34a2e5d8a5388ff8da6088fb6755e81506f`, candidate
`6420fbe9e7e15a1cd24d95cda83b1a385f008a58`, and observer
`f0349b29fe7fd44ff4b5de53646799840771ee60`.

- `lib/server/server_routes_http_routes_dashboard.ml:2715`: the execution
  route measures cache lookup and `dashboard_execution_http_response` only.
  Its cold `Execution_json` response serialization occurs after that timing.
- `lib/server/server_dashboard_http_execution_surfaces.ml:1467`: compute
  includes the offloaded complete dashboard render and projection diagnostics.
  Request wall time can therefore include waiting as well as computation.
- `lib/dashboard/dashboard_execution.ml:147,227,689,809`: existing render
  observations separate snapshot, operations, enrich, data load and assembly.
  Task loading and operation construction are in `operations`; worker support
  construction is in `assemble`, alongside other work. These are aggregate
  histogram observations using `Time_compat.now`, not task-index CPU samples.
- `lib/dashboard/dashboard_execution_builders.ml:79,482`: the candidate's
  private index covers exact supplied names and counts only Claimed/InProgress.
  Its source scenario in `test/test_dashboard_briefing.ml` already covers
  ownership/status semantics. No additional duplicate semantic test is needed.
- `scripts/harness/perf/server_artifact_session.py:189,210` and
  `compare_server_artifacts.py:53,152`: the existing runner and validator
  explicitly require Todo and zero owned counts. There is no mixed-workload
  CLI option. The retained server logs have no render timing lines.

Line references above refer to the pinned candidate/observer, not future main.
Existing route spans and coarse aggregate observations cannot reconstruct the
missing task-count measurement from the saved run.

## Proposed first mixed workload

Use the same 25 synthetic workers and 816 tasks, payload sizes, timestamps,
ASCII/multilingual and identity/gzip axes, AB/BA/AB ordering and 20 cycles.
This is an explicitly synthetic ownership distribution, not a claim about the
production distribution. Keep the existing all-Todo evidence as its own control;
do not pool it with this new experiment.

For block `b = 0..101`, generate eight tasks with owner
`fixture-worker-{b % 25:04d}`:

| Offset | State | Owner | Expected contribution |
| --- | --- | --- | --- |
| 0 | Todo | absent | 0 |
| 1 | Claimed | exact worker name | 1 |
| 2 | InProgress | exact worker name | 1 |
| 3 | AwaitingVerification | exact worker name | 0 |
| 4 | Done | exact worker name | 0 |
| 5 | Cancelled | exact worker as canceller | 0 |
| 6 | Claimed | `fixture-unlisted` | 0 |
| 7 | InProgress | uppercase worker on even b; worker plus trailing space on odd b | 0 |

Expected initial status totals: Todo 102, Claimed 204, InProgress 204,
AwaitingVerification 102, Done 102, Cancelled 102. Expected active count:
workers 0000 and 0001 each 10; workers 0002..0024 each 8; total 204. Keep the
fixed old presence signals so all 25 attention rows remain observable; explicit
`current_task` remains absent. Their focus and note should reflect owned work,
while state stays quiet. Unlisted/case/space variants must create no extra rows.

Prepare canonical task records and primary/recovery backlog copies while the
owned server is stopped. Use the exact pinned task wire schema and keep required
timestamps, terminal fields and verification intent/binding fields. This seeds
a projection fixture; it does not prove lifecycle transitions or verifier
behavior. Record the full initial fixture and hashes. Startup must preserve it,
and no background verification/model activity may mutate it. If that condition
cannot be met in the existing isolated harness, stop and revise the fixture;
do not weaken the unchanged-state or no-model-call controls.

After startup and priming, retain the existing per-cycle `masc_add_task` Todo
invalidation, cold read, warm read and separate concurrent mutation/liveness
phase. Initial owned counts remain constant, so every rendered response has an
independent expected count. Final task total is 856, with Todo 142 and other
status totals unchanged. Derive revision progression from the actual recorded
seed protocol; the previous batched-MCP seed revision equation no longer applies.
Compare primary/recovery bytes and expected fields as before.

## Required attribution before a new expensive experiment

Prepare one observer change applied symmetrically to both source arms. Review
its two source diffs before creating artifacts:

1. Retain complete per-render phase receipts with a render identifier, worker
   and task counts, status/owner histogram, monotonic wall durations, and the
   execution publication generation linking them to HTTP receipts. Keep the
   existing coarse boundaries, then add the full worker-support construction
   interval and a separately nested task-count interval. The baseline interval
   covers all per-agent scans; the candidate covers map build plus lookups.
   Do not time every task: timer overhead would become part of the comparison.
   Record timer-call counts and calibration: baseline scans are interleaved
   with worker construction, so their intervals are a sum, not one contiguous
   span. This instrumentation changes overhead differently in the two arms;
   use it for attribution and retain the uninstrumented wire evidence separately.
2. Apply the same timer/sink design to both arms, keep functional outputs
   unchanged, and emit evidence after measuring the work. Keep nested spans
   explicit; assembly includes worker support, which includes task counting.
   Preserve failed/partial render receipts and mark them unsuccessful rather
   than dropping them. Do not infer request matching from timestamps alone.
3. Collect server process CPU time at phase boundaries in the Linux observer,
   separately from monotonic wall time. This is whole-process CPU consumption,
   not per-function CPU attribution. Record the clock resolution; coarse process
   accounting can measure a whole 20-cycle phase, not a 0.1 ms operation. Any sampled call-stack profile is a
   separate diagnostic run with its overhead and all samples retained.
4. Extend the runner and independent validator with an explicit mixed profile,
   complete initial fixture receipt, expected per-worker counts and all status
   fields. Retain exact names, row order, focus/note fields, response bytes,
   generation/cache checks, endpoint/tool success, artifact provenance,
   accepted/actual encoding, controlled inputs, model-call rejection and cleanup.
   Continue excluding only the documented clock-derived age in cross-arm worker
   comparisons. Missing receipts invalidate the experiment, not individual rows.
5. Report full per-session distributions and all three paired comparisons for
   wire, compute, worker support and task count. Report CPU separately. Inspect
   the fixed 25/816 cell first. A task-count or worker-count sweep is a separately
   reviewed experiment only if the measured count phase warrants it; select its
   counts before observing results. No repeated identical run seeking a gain.

The fixed 0.1 ms whole-response goal remains unmet and unchanged. This proposal
adds diagnostic evidence; it does not establish readiness, production behavior,
TUI presentation timing or Keeper continuity.
