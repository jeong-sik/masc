# Connector Config Schema (SSOT)

Dashboard "커넥터" surface is meant to let an operator configure and control
each sidecar without hand-editing files. This document enumerates what config
each sidecar actually reads, where it reads it from, and how the dashboard
should surface it in a form.

The remaining external sidecars share the following resolution order via
Pydantic `BaseSettings` + `TomlConfigSettingsSource`:

```
env  >  runtime TOML  >  field defaults
```

- External-sidecar TOML path: `${MASC_BASE_PATH}/.gate/runtime/<name>/config.toml`
- Env file: `sidecars/<name>-bot/.env` (cwd-relative at process start)
- Dashboard should **write the TOML**, not the `.env` — TOML is the persistent
  surface, `.env` is developer scratch.

Discord, Slack and iMessage are not sidecars. Their in-process OCaml gateways
read what they need from the server environment, as documented in their
sections below. Telegram is the one external sidecar left.

## Common fields (all sidecars)

| Field | Env alias | Default | Notes |
|---|---|---|---|
| `gate_base_url` | `GATE_BASE_URL` | `http://localhost:8935` | MASC server. Loopback host relaxes auth. |
| `gate_api_token` | `GATE_API_TOKEN` | `""` | Required unless `gate_base_url` is loopback. |
| `gate_timeout_sec` | `GATE_TIMEOUT_SEC` | 120 | int/float seconds, must be positive. |
| `status_cache_ttl_sec` | `STATUS_CACHE_TTL_SEC` | 15 | gate status cache. |
| `keeper_cache_ttl_sec` | `KEEPER_CACHE_TTL_SEC` | 30 | keeper discovery cache. |
| `binding_store_path` | `<NAME>_BINDING_STORE_PATH` | `.gate/runtime/<name>/bindings.json` | runtime-bind file. |
| `status_path` | `<NAME>_STATUS_PATH` | `.gate/runtime/<name>/status.json` | heartbeat written by sidecar. |

## Per-sidecar required/unique fields

### Discord (in-process gateway — RFC-0203 §Phase 3)

The Discord connector runs **inside the server process**, not as an
external sidecar (`sidecars/discord-bot/` was deleted in #19393).
Module: `lib/server/server_discord_in_process_gateway.{ml,mli}` plus
the gate-state extension in `lib/gate/channel_gate_discord_state.{ml,mli}`.

| Env var | Required | Notes |
|---|---|---|
| `DISCORD_BOT_TOKEN` | **yes** | Developer Portal → Bot → Reset Token. Read at every `send_message` call, so token rotation does not require a server restart. If unset the gateway logs a warning and skips startup; the rest of the server boots normally. |
| `MASC_DISCORD_TRIGGER_POLICY` | no (default `mention_or_thread`) | Closed sum: `mention_only`, `mention_or_thread`, `user_only:<discord_user_id>`, or `all`. Resolution is env > `[discord].trigger_policy` in resolved `runtime.toml` > default. A non-empty invalid env or TOML value is a typed configuration error and the Discord gateway does not start; it is never coerced to a fallback policy. |

An absent or blank env value is unset and falls through to TOML. A missing
`runtime.toml`, missing `[discord].trigger_policy`, or blank TOML value is also
unset and yields the default only after both configured planes are absent.

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
| `MASC_SLACK_TRIGGER_POLICY` | no | Closed sum: `mention_only`, `mention_or_thread`, `user_only:<slack_user_id>`, or `all`. |

Channel→keeper bindings: `Channel_gate_slack_state.bind` / `unbind` write to
`.gate/runtime/slack/bindings.json` (overridable via
`MASC_SLACK_BINDING_STORE_PATH`), mutated through
`/api/v1/gate/connector/bind?name=slack` and `/unbind?name=slack`.

Slack-specific setup:

1. https://api.slack.com/apps → Create New App → From scratch.
2. **Socket Mode** → enable → generate App-Level Token with `connections:write` → `xapp-…`.
3. **OAuth & Permissions** → Bot Token Scopes: `chat:write`, `app_mentions:read`, `im:history`, `im:read` → install → `xoxb-…`.
4. **Event Subscriptions** → enable → subscribe bot events: `app_mention`, `message.im`.

### Telegram (`sidecars/telegram-bot/src/config.py`)

| Field | Env alias | Type | Required | Notes |
|---|---|---|---|---|
| `telegram_bot_token` | `TELEGRAM_BOT_TOKEN` | str | **yes** | `@BotFather` → `/newbot`. |
| `default_keeper` | `TELEGRAM_DEFAULT_KEEPER` | str | no (`sangsu`) | |
| `admin_user_ids` | `TELEGRAM_ADMIN_USER_IDS` | csv int | no | comma-separated Telegram user IDs. |

Telegram-specific setup:

1. Message `@BotFather` → `/newbot` → name + username → receive token.
2. Optional `/setprivacy` → disable to let bot see group messages (or mention-only).
3. Get user IDs via `@userinfobot` for `admin_user_ids`.

## Dashboard UI contract (target for Phase 7 follow-ups)

For each connector the dashboard should render:

1. **Status header** (already exists): `healthy | degraded | failing`,
   heartbeat age, bot identity.
2. **Lifecycle bar** (C4): `Start` · `Stop` · `Restart` · `Tail logs` — hits a
   new `/api/v1/sidecar/<name>/{start,stop,status,logs}` endpoint.
3. **Config form** (C5+): generated from the Pydantic JSON schema
   (`BotConfig.model_json_schema()`) — one endpoint per sidecar exposes the
   schema, so the form never drifts from the Python definition.
   - Secret fields (`*_token`, `gate_api_token`) render as masked with a
     "reveal once" button. Write-only — GET returns `"<redacted:len=72>"`.
   - Enums (`reply_mode`) render as radio / segmented control.
   - CSV fields (`admin_user_ids`) render as a tag input with int validation.
   - JSON fields (`discord_keeper_map`) render as a key/value grid.
4. **Setup wizard** (C6): per-connector click-through for the platform steps
   that can't be automated (Discord token / Slack Socket Mode / Telegram
   BotFather / iMessage Full Disk Access).
