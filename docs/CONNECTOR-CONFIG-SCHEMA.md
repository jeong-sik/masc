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

Discord is no longer a sidecar. Its in-process OCaml gateway resolves the
trigger-policy env override and the `[discord]` table in MASC `runtime.toml` as
documented in the Discord section below.

## Common fields (all sidecars)

| Field | Env alias | Default | Notes |
|---|---|---|---|
| `gate_base_url` | `GATE_BASE_URL` (Discord/Slack/Telegram), `MASC_GATE_URL` (iMessage) | `http://localhost:8935` | MASC server. Loopback host relaxes auth. |
| `gate_api_token` | `GATE_API_TOKEN`, `MASC_GATE_API_TOKEN` (iMessage) | `""` | Required unless `gate_base_url` is loopback. |
| `gate_timeout_sec` | `GATE_TIMEOUT_SEC` | 120 (30 for iMessage) | int/float seconds, must be positive. |
| `status_cache_ttl_sec` | `STATUS_CACHE_TTL_SEC` | 15 (10 for iMessage) | gate status cache. |
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

### iMessage (`sidecars/imessage-bot/src/config.py`)

No auth token — local `chat.db` access. Runs only on macOS.

| Field | Env alias | Type | Default | Notes |
|---|---|---|---|---|
| `poll_interval_sec` | `IMESSAGE_POLL_INTERVAL` | float | 2.0 | min 0.5. |
| `reply_mode` | `IMESSAGE_REPLY_MODE` | enum | `self-chat` | `self-chat` or `source-chat`. |
| `self_chat_guid` | `IMESSAGE_SELF_CHAT_GUID` | str | `""` | optional Messages.app chat guid when reply_mode=self-chat. |
| `chat_db_path` | — | path | `~/Library/Messages/chat.db` | rarely changed. |
| `cursor_path` | — | path | `.gate/runtime/imessage/cursor.json` | read cursor. |

iMessage-specific setup (dashboard can guide, not automate):

- Terminal/iTerm needs Full Disk Access (System Settings → Privacy → Full Disk Access).
- Messages.app must be signed in and open for chat.db to contain recent rows.
- For `reply_mode=self-chat`, create a self-chat in Messages first and paste its GUID.

### Slack (`sidecars/slack-bot/src/config.py`)

Uses **Socket Mode** — no public endpoint, no OAuth callback.

| Field | Env alias | Type | Required | Notes |
|---|---|---|---|---|
| `slack_bot_token` | `SLACK_BOT_TOKEN` | str | **yes** | `xoxb-…`. |
| `slack_app_token` | `SLACK_APP_TOKEN` | str | **yes** | `xapp-…` for Socket Mode. |
| `default_keeper` | `SLACK_DEFAULT_KEEPER` | str | no (`sangsu`) | fallback when no binding matches. |

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

- ~~`sidecars/{imessage,slack,telegram}-bot/src/config.py` reference `Path` and
  `os` inside `_runtime_toml_path()` without importing them — `BotConfig()`
  hits `NameError` the moment `TomlConfigSettingsSource` is wired.~~ **Fixed**
  in `fix/sidecar-config-imports` (regression test per sidecar).
- ~~Only discord-bot ships a `run.sh` wrapper — imessage/slack/telegram have
  no first-class start/tail/status entry point.~~ **Fixed** in
  `feature/sidecar-run-sh`: all 4 bots now expose
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
