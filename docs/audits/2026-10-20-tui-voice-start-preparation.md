# Voice preparation without holding the input handler

Related PR: [#44211](https://github.com/jeong-sik/masc/pull/44211).

Source-only change over parent
`0033d6c753f7aa514e543b374c64f330b54e34b0`. Parsing is the only OCaml check;
typing, scenarios, audio/TUI/PTY and actual Before/After are unexecuted.

## As-Is / To-Be

Both continuous-voice key handlers called `measure_noise_floor` before launching
the asynchronous recording. That operation reads capture configuration, records
a room probe for the configured calibration interval and computes its RMS. Even
with the initialized Eio process runner, that handler could not return to its
input loop until the probe returned. The probe also had no occupied session in
the UI while running. Separately, a missing async switch sent `Voice_failed`
without an active capture; the terminal consumer rejected that ownerless result.

Both entry points now request calibration inside the existing asynchronous
voice fiber. One logical microphone session owns its optional probe, recording
and result, retaining the existing occupied slot until terminal settlement. The
switch is checked before admission because Eio fork can skip its callback on a
cancelled switch. Normal missing-switch refusal is reported immediately to the
original Keeper, without creating a fake capture or weakening terminal guards.
Only the current idle draft's refusal clears its continuous mode/floor.

Source-review follow-through: [issuecomment-6288841225](https://github.com/jeong-sik/masc/pull/44211#issuecomment-6288841225)
identified three omissions. The public async protocol interface now declares
the same calibration event and typed meter payload as its implementation. Chat
uses the shared phase presentation whenever an active, non-withdrawn measured
recording does not justify its existing detailed bar. Missing meter data cannot
be labelled listening during preparation, processing or stopping. Immediately
after the probe and calibration notification, the real launcher rechecks the
original continuous-mode owner before entering the recorder. Turning it off
during either wait returns the original silent terminal without starting a
recorder. An already-entered recording retains its existing Keep/Discard policy.
The microphone lifecycle comment is moved onto the launcher it describes.

These repairs receive parsing/source inspection only. The supplied-observation
state scenario below does not cover the real probe/recorder ordering; that P3
integration coverage gap remains explicit. The required unexecuted compound
case holds the real probe, disables continuous mode through each original key
path, releases the probe and verifies original-slot settlement without a later
recorder process. A second case disables an already-entered recording and
preserves its captured speech and normal terminal cleanup. No wording/layout or
helper-mirror test substitutes for those physical protocol observations.

Keep/Discard during the room probe retains occupancy until the probe returns
through its existing cleanup. The worker then returns a silent/discarded outcome
instead of starting a subsequent recorder. Target/browser/workspace withdrawal
uses the existing sticky Discard and A→B→A rejection. Turning continuous mode off
clears its floor; a late calibration cannot restore that mode's floor. An active
worker uses its own captured/measured floor, rather than borrowing later state.

The voice bridge's float callback previously used negative infinity for three
different facts: a measured zero amplitude, an unavailable file reading and a
final meter reset. Its callback now carries `Level_observed`, `Level_unavailable`
or `Meter_closed`. All custom callback callers were inspected; the TUI is the
only one. Default callers and returned tool JSON retain their behavior. Capture
thresholds, durations and decisions still use the bridge's existing typed phase
logic; display observations do not authorize recording or message dispatch.

The UI distinguishes calibration, starting, observed recording, result processing
and stopping. Only a measured reading admits the recording display phase. A
missing reading clears the displayed meter instead of fabricating silence; a
measured zero remains a real reading. Meter closure enters result processing
without releasing the session. Late calibration/levels cannot move processing
or stopping back into recording. Original recipient/withdrawal guards apply to
progress as well as terminal results. Recorder failure appears in the original
chat and footer. These are logical/observed stages, not physical cleanup proof.

## Source Before/After

| Boundary | Before | After |
| --- | --- | --- |
| Continuous-start input handlers awaiting a room probe | Two entry points | Neither waits for probe completion; the voice fiber owns it |
| Microphone ownership during probe | No occupied UI session yet | Same original session retained through terminal result |
| Stop/retarget during preparation | Input handler had not returned | Stop retained; no follow-on recorder after probe return |
| Callback for unreadable input vs measured zero | Same float sentinel | Distinct typed observations |
| Meter reset while result is pending | Same float as silent input | Result-processing observation; slot remains occupied |
| Missing async context | Ownerless terminal failure rejected | Immediate original-Keeper failure; no fake occupied session |

No probe duration, level cadence, mailbox capacity, recording threshold, timeout,
resource limit, retry or environment knob is added. There is one additional
calibration observation for a calibrated session. It uses the existing bounded
mailbox and can wait there before recording; ordinary input/drain scheduling is
unchanged. Eio fiber separation removes a source dependency, not every possible
blocking operation in voice startup. Actual input, paint, audio overlap, memory
and elapsed latency remain unmeasured. No unique per-capture generation or
duplicate same-name terminal protocol is introduced.

## Authored scenario, unexecuted

The existing Work/metadata failure and draft-transfer scenario now crosses probe
withdrawal, late progress, A→B→A, a replacement session's measured/unavailable/closed
meter observations, non-regressing processing/stopping and refusal after terminal
settlement. It retains the original draft and independent Work failure. It uses
production state consumers with supplied protocol observations, without running
the actual launcher, audio process, main async dispatcher or cancellation/cleanup.
No standalone helper-mirror, invocation-count or UI wording/layout/row-order/
snapshot/PTY test is added.

Matched actual Before/After must retain failed, cancelled, interrupted and
unfinished probes/captures, exact owners, mailbox wait and physical resource
observations. These source changes do not complete any of the six original goal
axes or establish useful Task progress, delivered messages or visible paint.
