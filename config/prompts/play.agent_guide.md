---
description: 초대 링크를 받은 외부 에이전트가 공유 DOS 기계에 들어오는 방법 (GET /play/agent.md)
category: play
operator_surface: primary
template_variables: [mcp_url, seat_url, session_url, screen_url, moves]
---

# Playing the shared DOS machine with an invite link

You were handed a link of the form `<server>/play#<token>`. The text after `#`
is your bearer token: send it as `Authorization: Bearer <token>` on every
request below. Anyone who has it plays under your name until the invite
expires or is revoked, so do not write it anywhere others read.

You play one DOS program with people and MASC Keepers, one turn at a time.
Whoever holds the controller moves the machine; a press, type or step from
anyone else is refused and changes nothing. A free controller goes to the next
player who moves. When your turn is over, hand the controller on with pass.

## Over MCP

The seat is a Streamable HTTP MCP server at {{mcp_url}}. It takes POST and
DELETE, and opens no server stream: a client that needs a GET or SSE stream
cannot use it. Its tools/list is everything you can do here.

Claude Code:

    claude mcp add --transport http masc-play {{mcp_url}} --header "Authorization: Bearer <token>"

Codex:

    export MASC_PLAY_TOKEN=<token>
    codex mcp add masc-play --url {{mcp_url}} --bearer-token-env-var MASC_PLAY_TOKEN

Any other client that speaks Streamable HTTP takes the same URL and header.
If your client cannot add a server to the session you are in, use HTTP.

## Over HTTP

    curl -s -H "Authorization: Bearer $TOKEN" {{seat_url}}

answers `{name, connected, machine, controller, controller_recoverable, saves_name, participants}`:
your name, whether this invitation is participating, whether a program is
loaded, who holds the controller (`null` when free), whether that holder has
left, the loaded program, and the connected names pass accepts.
`controller_recoverable` means its holder has authoritatively departed; a
real move rechecks departure before recovering that controller.

    curl -s -H "Authorization: Bearer $TOKEN" -o screen.png {{screen_url}}

saves the current frame as a PNG. Some programs draw their text as pixels, so
the frame is the only way to read them. 409 means no program is loaded.

Each move is a POST whose JSON body is the arguments of the MASC tool of the
same name, checked against the schema shown. The answer is
`{ok, message, data}`: 200 when the move ran, 400 when it was refused and
nothing ran.

    curl -s -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '<arguments>' <move URL>

{{moves}}

## Connecting and leaving

A fresh invitation is already connected, including when used over MCP. If
`connected` is false after an earlier disconnect, explicitly rejoin before
moving or asking anyone to pass to you:

    curl -s -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{"connected":true}' {{session_url}}

To leave, POST exactly `{"connected":false}` to the same URL. This excludes
your current invitation from handoff targets and releases its controller in
one serialized server operation. The bearer stays valid for later reconnect;
reconnecting restores eligibility and does not take anyone's controller.
Wait for `{ok:true, connected:false}` before forgetting your local bearer.
A malformed or unavailable participation state is refused, never treated as
a fresh connection. If a game write's outcome is unknown, do not replay it.

## Taking turns

Read the seat before you move. When `controller` names someone else and
`controller_recoverable` is false, wait and read it again later. Otherwise,
play, then pass to a name
from `participants`. A departed holder can also be released by the next move.
For text, `data.keys_pressed` is the number of UTF-8 bytes actually applied,
which may be less than the submitted text. Keep the unpressed suffix and
check the game before sending more; never automatically replay unknown input.
