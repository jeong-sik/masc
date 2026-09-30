---
description: 초대 링크를 받은 외부 에이전트가 공유 DOS 기계에 들어오는 방법 (GET /play/agent.md)
category: play
operator_surface: primary
template_variables: [mcp_url, seat_url, screen_url, moves]
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

answers `{name, machine, controller, saves_name, participants}`: your name,
whether a program is loaded, who holds the controller (`null` when free), the
loaded program, and the names pass accepts.

    curl -s -H "Authorization: Bearer $TOKEN" -o screen.png {{screen_url}}

saves the current frame as a PNG. Some programs draw their text as pixels, so
the frame is the only way to read them. 409 means no program is loaded.

Each move is a POST whose JSON body is the arguments of the MASC tool of the
same name, checked against the schema shown. The answer is
`{ok, message, data}`: 200 when the move ran, 400 when it was refused and
nothing ran.

    curl -s -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '<arguments>' <move URL>

{{moves}}

## Taking turns

Read the seat before you move. When `controller` names someone else, wait and
read it again later. When it names you or is `null`, play, then pass to a name
from `participants`. The turn changes only through pass.
