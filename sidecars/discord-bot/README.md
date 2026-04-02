# MASC Discord Bot

Discord bot consumer for the MASC Channel Gate.

## Architecture

```
Discord <-> This Bot <-> Channel Gate (/api/v1/gate/*) <-> Keeper
```

This bot is a **protocol adapter**. It translates between Discord's API and
the Channel Gate's HTTP API. No business logic, no LLM calls.

## Setup

### 1. Create Discord Bot

1. Go to https://discord.com/developers/applications
2. New Application -> name it (e.g., "MASC Keeper")
3. Bot tab -> Reset Token -> copy the token
4. Bot tab -> enable "Message Content Intent"
5. OAuth2 -> URL Generator -> select "bot" scope
6. Select permissions: Send Messages, Embed Links, Read Message History
7. Copy the generated URL and open it to invite the bot to your server

### 2. Configure

```bash
cp .env.example .env
# Edit .env with your tokens and keeper mapping
```

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
