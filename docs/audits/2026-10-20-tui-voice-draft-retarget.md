# Voice withdrawal across draft target changes

Related PR: [#44186](https://github.com/jeong-sik/masc/pull/44186).

Source change only. Parent head: `79650d2d21d438fde6e2d39570a5b0b22a65178e`.
No typing, test execution, audio/TUI/PTY, actual send, install or runtime
Before/After was performed. Parsing does not prove behavior.

## As-Is / To-Be

The key path already bound actions to the original draft name. The asynchronous
voice path was separate: `open_message_for_keeper` saved/restored text drafts and
assigned the new name without withdrawing an active recording. A returned voice
event only needed to match `voice_capture`; its transcript could then append to
the current target's draft and invoke the existing send-on-stop path.

All three post-construction target writers now use `retarget_message`. A changed
name applies the existing browser/workspace withdrawal policy before assignment:
stop continuous mode, clear its calibration/meter, request Discard for an occupied
capture and retain its withdrawn latch until terminal settlement. Reopening the
same target preserves its valid capture. Existing text draft save/restore remains.
Unapplied recording/transcription is discarded on target transfer; it is not
saved as another Keeper's message. The row exposes the original occupied capture's
withdrawn/awaiting-terminal state instead of announcing new recording.

`settle_voice_capture` also checks the current bound draft before admitting a
matching completion. A different active capture is rejected before any mutation.
Existing terminal consumers already ignore withdrawn results, so they cannot
append text, restart continuous recording, publish a voice notice or auto-send it.
Workspace clear/preserved-chat restoration use the same centralized transfer
without relaxing their earlier independent workspace withdrawal.

| Case | Before in source | After in source |
| --- | --- | --- |
| Pending A capture, open B | B becomes current without voice withdrawal | A receives Discard; B text stays separate; A remains occupied until settlement |
| A→B→A before completion | Matching name can admit the old transcript | Withdrawn latch survives the return and a later Keep request |
| Late A event while B capture is active | Different-name guard already rejects it | Same guard protects B before target-admission checks |
| Same-target re-entry | Existing capture continues | Existing capture continues |
| New draft while old capture retires | Voice label can imply recording for that draft | Label reflects the old capture's actual pending withdrawal |

This adds a constant-time name comparison and existing withdrawal work on a
changed target. There is no new worker, timer, request, deadline, concurrency
limit or retry. Logical slot settlement retains the existing boundary; it does
not establish physical microphone/executor quiescence. No unique per-capture
generation or duplicate same-name terminal-event protocol is introduced here.

## Authored protocol coverage, unexecuted

The existing independent Work/metadata scenario now crosses owned metadata
failure/recovery and draft-recipient restoration into the production target
transfer, voice settlement and key classifier. It keeps A occupied while B can
own its text, returns A before the old result, attempts Keep after Discard, and
requires a withdrawn settlement with the original text retained. A later B
capture rejects a different-name late A event and settles only on B's result.
Work's failure remains independent. The fixture supplies restored draft text;
it does not execute `open_message_for_keeper`, audio, the main event loop or HTTP
dispatch. Existing browser/workspace voice fixtures gain their explicit bound
name. No display/layout/row-order/snapshot/PTY/helper-mirror/count test is added.

## Before/After evidence limits

The three producers now share one transfer policy and direct field writer.
That is source coverage, not an input-latency or allocation measurement. Actual
matched recordings must retain target changes, withdrawn/cancelled/unfinished
captures, exact draft/request ownership, resources and source outcomes. A label,
Discard request or ignored callback is not proof of physical cleanup, paint,
successful delivery or useful Task work. All six original goal axes and the
actual matched Before/After remain open.
