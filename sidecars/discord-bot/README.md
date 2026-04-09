# Discord Gate Bot

Discord bot consumer for the Channel Gate.

## Architecture

```
Discord <-> This Bot <-> Channel Gate (/api/v1/gate/*) <-> Keeper
```

This bot is a **protocol adapter**. It translates between Discord's API and
the Channel Gate's HTTP API. No business logic, no LLM calls.

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

### 3. Run

```bash
# Install dependencies
uv pip install -e ".[dev]"

# Run the bot
python -m src
```

### 4. Test

```bash
uv pip install -e ".[dev]"
pytest tests/
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
