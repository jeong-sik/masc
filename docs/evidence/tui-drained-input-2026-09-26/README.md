# Present handled input when the terminal queue drains

Base: `08cbfc631b610f130bb9f1d9010e309ff211eeef`.

The scheduler presents handled input immediately when no decoded events,
buffered bytes, probe replay or terminal readiness remain. A recent input frame
no longer forces another 16ms wait. A nonconsuming zero-timeout readiness check
also sees input waiting beyond the current 8192-byte read buffer. A continuously
nonempty queue and background updates retain the existing frame interval.
Force redraws and the event loop's cooperative yield remain in place.

## Tradeoff and verification scope

This deliberately removes the fixed frame-rate ceiling for separately arriving
inputs whose queues drain after every event. Such input can now render more than
63 times per second. CPU cost and end-to-end latency must be compared against the
same base binary on the same runner before calling this a measured improvement.
The historical candidate3 comparison left successive actions near 18ms, but is
not a measurement of this source.

Scheduler cases check successive drained events, continuously pending input,
final drain and return to an idle blocking wait. The readiness PTY suite also
checks a 1000-line paste larger than two input buffers by comparing the complete
submitted HTTP payload. That test proves byte retention across reads; it does
not prove kernel-backlog timing or a frame-rate bound. Existing fragmented UTF-8,
resize, paste and signal-exit cases remain relevant.

EINTR in the readiness probe defers a pending input frame to at most the existing
frame deadline. EOF can also report readable; it is not distinguished here from
queued bytes. The existing reader maps EOF to a timed-out read, so this change
does not repair terminal EOF handling or promise immediate final frames at EOF.

Static formatting, Python syntax and diff checks are the local checks. Behavioral
execution belongs to CI; no local OCaml build. Independent adversarial review
found no new input-loss or ownership defect and identified the limits above.
No production deployment, CPU reduction or 0.1ms achievement is claimed.