5. **Validation**: form submit POSTs TOML to backend; backend calls
   `BotConfig(**payload)` to re-run Pydantic validators, returns per-field
   errors on failure.

## Known gaps and progress

- ~~`sidecars/{imessage,telegram}-bot/src/config.py` reference `Path` and
  `os` inside `_runtime_toml_path()` without importing them — `BotConfig()`
  hits `NameError` the moment `TomlConfigSettingsSource` is wired.~~ **Fixed**
  in `fix/sidecar-config-imports` (regression test per sidecar).
- ~~imessage/telegram have no first-class start/tail/status entry point.~~
  **Fixed** in `feature/sidecar-run-sh`: both sidecars expose
  `./run.sh [start|stop|tail|status]` with a `.env.example` and
  per-bridge token guidance.
- ~~Dashboard's lifecycle hint forks discord-only `./run.sh` from
  `python -m src` for the others.~~ **Fixed** in
  `feature/dash-connectors-toplevel`: `sidecarCommands()` is now a single
  `./run.sh <verb>` table; stop routes through `./run.sh stop` (no more
  hand-rolled pkill).
- **Open**: no backend endpoint to start/stop a sidecar — the dashboard
  shows shell snippets to copy. Native Start/Stop/Restart buttons need a
  `/api/v1/sidecar/<id>/{start,stop,status,logs}` endpoint that shells out
  to the wrapper (Eio.Process based).
- **Open**: no per-connector config-TOML write endpoint. Form submit needs
  `/api/v1/sidecar/<id>/config` POST that writes
  `${MASC_BASE_PATH}/.gate/runtime/<id>/config.toml` with mode 0600.
- **Open**: no JSON-schema export endpoint for Pydantic models. Each sidecar
  could expose `BotConfig.model_json_schema()` once and the dashboard
  generates a form from that — single source of truth, zero drift.

## References

- Mautrix bridges (`bridge.toml` pattern): https://docs.mau.fi/bridges/
- BlueBubbles (iMessage admin panel start/stop): https://bluebubbles.app/
- Matterbridge TOML sections: https://github.com/42wim/matterbridge
- Beeper desktop (tabbed per-network config): commercial reference only.
