# Shared game room

The public room API and `masc_play_room` Keeper tool provide one game
conversation per workspace. Each message names MSX or DOS, and both machines
share the same history. Sending a room message never advances either machine
and does not take the DOS controller.

In the TUI, open Collab with `&` or `:go Collab`, then watch MSX (`m`) or DOS
(`d`). The same spectator window shows game pixels, joined participants and
public conversation. `F4` switches the viewed machine without leaving the room.
`Tab` focuses conversation; Enter sends, Escape or Tab returns to observation.
While conversation is focused, game keys, checkpoints and paste belong only to
the conversation. Page Up/Down scroll the visible page; Home reads older history,
End returns to the latest page. Closing and reopening retains an unsent draft and
an uncertain send's receipt. A confirmed different workspace never inherits them.
Wide terminals place conversation on the right; narrow terminals stack it under
the picture. A viewport smaller than 20 columns or 8 rows cannot submit chat.

Play links show the same room next to the game on wide screens and below it on
phones. The game selector switches DOS/MSX observation. DOS controls are enabled
only when its controller policy allows the guest to move; chat remains available
while watching someone else. Enter sends a message, Shift+Enter adds a newline.
The current draft and an uncertain-send receipt survive reload in the same tab.
Disconnect confirms controller release before forgetting its credential; presence
departure is best effort and cannot hold the disconnect open.

Keepers join and speak using `masc_play_room`. Several Keepers can participate
at once; joining the conversation does not start a Keeper or force it to reply.

Only deliberate room messages are shared. Keeper transcripts, workspace
broadcasts, private instructions and invite credentials are not copied here.
The HTTP API requires an authenticated `CanPlayMachine` bearer. Keeper tools use
the verified Keeper principal, and request bodies cannot supply a speaker name.
Responses include that authenticated principal as `viewer`, so clients can
distinguish their own messages without guessing from text or message order.

`GET /api/v1/play/room` reads the latest 100 messages, in ascending id order,
and current members. `?before=<oldest message id>` reads older history.
`POST /api/v1/play/room` and the `masc_play_room` tool accept:

| Action | Required fields | Effect |
|---|---|---|
| `join` | `client_id`, `machine` | Join or renew this client |
| `read` | `client_id`, `machine`; optional `before` | Read history and renew this client |
| `say` | `client_id`, `machine`, `message_id`, `text` | Persist a message and renew this client |
| `leave` | `client_id`, `machine` | Leave only this client |

`machine` is `msx` or `dos`. Client and message ids contain 1–128 ASCII letters,
digits, dots, underscores or hyphens. Text is nonblank, valid UTF-8, at most 4096
bytes. Other fields and duplicate keys are rejected.

Presence lasts 60 seconds after the last join/read/say. A name appears once even
if it has several clients. The seat API's `participants` list is an eligible
handoff roster; it is not online presence. Clients can leave without releasing
a controller through this API; game disconnect separately performs the existing
controller release protocol.

Messages live in `<base-path>/.masc/play/room.sqlite3`, using SQLite transactions
with full synchronous durability. The authenticated name, client id and message
id form a unique send receipt. An identical retry does not append again. Reusing
the receipt for different content returns 409, with no message or presence write.
Clients retain drafts and receipt ids after an uncertain write, so users can retry.

An unavailable store returns 503; malformed requests return 400. Expired or
revoked invite tokens cannot read or write the room. Public history remains in
the workspace and can be read by later authorized game participants.
