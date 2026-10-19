# Observe probe capture and first input without promoting them to completion

Source comparison base: `1622f23bd94b31b95740b3af1e6999405df0ec38` (#43797).
Source/observation contracts only; no native timing or input/paint measurement.

## As-Is / To-Be

The prior source hands decided replay out of the startup wait and retains late
capability replies. However, capture's real start, byte count and exit branch
were local variables. The function returned an unused copied replay snapshot.
Existing frame timing reports build/present work, not the probe's lifecycle or
delivery of an early key to the loop.

Each capture now owns immutable typed facts behind its own atomic cell. Its
worker closure records only that capture, and installed-input observations find
the capture by its actual decoder object. A different reader/capture cannot
borrow those observations merely because it is now current. CAS updates retain
independent caller and capture outcomes, including a late capture result after
caller interruption. Timing never controls an input, effect or admission.

| Source boundary | Before | After |
| --- | --- | --- |
| Typed probe/first-input lifecycle event kinds | 0 at this boundary | 8, plus an exit snapshot |
| Probe dispatch and worker entry | No dedicated receipt | Separate actual monotonic observations |
| Capture end reason | Local loop condition | Input/replies ready, explicit deadline branch, no-byte read or existing cap |
| No-byte read | No lifecycle evidence | Same observed no-byte fact; no guessed EOF/timeout |
| Caller interruption followed by late capture | No combined typed view | Original caller and capture facts both retained |
| Decoder installation and capability application | No lifecycle timestamps | Separate actual callback boundaries |
| First decoded input and main-loop reception | No probe-linked receipt | Separate first observations, without input content |
| Missing phase at exit | Unavailable to this boundary | Null/unobserved in an original-capture snapshot |
| Returned unused replay snapshot | Copied by capture return | Removed; returns the original decoder |
| Native latency/paint/useful work | Unmeasured for this comparison | Unmeasured |

These count source event kinds, not executed events or timing gains. Captures
may never see some phases: replies may be absent, a caller may stop, or a person
may exit without sending input. The existing no-input capture deadline and byte
cap remain. The loop's exit-precedence and original input byte ownership remain;
the diagnostic does not add a wait, retry, reader or timer.

## Meaning of the timestamps

Dispatch is entry to this probe call, after earlier TUI setup. Worker entry is
the actual system-thread body entry. Capture end is the read procedure's actual
return/failure boundary before diagnostic logging, not thread cleanup or
resource quiescence. Caller observation is the synchronous wait returning or
raising. Decoder installation records the actual installed decoder; additional
main setup can still precede the input loop.

Capability application follows the actual palette/theme, image/portrait/MSX
updates and repaint request. It is not terminal output. First decoded input
follows a real reader decode, and main reception follows that reader's return.
Graphics replies are excluded. Synthetic paste recovery bypasses this new-read
boundary. Later gestures do not replace the original first-input pair. These
observations do not prove acceptance, command execution, server readiness,
Keeper progress, usable input or physical paint.

All source clocks use `Mtime_clock.elapsed_ns` within the same process. The
records derive dispatch-to-worker/caller/decoder/input intervals, capture
elapsed time and decoded-to-received delivery time only when their endpoints
exist. Capture-to-caller is absent for caller failure, including failure before
the capture returns. Intervals include scheduling and observation overhead;
they are not pure CPU or terminal transport durations. Existing frame/present
timing is retained separately. PID and dispatch time provide diagnostic
correlation; immutable owner/decoder objects retain in-process attribution.

## Failure, privacy and cost

Facts are stored before the log sink runs. Non-cancellation diagnostic sink
errors cannot discard a decoded input. Real Eio cancellation propagates;
exception-path observations use the existing cancellation protection boundary
and rethrow the original operation exception/backtrace. Failed captures retain
their actual consumed byte count without serializing exception text. A later
worker result cannot overwrite caller interruption or fabricate installation,
input or paint. Exit snapshots read each original capture once. Missing fields
remain unobserved; neither caller interruption nor process exit proves a worker
stopped. Abrupt process loss may leave only the earlier event records.

Records contain kind/availability, counts, process identity and timestamps, not
key/paste contents, raw terminal replies/refusal text, credentials or paths.
Capability state keeps the latest applied observation; earlier emitted records
remain separate. After the first input pair, the hot path checks those existing
facts before taking another diagnostic clock reading. No parallel completion
queue or replacement authority is introduced.

There is added atomic/logging work, a retained per-capture record, and an exit
snapshot. Capture elapsed can include the worker-entry log; decoded-to-received
can include the decoded-input log. Net CPU, memory and latency cost remains
unmeasured. Diagnostic storage failure is not successful observation delivery.

## Authored evidence and limits

Three new compound cases are authored but unexecuted: caller interruption plus
a later real input-ready capture observation; failed and never-observed capture
samples without fabricated input; and early input delivery followed by actual
late palette/graphics/geometry, preserving the original capture snapshot and
first-input pair. They use the typed lifecycle core and actual protocol
producer; they do not run real stdin, native startup or prove logging delivery.
The earlier protocol/reader ownership cases remain unexecuted for this head.

Parser and diff/changelog checks do not prove typing, assertions, independent
approval, merge, installed behavior, key response or paint. No Dune, local tests,
CI, native/model run, installation or restart is performed. Later matched
Before/After must use the same task, terminal behavior and input/reply sequence,
retain failed/interrupted/unobserved attempts, and join probe observations with
actual input decisions and existing frame evidence without promoting one layer
to another.
