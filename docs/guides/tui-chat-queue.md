# Controlling a Keeper conversation

The chat footer identifies the current direct or autonomous turn and the age of
its last observed activity. A status such as `receiving response` describes that
observation; it does not prove the provider is still producing output.

While a turn is active, `Esc` requests that exact turn to stop and pauses admission
of queued messages and autonomous work. A stop request is acknowledged separately
from the turn actually ending. Repeated keys cannot stop an unseen successor.

Press Enter to send an update during a running conversation. Ordinary sends
reach server admission in local queue order without stopping the running turn.
Each Enter keeps its own message identity. Compatible waiting inputs may share one execution in their
accepted order. `/priority on` opts into automatically moving new messages ahead
of ordinary queued work while keeping their Enter order; `/run-next` moves a
previously queued message explicitly to the front. A stop can retain earlier local messages for an explicit operator decision, so those
held messages do not block newer sends automatically. A separate manual pause
remains in effect until it is resumed explicitly.

If another stop or resume happened after the input was sent, the message remains
queued and the newer control takes precedence. The TUI reports this explicitly.
Reconnecting to an accepted message does not repeat interruption or resume it.

`/queue` shows a snapshot of local unsent messages, server queued messages with
their sender and contents, and other waiting work. Event rows may represent
groups; the group count is not a total message count. Run `/queue` again to refresh.

| Command | Effect |
| --- | --- |
| `/queue pause` | Pause new work; the current turn can finish. |
| `/queue resume` | Resume queue consumption. |
| `/queue clear` | Cancel the waiting messages this TUI is tracking for this Keeper. |
| `/queue edit ID message` | Replace queued text while retaining attachments. |
| `/queue cancel ID` | Cancel a waiting message. |
| `/queue last ID` | Move a waiting message to the end of its queue. |
| `/queue cancel-event REF INCARNATION reason` | Cancel the exact event shown. |
| `/queue priority-event REF INCARNATION urgency` | Change that event's priority. |

`Esc` stops a turn; it does not remove waiting messages. `/queue clear` removes
the ones this TUI is tracking for the Keeper on screen, by where each one stands:

| Where the message stands | What `/queue clear` does |
| --- | --- |
| In the local queue | Drops it at once. |
| Handed over for sending, first POST not started, never answered by the server | Takes it back; it is not sent. |
| Answered by the server as queued | Sends one cancel request for it, whatever the TUI is doing with it now. |
| Being posted, or its delivery being rechecked (with no answer from the server, or after the server answered that it already ended) | Leaves it; what the server holds is not known, or the operation has already ended and has nothing left to cancel. |
| Answered by the server as started | Leaves it; `Esc` stops a started turn. |

A dropped or taken-back message is discarded with its attachments. It does not
return to the composer.

The local part needs no server and happens first. The command then prints one
row of counts: unsent messages cancelled, messages in the server queue, and
messages left waiting. The cancel requests go out with the queue request that
follows. That request is refused when the workspace identity is unconfirmed or
another queue request is pending, and it can fail before it sends anything. In
each case the TUI prints why, sends no cancel, and the messages counted as in
the server queue stay there.

When the request runs, each cancel is answered by ID: `confirmed`, `not
confirmed` (the server refused, or no answer arrived), or `not sent` (the
workspace changed while the request was running). The snapshot after them lists
what is still waiting. Until the TUI hears that a cancelled message has settled
it still counts that message as in the server queue, so a second `/queue clear`
in that window asks again and is answered `not confirmed`.

A message this TUI is not tracking is not touched: one sent before the TUI was
restarted or the workspace was reconnected, and one another sender queued. Those
stay listed in `/queue`, and `/queue cancel ID` removes one.

Copy message IDs and event references from `/queue`. An event reference identifies
the displayed event, not every event in its group. Already running or changed
items can be refused; the TUI reports the server's result before refreshing the
snapshot. Local messages have not reached the server yet and are lost if the TUI
exits before submitting them.

Keeper chat also shows a separate `NATIVE TASKS` section when native-task
observations or read failures are available. Reported status and terminal
notices remain visible after the root turn ends; they do not establish that a
provider process is still live. Registration alone reports no running status.
Task reads follow chat refresh even while reading older rows. Ctrl-D expands
original execution and receiver details. Task usage is provider-reported and
does not add to root model usage. Unavailable reads retain earlier observations
with an explicit failure. Providers without observations receive no synthetic
tasks or completion states.
