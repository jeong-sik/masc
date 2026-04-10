# Discord Gate Bot

Discord bot consumer for the Channel Gate.

## Architecture

```
Discord <-> This Bot <-> Channel Gate (/api/v1/gate/*) <-> Keeper
```

This bot is a **protocol adapter**. It translates between Discord's API and
the Channel Gate's HTTP API. No business logic, no LLM calls.

## What "Working" Means

The Discord path is healthy only when all of the following are true:

1. The MASC server is running and `/api/v1/gate/health` returns `ok=true`.
2. The Discord bot process is running and logged into Discord.
3. The bot and the server resolve the same runtime root for connector state.
4. `/api/v1/gate/discord/status` reports `connected=true`.

If the gate says `offline` with `connector status file not found`, the server is
up but the Discord bot has not written its runtime heartbeat yet.

## Quick Start

Run the bot from `sidecars/discord-bot`, but make sure its runtime root matches
the server's `MASC_BASE_PATH`.

```bash
cd ~/me/workspace/yousleepwhen/masc-mcp/sidecars/discord-bot
cp .env.example .env

# Required for shared connector state with the local MASC server.
export MASC_BASE_PATH=~/me

# Install dependencies once.
uv pip install -e ".[dev]"

# Start the bot from this directory so .env is auto-loaded.
python -m src
```

## Setup

### 1. Create Discord Bot

1. Go to https://discord.com/developers/applications
2. New Application -> name it (e.g., "Keeper Gateway")
3. Bot tab -> Reset Token -> copy the token
4. Bot tab -> enable "Message Content Intent"
5. OAuth2 -> URL Generator -> select "bot" scope
6. Select permissions: Send Messages, Embed Links, Read Message History
7. Copy the generated URL and open it to invite the bot to your server

### 2. Configure

```bash
cp .env.example .env
# Edit .env with your tokens and keeper mapping
# BotConfig auto-loads .env from the current working directory
```

`GATE_API_TOKEN` is recommended. For local loopback development only, the bot
can omit it when the server keeps `require_token=false`; in that mode the
connector falls back to same-origin auth headers against `127.0.0.1`/`localhost`.

### 3. Match The Server Runtime Root

By default the bot writes runtime files under:

- `.masc/connectors/discord/bindings.json`
- `.masc/connectors/discord/binding_audit.jsonl`
- `.masc/connectors/discord/status.json`

Relative paths resolve from `MASC_BASE_PATH` when it is set; otherwise they
resolve from the bot's current working directory.

For local development, the server usually owns the runtime root. The safest
pattern is:

```bash
export MASC_BASE_PATH=~/me
```

That keeps the bot aligned with a server process that also runs with
`MASC_BASE_PATH=~/me`, so both sides read and write the same connector state.

If you intentionally want sidecar-local files instead, set explicit paths in
`.env`:

```bash
DISCORD_BINDING_STORE_PATH=.gate/discord_bindings.json
DISCORD_BINDING_AUDIT_PATH=.gate/discord_binding_audit.jsonl
DISCORD_STATUS_PATH=.gate/discord_status.json
```

Use that mode only if the server is configured to read the same files via
`MASC_DISCORD_*` overrides or matching base-path rules.

### 4. Run

```bash
# Install dependencies
uv pip install -e ".[dev]"

# Run the bot
python -m src
```

### 5. Test

```bash
uv pip install -e ".[dev]"
pytest tests/
```

## Verify End-To-End

Before starting the bot:

```bash
curl -sfS http://127.0.0.1:8935/api/v1/gate/health
curl -sfS http://127.0.0.1:8935/api/v1/gate/discord/status
```

Expected state before the bot is ready:

- `/gate/health` returns `{"ok":true,...}`
- `/gate/discord/status` may show `offline`

After the bot is logged in and heartbeats are being written:

```bash
curl -sfS http://127.0.0.1:8935/api/v1/gate/discord/status
curl -sfS http://127.0.0.1:8935/api/v1/gate/connectors
```

Expected state after the bot is ready:

- `connected=true`
- `status="connected"`
- `status_path` points at the same runtime root the bot is using

If you want a quick process check:

```bash
ps -ef | rg "python(3)? -m src|discord-gate-bot"
```

## Channel-Keeper Mapping

The `DISCORD_KEEPER_MAP` environment variable maps Discord channel IDs to keeper names:

```json
{
  "1234567890": "luna",
  "9876543210": "sangsu"
}
```

Messages in mapped channels are automatically forwarded to the corresponding keeper.
Use the `/keeper-ask` slash command to talk to any keeper from any channel.

## Durable Runtime Bindings

`/keeper-bind` and `/keeper-unbind` now persist the effective channel map to
`DISCORD_BINDING_STORE_PATH` (default:
`.masc/connectors/discord/bindings.json`).

- If the store file does not exist, the bot starts from `DISCORD_KEEPER_MAP`
- Once an operator persists a runtime bind/unbind, the store file becomes the
  restart-time source of truth so admin changes survive process restarts
- `/keeper-map` shows the active binding source and store path for operators
- successful bind/unbind operations also append an audit record to
  `DISCORD_BINDING_AUDIT_PATH` (default:
  `.masc/connectors/discord/binding_audit.jsonl`)
- the bot also writes a direct runtime snapshot to `DISCORD_STATUS_PATH`
  (default: `.masc/connectors/discord/status.json`) every `STATUS_HEARTBEAT_SEC`
  seconds so the dashboard can show live Discord connection state
- runtime binding changes written by the dashboard are hot-reloaded by the bot
  without a process restart
- relative connector paths resolve from `MASC_BASE_PATH` when it is set; this
  keeps the bot on the same project data root as the MASC server
- when the new default binding path is empty but the legacy sidecar-local
  `.gate/discord_bindings.json` exists, the bot loads that legacy map as a
  compatibility fallback and reports `binding_source=legacy-fallback`

## Operations Upgrades

- `/keeper-status [keeper]`: connector health snapshot or single-keeper status
- `/keeper-bind <keeper>`: runtime bind current channel to a keeper
- `/keeper-unbind`: remove the current runtime binding
- `/keeper-map`: inspect resolved binding + loaded runtime map
- `/keeper-audit [limit]`: inspect recent bind/unbind audit entries
- Keeper names support slash-command autocomplete via `/api/v1/gate/keepers`
- dashboards and other read-only ops surfaces should prefer
  `/api/v1/gate/connectors`; it is the gate-owned connector descriptor surface
- The bot now forwards attachment-only messages by synthesizing a deterministic
  `Attachments:` block instead of dropping them as empty content
- A lightweight transport circuit breaker prevents repeated timeouts / 5xx
  storms from hammering the gate while still serving cached status data

## Troubleshooting

### Gate shows `offline`

Check these in order:

1. The bot process is running.
2. `MASC_BASE_PATH` matches the server runtime root.
3. `DISCORD_STATUS_PATH` resolves to the file the server is reading.
4. The bot token is valid and the bot has logged into Discord.

Useful checks:

```bash
curl -sfS http://127.0.0.1:8935/api/v1/gate/discord/status
ls -la ~/me/.masc/connectors/discord
```

### Messages are ignored in a channel

The bot only forwards messages from mapped channels.

Check:

- `DISCORD_KEEPER_MAP` in `.env`
- `/keeper-map`
- `/keeper-bind <keeper>`

### Dashboard bind/unbind works but the bot does not follow changes

The bot hot-reloads the durable binding store. If it does not react:

1. Confirm the dashboard and the bot are writing the same `bindings.json`.
2. Confirm the file mtime changes after bind/unbind.
3. Restart the bot once to rule out a stale process.
