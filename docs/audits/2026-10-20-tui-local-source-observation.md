# Local Work and required-metadata observation

Related PR: [#44143](https://github.com/jeong-sik/masc/pull/44143).

Source implementation only. The authored resource scenario is unexecuted.
No typing, Dune build, test, CI, TUI/PTY, install, restart or live measurement
was performed for this change.

## As-Is / To-Be

| Boundary | Before | After in source |
| --- | --- | --- |
| Original read | Source/request start, caller settlement and cancellation-request logs | Independent capture for the original source, intent, request, demand revision, workspace revision/fingerprint and process |
| Actual I/O | Generic pool telemetry; source launcher has no worker facts | Submission, actual closure entry/body return and submission-caller observation under the same capture |
| Task comparison | Immediate/CPU planner; generic named switch span | Actual Immediate/Compare decision and, only on Compare, separate CPU submission/worker/caller facts |
| UI | Result received/failed/discarded at admission | Admission/rejection and actual state application are distinct facts |
| Withdrawal | Original cancellation owners and registry | First retirement, cancellation request and actual registry release remain distinct |
| Pending display | Unobserved/failed/last observed data | Work and Keeper lists also show the current source's observed read stage |

The independent source orders, metadata lock, Work lock, followup coalescing,
workspace/base/request checks and shared-pool policy stay authoritative. The
observer supplies no read freshness, effect permission or scheduling decision.
Work does not wait for metadata preparation; metadata has no Task comparison.
The Immediate fact makes no assertion that a prior successful snapshot exists.
A cold or empty read is also immediate under the existing planner.

## Captures and boundaries

`Masc_tui_local_read_observation` owns immutable identity plus atomic first facts.
The request owns the capture across actual I/O, caller-side planning, optional
shared CPU comparison, delivery and UI application. One current capture per
source supports display; old workers retain their original capture after that
slot is replaced or invalidated. No Task data, context, paths, exception detail,
new global cache, timer, timeout or concurrency limit is added to this observer.

The existing Transport routine sink receives `tui_local_read` changed-fact records
using schema `masc.tui-local-read-observation/v2`. Its `requested` record carries
the original identity even if no switch starts the caller. Later records carry
capture ID, phase, monotonic time and only that fact's outcome/context/decision.
No complete snapshot is re-serialized for each event. Facts are committed before
emission. Repeated observations retain the first fact. Sink failure does not
classify the read. The local cancellation promise is resolved in a finally clause
even if diagnostic emission raises.

Detailed logging follows the existing routine level and Transport threshold.
With their defaults (routine Debug, global Info, no module override), no new
`tui_local_read` records are emitted. `Log.Transport.routine_lazy` also skips JSON
serialization, redaction and sink writes when suppressed. Atomic facts and current
pending rows remain available. Existing source start/settled/failure logs are
unchanged. Setting the existing `MASC_LOG_ROUTINE_LEVEL=info` permits detailed
recording under default thresholds; a debug Transport threshold also admits the
default Debug routine level. This change adds no configuration knob or sampling.
No live environment or logging setting was changed. A recording made without
these details has unavailable internal phases, never measured zero phases.

The typed fixed fact slots support concurrent first observations and source
pending projection without retaining a growing event list or deriving truth from
sink delivery order. These distinctions are required by the actual list consumers:
queued I/O, entered worker, body return, caller preparation, optional comparison
and UI wait. `compare_tasks` names the chosen CPU operation without shadowing
`Stdlib.compare`.

I/O closure return means the local loader body returned, possibly with existing
partial-source error fields. It does not assert a healthy snapshot or physical
executor quiescence. The I/O body includes loader/cache-lock work. CPU body return
means the chosen comparison returned. Submission-caller observation and whole
pipeline-caller observation are separate. UI admission may reject a returned
result. UI application is recorded after the existing apply function succeeds;
an apply exception remains a failure and keeps its original backtrace. An admitted
read failure records application only after the source failure state is stored.
Registry release observes removal of the original workspace job registration,
not paint, usable input, successful Task work or a new physical-cleanup protocol.

Only `Local_read_order.in_flight` selects a pending row, and only that source's
current atomic facts select its stage. The row keeps last data and error rows.
It adds no refresh, hides no source failure, and cannot enable/disable input.
Keeper chrome counts the row before calculating its remaining viewport budget.

## Meaningful resource scenario, authored only

The existing first-loss Composition scenario in `test/test_h2_journal.ml` already
uses the original durable Task/run, real backlog writes, original Task document
owners and an independently corrupted/restored Goal-link registry. Its actual
local reads now compose the production observer's I/O/preparation/apply adapters.
The added segment retains a real Work result across read withdrawal, starts
replacement Work and required-metadata requests, rejects the old result without
settling either replacement, and applies real metadata while Work stays pending.
Only the replacement Work result can record its own application. Assertions inspect
stored source ownership and decisions; no text, layout, row order, snapshot, PTY,
helper-mirror or invocation-count test is added. This does not execute the full
TUI launcher or establish physical worker cancellation/cleanup behavior.

## Static log accounting after review

The source defaults to `--refresh 2`. Each due tick attempts the two independent
reads; in-flight reads coalesce, and refresh/followup may add other attempts.
Info passes the default Transport/global threshold. The TUI redirects its console
mirror to `<base-path>/.masc/logs/masc-tui-<pid>.log`; it does not initialize a Ring
JSONL file sink here. The console mirror may drop lines under backpressure.
If another caller initializes the Ring file sink, enabled messages also reach
its JSONL file. These are source contracts, not a live sink/configuration audit.

For a static accounting example, use 5-digit PID/request/demand/workspace/capture
sequence numbers, a UUID capture prefix, 16-digit monotonic times and a 64-hex
workspace fingerprint. Include the timestamp/Info/Transport console prefix,
`tui_local_read=` and newline. Count successful shared-worker paths plus the later
replacement of the completed capture. These are byte calculations from the JSON
shape; they do not execute the observer, loader, TUI or a measurement collector.
The old range repeats respectively the empty and fully populated successful
snapshot for every phase; it bounds this example, not arbitrary inputs.

| Path | Preserved events | Previous bytes/read, envelope | v2 bytes/read when enabled | v2 default emitted bytes/read |
| --- | ---: | ---: | ---: | ---: |
| Keeper metadata | 11 | 9,573–13,445 | 2,722 | 0 |
| Work, Immediate | 12 | 10,411–15,163 | 2,960 | 0 |
| Work, Compare | 16 | 13,940–22,692 | 3,948 | 0 |

At one completed read per source per two seconds, each source starts 43,200/day.
The formula is `(metadata bytes + Work bytes) × 43,200`: old example envelopes
are 863–1,236 MB/day for Immediate Work or 1,016–1,561 MB/day for Compare Work;
enabled v2 details are 245 MB/day or 288 MB/day. Thus enabled detail bytes fall
about 72–83% within this example, while the default adds zero detail log lines.
This is not total disk usage or a runtime speedup. It excludes existing launcher
logs, JSONL framing, other diagnostics, errors, manual refresh/followup and sink
losses. Variable widths and actual starts alter totals. Atomic/record allocations
still cost work even with logging suppressed.

## Before/After measurement contract

No measured speedup, percentile, memory improvement, input or paint result is
claimed. The source change adds attribution and display coverage; it also adds
atomic updates, bounded fact-record allocation, fingerprint/identity creation and
structured logging. Include those costs in any actual matched comparison.

Use one sample per original capture, not one per event. Retain not-started,
failed, interrupted, retired, rejected, unfinished and missing-stage captures in
the cohort. Within a capture/process, submission-to-entry measures the observed
handoff; entry-to-body-return measures that body; body-return-to-submission-caller
and pipeline-caller-to-UI-application are different waits. Null is unavailable,
never zero, and registration release is not a substitute endpoint. Log delivery
order may differ across domains; join v2 facts by capture and phase, not arrival
order. An orphan event or missing required endpoint is unavailable/incomplete,
never another successful sample. Do not subtract
monotonic times across processes or combine unrelated captures with equal numeric
request IDs. Before builds without this schema have unavailable internal phases;
measure both builds with equivalent independently captured boundaries before
claiming a latency change. Match workspace/population, cache state, intent,
resources, terminal conditions and included outcomes.

The current consumers are the Work/Keeper pending rows, not a measured latency
report. A matched recording with required endpoints is the prerequisite for a
later numeric Before/After claim. Until such a run is authorized, retain the
source observation and show its limits; do not claim a measurement verdict.

All six original goal axes remain open: Ask-to-original-Task/useful-work continuity,
exact preparation/frozen discovery, ordinary/nested/dynamic/effectful Composition,
held-job/shared-backend recovery, usable startup/readability/observability and
actual matched Before/After cohorts. This source unit does not complete the goal.
