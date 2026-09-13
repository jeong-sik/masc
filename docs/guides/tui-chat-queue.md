# Controlling a Keeper conversation

The chat footer identifies the current direct or autonomous turn and the age of
its last observed activity. A status such as `receiving response` describes that
observation; it does not prove the provider is still producing output.

While a turn is active, `Esc` requests that exact turn to stop and pauses admission
of queued messages and autonomous work. A stop request is acknowledged separately
from the turn actually ending. Repeated keys cannot stop an unseen successor.

Press Enter to send an update during a running conversation. The server accepts
it and applies the observed interruption in one command; no `/run-next` is
required. Compatible waiting inputs are grouped in their accepted order. A pause
caused by chat interruption can be resumed by a later message that observed that
pause; a separate manual pause remains in effect.

If another stop or resume happened after the input was sent, the message remains
queued and the newer control takes precedence. The TUI reports this explicitly.
Reconnecting to an accepted message does not repeat interruption or resume it.
`/run-next` remains an explicit priority control for previously queued messages.

`/queue` shows a snapshot of local unsent messages, server queued messages with
their sender and contents, and other waiting work. Event rows may represent
groups; the group count is not a total message count. Run `/queue` again to refresh.

| Command | Effect |
| --- | --- |
| `/queue pause` | Pause new work; the current turn can finish. |
| `/queue resume` | Resume queue consumption. |
| `/queue edit ID message` | Replace queued text while retaining attachments. |
| `/queue cancel ID` | Cancel a waiting message. |
| `/queue last ID` | Move a waiting message to the end of its queue. |
| `/queue cancel-event REF INCARNATION reason` | Cancel the exact event shown. |
| `/queue priority-event REF INCARNATION urgency` | Change that event's priority. |

Copy message IDs and event references from `/queue`. An event reference identifies
the displayed event, not every event in its group. Already running or changed
items can be refused; the TUI reports the server's result before refreshing the
snapshot. Local messages have not reached the server yet and are lost if the TUI
exits before submitting them.
