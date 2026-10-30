# Connector Config Schema (SSOT)

Discord, iMessage, Slack and Telegram run inside the MASC server. Credentials
and paths use each connector's documented configuration reader. Discord and
Slack credentials come from the server process environment. Telegram first
reads the environment value (including an explicit blank); only an absent value
falls back to its runtime.toml override. Telegram binding path resolution then
skips blank values and tries the next alias/default. Relative binding and audit
paths resolve against the effective base path.
The dashboard exposes connection state, setup instructions and Keeper bindings.

## Connector settings

### Discord (in-process gateway — RFC-0203 §Phase 3)

The Discord connector runs **inside the server process**, not as an
external sidecar (`sidecars/discord-bot/` was deleted in #19393).
Module: `lib/server/server_discord_in_process_gateway.{ml,mli}` plus
the gate-state extension in `lib/gate/channel_gate_discord_state.{ml,mli}`.

| Env var | Required | Notes |
|---|---|---|
| `DISCORD_BOT_TOKEN` | **yes** | Developer Portal → Bot → Reset Token. Read at every `send_message` call, so token rotation does not require a server restart. If unset the gateway logs a warning and skips startup; the rest of the server boots normally. |
The trigger policy is not an env var. Which inbound messages start a turn is a
stance the operator writes down, so it is read from `[discord].trigger_policy`
in the resolved `runtime.toml` and nowhere else. Resolution is the
`discord.trigger_policy` runtime param > `[discord].trigger_policy` > default
(`mention_or_thread`). Closed sum: `mention_only`, `mention_or_thread`,
`user_only:<discord_user_id>`, or `all`. A non-empty invalid value is a typed
configuration error and the Discord gateway does not start; it is never coerced
to a fallback policy.

A missing `runtime.toml`, a missing `[discord].trigger_policy`, or a blank
value are three ways of saying unset and yield the default.

The runtime param sits above both file planes and is where an operator changes
the policy without a restart: the gateway client reads it before every step, so
a change decides the next inbound message. The TUI reaches it at Config → `p` →
params, which draws the three named values as a picker (`user_only:<id>` is
typed, since it carries an id). Clearing the override returns to whatever env
and `runtime.toml` resolved to at startup, not to the hardcoded baseline.
Changes persist in `.masc/runtime_params.json` and are recorded in
`.masc/param_audit.jsonl`.

`Channel_gate_discord_state.set_trigger_policy` holds a display mirror for the
connector status JSON, not the value anything is judged by; a param change
carries it along so the screen does not contradict the change.

Slack's `[slack].trigger_policy` and its `slack.trigger_policy` param work the
same way, through the same shared resolution (`Connector_trigger_policy`).

Channel→keeper bindings live where they always did:
`Channel_gate_discord_state.bind` / `unbind` write to
`.gate/runtime/discord/bindings.json` (overridable via
`MASC_DISCORD_BINDING_STORE_PATH`). The HTTP routes
`/api/v1/gate/connector/bind?name=discord` and
`/api/v1/gate/connector/unbind?name=discord` remain functional and
are how the dashboard mutates bindings.

The pre-cutover env vars `DISCORD_KEEPER_MAP`, `DISCORD_ADMIN_ROLE_ID`,
`DISCORD_BINDING_AUDIT_PATH`, `DISCORD_NAMES_PATH`,
`STATUS_HEARTBEAT_SEC`, `GATE_MAX_RETRIES` were sidecar-only and
no longer apply.

Discord-specific setup (cannot be driven from dashboard — operator must do):

1. https://discord.com/developers/applications → New Application.
2. Bot tab → Reset Token → paste into shell env as `DISCORD_BOT_TOKEN`.
3. Bot tab → enable **Message Content Intent** (required for `GUILD_MESSAGES`/`MESSAGE_CONTENT` intents).
4. OAuth2 URL Generator → `bot` scope, permissions: Send Messages, Embed Links, Read Message History → invite.
5. Restart the server so the new token is picked up at the next gateway connect.

### iMessage (in-process gateway)

The iMessage connector runs **inside the server process**, not as an external
sidecar (`sidecars/imessage-bot/` was deleted in #30531). Modules:
`lib/server/server_imessage_in_process_gateway.{ml,mli}`, the gate-state module
`lib/gate/channel_gate_imessage_state.{ml,mli}`, the chat.db reader
`lib/gate/imessage_chat_db.{ml,mli}`, and the sender
`lib/gate/imessage_applescript.{ml,mli}`; env reads live in
`lib/config/env_config_imessage.{ml,mli}`.

macOS only, and there is no token. macOS authorizes the process itself, so what
this connector needs is a permission grant rather than a credential.

| Env var | Required | Notes |
|---|---|---|
| `MASC_IMESSAGE_REPLY_MODE` | no (default `self-chat`) | `self-chat` or `source-chat`. An unrecognised value is a configuration error and the gateway does not start; it is never coerced to the default. A typo that quietly routed replies elsewhere would only be visible to whoever wrongly received them. |
| `MASC_IMESSAGE_SELF_CHAT_GUID` | no | The note-to-self chat to answer in. Left unset, the connector resolves it from chat.db and keeps looking on every poll, because that conversation may not exist yet when the server boots. |
| `MASC_IMESSAGE_POLL_INTERVAL_SEC` | no (default `2`) | Accepted range 0.5–300 seconds. Unparseable or out of range is a configuration error, not a silent fallback to the default. |
| `MASC_IMESSAGE_CURSOR_PATH` | no | Default `.gate/runtime/imessage/cursor.json` under the base path. Holds the last delivered `message.ROWID`. A cursor file that cannot be read stops startup rather than restarting from zero, which would redeliver every message Messages.app has ever stored. |
| `MASC_IMESSAGE_CHAT_DB_PATH` | no | Default `$HOME/Library/Messages/chat.db`. Exists so tests can read a fixture. |

Bindings work like every other connector:
`.gate/runtime/imessage/bindings.json` (overridable via
`MASC_IMESSAGE_BINDING_STORE_PATH`), mutated through
`/api/v1/gate/connector/bind?name=imessage` and the matching `unbind`.

The sidecar's `IMESSAGE_*` spellings, `MASC_GATE_URL`, `MASC_GATE_API_TOKEN`
and `status.json` are gone, and so is `/api/v1/sidecar/*?name=imessage`, which
now 404s. There is no process to start or stop.

#### Setting it up

1. Give **the terminal that runs the masc server** Full Disk Access: System
   Settings → Privacy & Security → Full Disk Access. The grant follows the
   process that reads the file, and that is now the server rather than a bot.
2. Sign in to Messages.app and leave it open, so chat.db keeps receiving rows.
3. Start the server. Without the grant it boots normally and this connector
   alone stays down, with the reason in the log and in the connector's `error`
   field.
4. Bind a conversation to a Keeper. In the TUI: the **Connectors** surface,
   `b` opens the bind form and `u` unbinds. In the dashboard:
   **Connectors → iMessage → Quick Bind**. Both write the same file.

The channel id is the conversation's `chat_identifier`. For a one-to-one chat
that is the other party's phone number or email address.

#### Two things that surprise people

**Replies do not go back to the sender by default.** `self-chat` answers in
your own note-to-self conversation. That is the quiet default on purpose: a
Keeper answering in `source-chat` writes into whatever conversation asked,
including a group chat. Set `MASC_IMESSAGE_REPLY_MODE=source-chat` to answer
where the message came from. In `self-chat` with no note-to-self conversation
resolved, the connector reports `available: false` and refuses to send rather
than picking a conversation for you.

**An unbound conversation leaves no trace.** Messages.app holds the operator's
whole personal correspondence, so a conversation nobody bound is dropped
without a log line. The cost is that a group chat's opaque `chat_identifier`
cannot be discovered from masc — see #30596.

#### Checking that it works

`GET /api/v1/gate/connectors`, or the same fields in the TUI and the dashboard:

| Field | Healthy |
|---|---|
| `chat_db_readable` | `true` — the grant is in place |
| `poll_state` | `polling` |
| `connected` | `true` |
| `cursor_rowid` | rising as messages arrive |
| `self_chat_guid` | redacted but non-empty, in `self-chat` mode |
| `runtime_bindings_count` | at least 1 |
| `error` | empty |

This connector never reports `stale`. Liveness is a value the poll fiber
publishes, not a heartbeat file that can age out.

### Slack (in-process gateway — RFC-0317)

The Slack connector runs **inside the server process** over **Socket Mode** —
no public endpoint, no OAuth callback, no sidecar. Modules:
`lib/server/server_slack_in_process_gateway.{ml,mli}` plus the gate-state
module `lib/gate/channel_gate_slack_state.{ml,mli}`; env reads live in
`lib/config/env_config_slack.{ml,mli}`.

| Env var | Required | Notes |
|---|---|---|
| `SLACK_APP_TOKEN` | **yes** | `xapp-…` app-level token for `apps.connections.open`. If unset the gateway does not start; the rest of the server boots normally. |
| `SLACK_BOT_TOKEN` | **yes** | `xoxb-…` bot token for outbound `chat.postMessage`. Read at call time, so rotation does not require a restart. If unset the gateway connects but every reply fails, and the connector reports `available:false`. |

The Slack trigger policy is not an env var either: `[slack].trigger_policy` in
the resolved `runtime.toml` is the only configured plane. Closed sum:
`mention_only`, `mention_or_thread`, `user_only:<slack_user_id>`, or `all`.

Channel→keeper bindings: `Channel_gate_slack_state.bind` / `unbind` write to
`.gate/runtime/slack/bindings.json` (overridable via
`MASC_SLACK_BINDING_STORE_PATH`), mutated through
`/api/v1/gate/connector/bind?name=slack` and `/unbind?name=slack`.

Slack-specific setup:

1. https://api.slack.com/apps → Create New App → From scratch.
2. **Socket Mode** → enable → generate App-Level Token with `connections:write` → `xapp-…`.
3. **OAuth & Permissions** → Bot Token Scopes: `chat:write`, `app_mentions:read`, `im:history`, `im:read` → install → `xoxb-…`.
4. **Event Subscriptions** → enable → subscribe bot events: `app_mention`, `message.im`.

### Telegram (native long polling)

Modules: `lib/server/server_telegram_in_process_gateway.ml`,
`lib/gate/channel_gate_telegram_state.ml`, `lib/gate/telegram_poll_custody.ml`,
`lib/keeper/keeper_chat_telegram.ml` and `lib/keeper/keeper_telegram_render.ml`.

| Setting | Resolution | Default |
|---|---|---|
| Bot credential | `TELEGRAM_BOT_TOKEN` | required |
| Bindings | `TELEGRAM_BINDING_STORE_PATH`, then `MASC_TELEGRAM_BINDING_STORE_PATH` | `.gate/runtime/telegram/bindings.json` |
| Binding audit | `TELEGRAM_BINDING_AUDIT_PATH`, then `MASC_TELEGRAM_BINDING_AUDIT_PATH` | `.gate/runtime/telegram/binding_audit.jsonl` |

1. Obtain a bot token from [@BotFather](https://t.me/BotFather).
2. Set `TELEGRAM_BOT_TOKEN` in the server environment or runtime.toml and restart
   MASC. Set group privacy according to which messages the bot should receive.
3. Bind the numeric chat ID to a Keeper through the dashboard. Group chat IDs
   can be negative. Unreadable binding state refuses acknowledgment.

The authenticated bot ID owns its cursor under
`<base-path>/.gate/runtime/telegram/<bot-id>/cursor.json`. The cursor advances
only after durable Keeper acceptance or an explicit ignored-message decision.
The native continuation retains chat, forum/direct-message topic, reply and
user coordinates. Terminal delivery renders the exact persisted assistant turn
as balanced Telegram HTML chunks. Private/local media references and binary
attachments without a public reference remain explicit delivery failures;
partial sends record successful message IDs and do not imply automatic resume.

## Dashboard and backend

Connection state comes from `GET /api/v1/gate/connectors`. Keeper bindings use
`POST /api/v1/gate/connector/bind?name=<id>` and
`POST /api/v1/gate/connector/unbind?name=<id>`. Configuration panels provide
credential/permission instructions. Gateways start with the server; connection
configuration and actual remote connectivity are separate observations.

## References

- Mautrix bridges (`bridge.toml` pattern): https://docs.mau.fi/bridges/
- BlueBubbles (iMessage admin panel start/stop): https://bluebubbles.app/
- Matterbridge TOML sections: https://github.com/42wim/matterbridge
- Beeper desktop (tabbed per-network config): commercial reference only.
