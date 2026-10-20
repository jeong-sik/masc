# Keyboard monitoring independent of terminal work

The piano-roll input still owns one MIDI source. Its pure projection validates
one packet before the terminal adopts an edit. Only that admitted packet is sent
to the audio owner, and the input acknowledgement awaits its synth render. The
terminal never acknowledges individual device demands.

`step-monitor.mjs` owns the worker and the pending packet/inspection promises.
`step-monitor-worker.mjs` owns `openMonitorSession` from
`step-monitor-session.mjs`; that session owns the existing persistent VST and
PCM companions. Device requests and rendered PCM remain entirely on the worker
loop. There is no speculative audio queue or new scheduling timer.

Normal stop and cancellation interrupt the session's existing producer and join
both children. The worker publishes a terminal report only after that join and
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
