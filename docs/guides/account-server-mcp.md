# The MCP endpoint of a person on the account server

A multi-account installation runs the account server. A person who was
invited to it can connect an MCP client with a personal access token (PAT)
and work with their own Keepers from that client. This guide covers what
the endpoint serves, how to connect, and what it does not do yet.

The single-user server has its own `/mcp`, with other tools and other
credentials. Nothing here applies to it. How an operator sets the account
server up is in [Setting up the account server](account-server-setup.md).

## What the endpoint serves

`POST /mcp` on the address of the account server. One JSON-RPC message per
request, one JSON answer.

| Method | Answer |
| --- | --- |
| `initialize` | The negotiated revision, the server, and the `tools` capability. No `Mcp-Session-Id`. |
| `server/discover` | The supported revisions, for a client of revision 2026-07-28. |
| `ping` | An empty result. |
| `tools/list` | The six tools below, on one page. |
| `tools/call` | The result of the tool. |
| a notification | 202 with no body. |

| Tool | What it does | Effect the PAT needs |
| --- | --- | --- |
| `masc_whoami` | Who the server takes the credential for, and the role. | `read_state` |
| `masc_my_runtimes` | Your subscriptions and the Runtimes on them. | `manage_own_provider` |
| `masc_my_keepers` | Your Keepers, each with its Runtime. | `manage_own_keeper` |
| `masc_my_keeper_create` | Makes a Keeper you own. | `manage_own_keeper` |
| `masc_my_keeper_assign` | Gives one of your Keepers one of your Runtimes. | `manage_own_keeper` |
| `masc_my_keeper_turn` | Sends a Keeper a message and returns its answer. The Keeper goes on in its conversation. | `manage_own_keeper`, `invoke_model`, `use_tool` |
| `masc_my_keeper_conversation_new` | Starts a new conversation of a Keeper. | `manage_own_keeper` |
| `masc_my_keeper_conversation` | Reads what you asked a Keeper and what it answered. | `manage_own_keeper`, `read_state` |

