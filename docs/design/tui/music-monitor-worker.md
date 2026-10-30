# Keyboard monitoring independent of terminal work

The piano-roll input still owns one MIDI source. Its pure projection validates
one packet before the terminal adopts an edit. Only that admitted packet is sent
to the audio owner, and the input acknowledgement awaits its synth render. The
terminal never acknowledges individual device demands.

`step-monitor.mjs` owns the worker and the pending packet/inspection promises.
`step-monitor-worker.mjs` owns `openMonitorSession` from
`step-monitor-session.mjs`; that session owns the existing persistent VST and
PCM companions. Practice backing creates one synth companion per participating
track; ordinary monitoring creates one. Device requests and rendered PCM remain entirely on the worker
loop. There is no speculative audio queue or new scheduling timer.

Normal stop and cancellation interrupt the session's existing producer and join
every owned synth/output child. The worker publishes a terminal report only after that join and
closes its port. The controller waits for the actual worker `exit`, not merely
the terminal message. It does not use `terminate()`, which can interrupt code at
any point. Node documents that all posted worker messages precede `exit`:
https://nodejs.org/api/worker_threads.html#event-exit
https://nodejs.org/api/worker_threads.html#event-message

An unexpected worker exit without a terminal receipt is failure with
unconfirmed native cleanup. The controller does not manufacture a native final
report, closure or success from that exit. This is an evidence boundary, not a
claim that an abruptly terminated worker can attest to its children.

Diagnostics are observations. `diagnostics()` clones the last worker message;
`inspect()` coalesces concurrent requests and returns a fresh worker snapshot.
Active `:step-diagnostics PATH` uses `inspect()`. After retirement the terminal
keeps the final snapshot. `observedAt`, `worker.closed` and `terminalReceived`
identify the observation and the two retirement acknowledgements. Reports omit
preset bytes. Cancellation retains the caller's original cause locally, even
when that cause cannot be structured-cloned; only its cancellation message is
sent to the worker.

The isolation fixes a reproducible terminal-loop starvation boundary. It does
not guarantee plug-in real-time performance or operating-system scheduling, and
does not turn step input into timestamp-preserving recording. The raw recorder
continues to own the original MIDI timestamps and precision.


## Free-play phrase backing

`:practice-input` snapshots the authored phrase and selected track. The same
input owner projects packets for audition but does not call the step-note edit
transaction. Backing uses the ordinary clipped phrase schedule and audibility;
the selected track is excluded. Loop mode selects the source range, while the
resulting range always repeats until stop. Original MIDI-source documents keep
the existing arrangement/raw recording contracts.

`phrase-backing.mjs` maps absolute `(cycle * ticks + event tick)` positions to
output frames using integer arithmetic and nearest rounding. This avoids a
rounded-period drift. An endpoint note-off precedes the next cycle's tick-zero
controls/on. Events exactly at a block end belong to the next block. A positive
note/cycle shorter than one output frame cannot retain its musical duration and
is refused when the output rate is known. VST events use offsets relative to the
current processing block, matching the [VST event contract](https://steinbergmedia.github.io/vst3_doc/vstinterfaces/structSteinberg_1_1Vst_1_1Event.html).

Separate VST processes retain the selected live track and each backing track's
voices/CC state, including plug-ins that treat MIDI channels as omni. They share
the captured preset. Each device demand renders their blocks concurrently and
adds stereo float samples into the one output block; no other audio owner or
wall-clock scheduler opens. This does not turn the chosen VST into independent
GM program sounds. There is no automatic gain or limiter. Peak and samples above
full scale are observations in backing diagnostics; track levels remain explicit.
Startup, error, stop and cancellation retain/join every synth process and the
single output before terminal/exit acknowledgement.
