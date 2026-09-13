# Controlling a Keeper conversation

The chat footer identifies the current direct or autonomous turn and the age of
its last observed activity. A status such as `receiving response` describes that
observation; it does not prove the provider is still producing output.

While a turn is active, `Esc` requests that exact turn to stop and pauses admission
of queued messages and autonomous work. A stop request is acknowledged separately
from the turn actually ending. Repeated keys cannot stop an unseen successor.

Use `/run-next` to put your waiting message first and stop the observed turn. It
also admits a message still waiting in the local TUI before asking the server to
prioritize it. This resumes a pause caused by chat interruption; a separate manual
pause remains in effect. `/steer message` submits a correction using the same path.

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
