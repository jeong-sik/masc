# Native TUI while 2, 30 and 300 Keeper owners are held

The strict 100 us objective remains unmet. These runs execute real isolated
Keeper owners and the native TUI/server pair from source
`5297349b101d61bb901b3729d43c4dec8bb30ec4` (PR #46913). A local scripted provider
holds actual concurrent HTTP requests, then returns final text. One admin
producer submits two original inputs per Keeper. This is neither external-LLM
latency, real peer-tool/broadcast traffic, production throughput, deep-scroll
acceptance nor physical terminal/flicker proof.

## Identity and execution

The macOS arm64 native pair came from **Minimal manual checks** run
[41011842325](https://github.com/jeong-sik/masc/actions/runs/41011842325), completed
success, workflow ref/main head `f06ab8f4fb3dd2c18e92366922c13a7c73f140f3`,
requested native source `5297349b101d61bb901b3729d43c4dec8bb30ec4`. The downloaded
receipt declares `rich-chat-workspace`; all seven selected suites exited zero.
That is targeted verification, not full regression or installed-runtime proof.
Both binary digests and embedded commits were read back before the runs:

- Server SHA256 `464fc0090639d89b03e85e73435632a9a709506dc139ccdb50f586e8ead0fc2e`.
- TUI SHA256 `e1e41a1ed79de05ba563bb1fd7d517c7578b475c9eaa6a606da28e89028d991d`.

The harness adapter derives from checkout
`fd230b33f1c25b1fb49b6f56f1d03c5876baa423`. Native source, harness source and
workflow source are distinct. The shared installation was separately copied
and self-reported f06; it was not replaced or used as these runs' candidate.
The shared server was not restarted or populated with synthetic Keepers.
This is one pinned-candidate scale observation, **not a before/after comparison**.
A direct-parent native control was separately requested in run
[41014690379](https://github.com/jeong-sik/masc/actions/runs/41014690379), wrapper
main/f06, completed success, source b004188…. Its TUI digest and embedded source
were read back; that artifact contains no server. Its performance has not been
measured; the current observer requires a matching server/TUI source, so that
control alone cannot repeat the same owner runs.

Every run uses its own base/HOME, loopback scripted provider and port, with
provider holds causally enclosing the TUI child lifetime. The renderer is an
actual native PTY process (45 rows × 150 columns), not a physical emulator.
Inputs include Keepers/chat navigation, PgUp/PgDn, `/keeper`, leaving chat and
Tab. Thirteen complete PTY input writes do not establish thirteen applied
commands. Keeper-list/chat frame tags identify the surface built, not the
number of loaded/displayed entries or the cause of a delay.

## Observed outcomes and distributions

All v2 server/TUI children exited zero and were reaped without forced kill.
Provider handlers drained to zero. Raw counts match diagnostic summary counts
and ordinals, without reported cap omissions, malformed records or invalid
native time windows. The 2/30/300 populations have 559/612/690 stage records.
An independent source/data reviewer matched 4/60/600 unique admission, terminal
and offline SQLite outcomes and each Keeper's `[1,2]` provider sequence. This is
an independent read-only assessment, not formal GitHub approval or another live
execution.

| Owners | Durable outcomes | Build / Present frames | List samples | List Build p50 / p95 ms | Chat samples | Chat Build p50 / p95 ms | Released health samples | Released health p95 / max ms |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 2 | 4/4 | 85 / 85 | 10 | 0.275 / 0.401 | 42 | 0.219 / 0.697 | 5 | 5.126 / 5.126 |
| 30 | 60/60 | 93 / 93 | 10 | 0.954 / 4.403 | 44 | 0.276 / 0.492 | 43 | 13.018 / 49.738 |
| 300 | 600/600 | 109 / 109 | 14 | 4.800 / 5.608 | 58 | 0.253 / 0.579 | 642 | 47.815 / 8269.019 |

Native frame/stage percentiles use the native round-index rule; the workload's
health phase summary uses nearest rank. These are small observed cohorts, not
stable production tail estimates. All phases/frames remain in the raw data.
In particular, the 300-owner list's 14 samples do not prove a general p95 or
that Keeper count alone caused the difference. The source already limits its
visible entry window; repeated fleet-wide reading/model preparation is a next
profiling candidate, not a demonstrated causal repair.

The 30-owner worst Present was 13.863 ms: write 0.0014 ms, flush 0.0198 ms and
about 13.842 ms elsewhere in Present. The 300-owner worst Present was 1.351 ms,
mostly flush (1.339 ms). These differing outliers cannot be assigned uniformly
to I/O, GC, scheduling or one renderer function. PTY/observer overhead and a
shared, unquiesced host remain part of the observation.

The 2/30/300 runs recorded 0/2/33 HTTP 429 responses and 0/2.008/33.089 seconds of
client fallback waits. The limiter was not disabled. All 118/187/1269 health
samples succeeded, but low liveness-query latency is not durable operation,
peer, Add-on or TUI input latency. The 300 run refused 991 recognized inventory
wrapper invocations (30: 2); wrapper/process costs remain, and no causal
attribution to the 8.269-second outlier is established. No guest tool executed.
The complete original SQLite/WAL snapshots remain under ignored run output.

## Clocks, overlap and a measurement defect found

Native records use **TUI-process-relative `Mtime_clock.elapsed_ns`**. Observer,
workload events and health requests use Python `perf_counter_ns`. These numeric
origins are not joined. The sequential owner hook proves that the TUI lifetime
ended before provider release; it does not correlate one key with one native
frame. `analysis.json` compares only same-Python-clock health request intervals
with the conservative fork-to-reap child envelope.

Health requests wholly inside that envelope numbered 66/67/66. Their observed
wire p95 values were 2.211/2.169/7.968 ms. These are temporal overlap cohorts,
not measurements of TUI-caused server overhead. The broad model-held phase also
includes binary copying, identity reads and queue validation outside the child.
Released-phase queries occur after actual provider replies began and after the
TUI child has stopped, so their long tails are not a claim about simultaneous
UI activity.

Recorded stages overlap inside 50/51/61 Build frames; every recorded interval
is contained in its matching native Build. For example `overview.rows` is
inside `surface.content`. The measured source's `Stage_samples.residual_lines`
subtracts their simple sum and clamps to zero, although its interface asks
callers to keep stages disjoint. That can understate unmeasured wall time.
**Do not use those native `unattributed` lines as a disjoint decomposition.**
The analyzer independently unions recorded intervals per Build before
subtraction. Its `uncovered_build_wall` means only Build wall not covered by
those timers, including observation overhead, scheduling/GC and uninstrumented
work. It is not a function cost or exclusive CPU attribution. Product diagnostic
repair and narrower critical-path profiling remain follow-up work.

## Observer corrections and retained negatives

The earlier v1 observer is retained separately with its actual two-owner
capture. It inherited parent environment/cwd for the information query,
allowed proxy-aware health and did not block TUI replacement-server discovery;
it also counted lone DEC 2026 end controls as frames. Its post-hoc control
readback finds 56 paired blocks and two unpaired ends. Native phase records are
kept, but v1 is not used as v2 isolation/capture qualification.

V2 queries information with the dedicated env/cwd, uses direct HTTPConnection,
and places an exit-126 recording `masc` shim both beside the TUI and on its
PATH. Actual replacement-server execution is blocked by those discovery paths.
The log is only a read-time lower bound: an empty list does **not** prove that
no detached shim attempt existed or that every delayed shim has settled.
Capture qualification does not certify either claim.

V2 pairs begin/end transport controls, records unmatched resets separately,
rejects a partial input write without replay, drains PTY output to EOF after
reaping, and checks native frame/stage counts and both plain/JSON omission
formats. Workload success and `capture_qualified` are separate. The latter is
only a native phase/transport-capture verdict, never input acknowledgement,
physical paint, deep scrolling, all stage coverage or target completion.

## Retention and reproduction

`provenance.json` maps exact selected capture bytes to original paths/hashes.
Host paths are deliberate capture-time addresses. Synthetic inputs are included
in admission records and completed replies in terminal records. Selected SQLite
snapshot fields retain source metadata, operation status and digests; their final
input fields are null and they do not retain replies. Observer records include
synthetic PTY input bytes;
latency samples retain health response bodies. Original configurations, full
HTTP/model request bodies and traces, raw terminal output streams, native
executables and complete SQLite/WAL packets remain outside Git. Reproduction requires Python 3.11 or later and a checkout containing the same
release fixture. Reproduction sources write a new run;
do not overwrite retained captures or reuse historical digests as a new receipt.

```sh
python3 docs/evidence/extreme-performance-20261030/native-tui-owners/probe-v2/keeper_scale_session.py \
  --binary "$PINNED_SERVER" --tui-binary "$PINNED_TUI" --repo "$CHECKOUT" \
  --output "$NEW_IGNORED_OUTPUT" --keepers 300 --messages-per-keeper 2
python3 docs/evidence/extreme-performance-20261030/native-tui-owners/analyze-owned-runs.py \
  "$NEW_IGNORED_OUTPUT"
```

Next work must preserve the full objective: actual input/state/scroll evidence,
long histories, CPU/allocation attribution, fleet reading/model joins, the server
release tail, file/SQLite/Markdown/HTML paths, real peer/broadcast and concurrent
Add-on lanes, DAW/audio timing and physical flicker. No whole-goal completion,
deployment or real-display claim follows from this bundle.
