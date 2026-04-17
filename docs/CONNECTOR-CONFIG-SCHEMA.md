# Connector Config Schema (SSOT)

Dashboard "커넥터" surface is meant to let an operator configure and control
each sidecar without hand-editing files. This document enumerates what config
each sidecar actually reads, where it reads it from, and how the dashboard
should surface it in a form.

All four current sidecars share the same resolution order (via Pydantic
`BaseSettings` + `TomlConfigSettingsSource`):

```
env  >  runtime TOML  >  field defaults
```

- Runtime TOML path: `${MASC_BASE_PATH}/.gate/runtime/<name>/config.toml`
- Env file: `sidecars/<name>-bot/.env` (cwd-relative at process start)
- Dashboard should **write the TOML**, not the `.env` — TOML is the persistent
  surface, `.env` is developer scratch.

## Common fields (all sidecars)

| Field | Env alias | Default | Notes |
|---|---|---|---|
| `gate_base_url` | `GATE_BASE_URL` (Discord/Slack/Telegram), `MASC_GATE_URL` (iMessage) | `http://localhost:8935` | MASC server. Loopback host relaxes auth. |
| `gate_api_token` | `GATE_API_TOKEN`, `MASC_GATE_API_TOKEN` (iMessage) | `""` | Required unless `gate_base_url` is loopback. |
| `gate_timeout_sec` | `GATE_TIMEOUT_SEC` | 120 (30 for iMessage) | int/float seconds, must be positive. |
| `gate_breaker_failure_threshold` | `GATE_BREAKER_FAILURE_THRESHOLD` | 3 (5 for iMessage) | consecutive 5xx/timeout before circuit opens. |
| `gate_breaker_reset_sec` | `GATE_BREAKER_RESET_SEC` | 30 (60 for iMessage) | half-open wait. |
| `status_cache_ttl_sec` | `STATUS_CACHE_TTL_SEC` | 15 (10 for iMessage) | gate status cache. |
| `keeper_cache_ttl_sec` | `KEEPER_CACHE_TTL_SEC` | 30 | keeper discovery cache. |
| `binding_store_path` | `<NAME>_BINDING_STORE_PATH` | `.gate/runtime/<name>/bindings.json` | runtime-bind file. |
| `status_path` | `<NAME>_STATUS_PATH` | `.gate/runtime/<name>/status.json` | heartbeat written by sidecar. |

## Per-sidecar required/unique fields

### Discord (`sidecars/discord-bot/src/config.py`)

| Field | Env alias | Type | Required | Notes |
|---|---|---|---|---|
| `discord_bot_token` | `DISCORD_BOT_TOKEN` | str | **yes** | Developer Portal → Bot → Reset Token. |
| `discord_keeper_map` | `DISCORD_KEEPER_MAP` | JSON str | no (default `{}`) | `{"<channel_id>": "<keeper_name>"}` — startup-only mapping; runtime edits go through `/api/v1/gate/connector/bind`. |
| `discord_admin_role_id` | `DISCORD_ADMIN_ROLE_ID` | str | no | role allowed to use admin commands. |
| `discord_binding_audit_path` | `DISCORD_BINDING_AUDIT_PATH` | path | no | append-only audit log (JSONL). |
| `discord_names_path` | `DISCORD_NAMES_PATH` | path | no | guild/channel id→name side-map, written every `STATUS_HEARTBEAT_SEC`. |
| `status_heartbeat_sec` | `STATUS_HEARTBEAT_SEC` | int | no (10) | |
| `gate_max_retries` | `GATE_MAX_RETRIES` | int | no (2) | Discord-only; others have no retry knob. |

Discord-specific setup (cannot be driven from dashboard — operator must do):

1. https://discord.com/developers/applications → New Application.
2. Bot tab → Reset Token → paste into dashboard field.
3. Bot tab → enable **Message Content Intent**.
4. OAuth2 URL Generator → `bot` scope, permissions: Send Messages, Embed Links, Read Message History → invite.

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

## Known gaps (to fix as separate PRs)

- `sidecars/{imessage,slack,telegram}-bot/src/config.py` reference `Path` and
  `os` inside `_runtime_toml_path()` without importing them — `BotConfig()`
  hits `NameError` the moment `TomlConfigSettingsSource` is wired. Discord is
  fine. Fix: add `from pathlib import Path` to all three, add `import os` to
  slack + telegram.
- No backend endpoint to start/stop a sidecar — currently the dashboard only
  advertises state written to `status.json`.
- No per-connector config-TOML write endpoint.
- No JSON-schema export endpoint for Pydantic models.

## References

- Mautrix bridges (`bridge.toml` pattern): https://docs.mau.fi/bridges/
- BlueBubbles (iMessage admin panel start/stop): https://bluebubbles.app/
- Matterbridge TOML sections: https://github.com/42wim/matterbridge
- Beeper desktop (tabbed per-network config): commercial reference only.