Each tool calls the function behind the matching control of the person's
page (`/`), after the same check. The text of a tool result is the JSON
that page reads. A refusal comes back as a tool result with `isError: true`
and the sentence of the refusal. The tools of a Keeper's turn and
conversation give `{"error": <sentence>, "code": <code>}`; the codes are
listed under [Error codes of a turn and a conversation](#error-codes-of-a-turn-and-a-conversation).

A Keeper or a Runtime of another person is answered as one that is not
there. A Keeper name is your own: another person can have a Keeper of the
same name, and each of you lists, assigns and runs only your own.

## Connect a client

1. Sign in at `/` on the account server.
2. Connect a subscription under **My subscriptions**. The endpoint has no
   tool for this step: the login of a CLI needs the browser.
3. Under **My PATs**, replace the scope with the effects you want the token
   to carry, then press **Issue**. For every tool:

   ```json
   {"runtimes":"all","channels":["direct"],"allowed_effects":["invoke_model","manage_own_keeper","manage_own_provider","read_state","use_tool"]}
   ```

   The labels of `allowed_effects` are in ascending order; another order
   is refused. The scope the page fills in holds `read_state` alone, which
   is enough for `masc_whoami` and nothing else.

   A turn runs on your subscription, so the token must allow it as a turn:
   its scope holds `invoke_model` and `use_tool`, the `direct` channel, and
   the Runtime of the Keeper (`"runtimes":"all"`, or a list that names it).
   A token without them still lists, makes and assigns Keepers, and its
   turn is refused with a 403.
4. Copy the token. The page shows it once.
5. Give the client the URL and the token as a bearer header. With Claude
   Code:

   ```sh
   claude mcp add --transport http masc-account https://<host>/mcp \
     --header "Authorization: Bearer <token>"
   ```

Revoking the PAT on the page takes effect on the next request. The
endpoint keeps no session, so there is nothing else to close.

## Check it by hand

```sh
curl -sS https://<host>/mcp \
  -H "Authorization: Bearer $MASC_PAT" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"masc_whoami","arguments":{}}}'
```

The answer is a JSON-RPC result whose text holds your principal, your role
and `"binding":{"kind":"pat",...}`.

| Status | Meaning |
| --- | --- |
| 200 | A JSON-RPC answer. A tool that refused is still a 200, with `isError`. |
| 202 | A notification was taken. |
| 400 | The body is not one JSON-RPC message, the `Accept` header does not take both `application/json` and `text/event-stream`, or the MCP routing headers disagree with the body. |
| 401 | No credential, or one the server does not take: a revoked or expired PAT, a credential of the single-user server. |
| 403 | A browser session without the same origin or the CSRF token. |
| 405 | `GET` or `DELETE`. The endpoint opens no stream. |
| 413 | A message over 64 KiB. |
| 503 | The server cannot read its accounts. Try again later. |

## Conversations

A Keeper on a Claude Code Runtime has one conversation at a time. Its first
turn starts one, and each later turn goes on in it: the Keeper has read
what you asked before and what it answered. The answer of
`masc_my_keeper_turn` names the conversation in `conversation_id`, and
`continued` is `true` when the turn resumed it.

- **What the server keeps.** The message and the answer of each turn are
  written to the disk of the server, in a directory of your own beside the
  logins of your subscriptions. Whoever runs the server can read that
  directory.
- **One subscription per conversation.** A conversation stays on the
  subscription it began on. When you give the Keeper a Runtime of another
  subscription, its next turn is refused. Start a new conversation with
  `masc_my_keeper_conversation_new`, or give the Keeper a Runtime of the
  first subscription again.
- **Turns that keep failing.** When Claude Code no longer has the session
  of a conversation, each turn of it ends without an answer, and the
  answer says to start a new conversation when that keeps happening. The
  server cannot tell that from another failure and starts no session by
  itself: start a new conversation.
- **A new conversation is yours to start.** `masc_my_keeper_conversation_new`
  starts one. The Keeper's next turn has read none of the earlier turns.
  The earlier conversations stay recorded, and no turn goes on in them.
  While a turn runs on the subscription of the current conversation, the
  start is refused: start it when the turn has ended.
- **Reading it back.** `masc_my_keeper_conversation` answers the turns of
  the current conversation, and the list of the Keeper's conversations.
  Name one of them in `conversation_id` to read an earlier one. Each
  listed conversation names the subscription it began on
  (`provider_account_id`), so you can tell before a turn that the current
  one is bound to another subscription than the Keeper's Runtime. A turn is
  `answered`, `failed`, or `unrecorded` when the server stopped before the
  turn ended. A failed or unrecorded turn with `model_may_have_read: true`
  may still be part of what the Keeper remembers: the client was started
  with your message. The whole conversation comes in one answer. When the
  server stopped in the middle of writing a row, the read is refused with
  503 `conversation_row_half_written` until a new conversation of the
  Keeper, or its next turn on a Claude Code Runtime, cuts that row.
  Reading again does not cut it.
- **A failed turn is not sent again.** The server does not start the turn
  over, and it starts no new conversation in place of one whose turn
  failed. Send the message again when you want it answered.

## Error codes of a turn and a conversation

`masc_my_keeper_turn`, `masc_my_keeper_conversation_new` and
`masc_my_keeper_conversation`, and the routes behind them, refuse with
`{"error": <sentence>, "code": <code>}`. Tell the cases apart by `code`;
the sentence may change. The code of a failed turn is the `failure` the
read of the conversation shows for that turn.

| Status | `code` | Meaning |
| --- | --- | --- |
| 400 | `invalid_request` | The arguments are not of the shape the tool reads, or the name is no Keeper name. |
| 400 | `message_too_long` | The message is longer than 4096 bytes. |
| 400 | `message_blank` | The message is blank. |
| 400 | `runtime_not_supported` | The Runtime of the Keeper is neither a Claude Code nor a Codex Runtime. |
| 400 | `account_runtime_invalid` | The runtime of the subscription does not load from the configuration of the server. |
| 403 | `turn_refused` | The authorization refused the turn, for example for a PAT whose scope does not cover it. |
| 403 | `native_tools_refused` | The client would start with tools that reach the homes of other people. |
| 404 | `unknown_keeper` | No Keeper of yours has this name. |
| 404 | `unknown_conversation` | The Keeper has no conversation of this id. |
| 404 | `unknown_account` | The subscription of the Keeper's Runtime has no login of yours. |
| 409 | `keeper_has_no_runtime` | The Keeper has no Runtime. Give it one first. |
| 409 | `account_call_running` | A turn or a check of the subscription runs. Try again when it ends. |
| 409 | `conversation_on_other_subscription` | The current conversation began on another subscription. Start a new conversation. |
| 409 | `runtime_reassigned` | The Keeper got another Runtime during the request. |
| 409 | `not_signed_in` | The subscription of the Runtime is not signed in. |
| 429 | `no_quota` | The subscription has no quota left. |
| 500 | `configuration_refused` | The client refused the configuration of the Runtime. |
| 500 | `conversation_row_not_understood` | The record of the conversation has a row the server does not understand. |
| 500 | `internal_error` | A state the server does not expect. Its log has the detail. |
| 502 | `no_answer` | The client ended the turn without an answer. When the turns of a conversation keep failing, start a new conversation. |
| 503 | `not_started` | The client did not start. |
| 503 | `answer_unrecorded` | The Keeper answered, and the server could not record the answer. |
| 503 | `conversation_row_half_written` | A stopped server left the last row of the record half written. A new conversation, or the Keeper's next turn on a Claude Code Runtime, cuts it. |
| 503 | `conversation_record_unavailable` | The server could not read or write the record of the conversation. |
| 503 | `server_unavailable` | The server cannot decide now. Try again later. |
| 504 | `silent` | The client sent nothing for 120 seconds. |

A refusal before the tool reaches the route, such as a PAT without the
Keeper effect, has no `code`.

## Limits

- **One answer per request.** `masc_my_keeper_turn` holds the request open
  until the Runtime answers. The server gives a turn up when the client of
  the Runtime is silent for 120 seconds. An MCP client with a shorter
  request timeout ends the call first; raise that timeout if turns are cut
  off.
- **One call of a subscription at a time.** A second turn on the same
  subscription while one runs is refused, and so is a new conversation of
  a Keeper whose current conversation is on that subscription.
- **No OAuth.** A 401 carries no `WWW-Authenticate` challenge and the
  server publishes no protected resource metadata, so a client that
  connects only through MCP OAuth cannot connect. Use a client that sends a
  bearer header.
- **No Board, no resources, no prompts, no notifications from the
  server.**
