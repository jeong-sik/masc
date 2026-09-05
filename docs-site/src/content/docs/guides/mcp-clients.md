---
title: Connecting MCP clients
description: Attach an MCP client to the MASC server, with the config masc mcp-config emits or by hand.
---

MASC speaks the Model Context Protocol here:

```
http://127.0.0.1:8935/mcp
```

The endpoint **requires a bearer token** — an unauthenticated request is a
`401`. A URL on its own does not connect.

## What masc writes for you

`masc mcp-config` mints the token and prints the config block. `--client` takes
one of three:

| `--client` | What it emits |
| --- | --- |
| `env` (default) | Shell exports — any client that reads the bearer from the environment |
| `codex` | TOML for Codex |
| `claude-desktop` | `mcp-remote` JSON for Claude Desktop |

```bash
masc mcp-config --base-path ~/masc --client codex
```

`--client-env` renames the variable (default `MASC_TOKEN`). The token is
long-lived by default, because a local MCP daemon cannot refresh itself on
expiry; pass `--expiring` for a session-scoped one.

## Clients you wire by hand

**Nothing else has an emitter.** The two below are worked examples, and any
other MCP client attaches the same way: same URL, same header.

Mint a token into the current shell first.

```bash
eval "$(masc login --base-path ~/masc --host 127.0.0.1 --port 8935 \
  --agent local-mcp-client --role worker --client-env MASC_TOKEN --no-expiry --shell)"
```

### Claude Code

```bash
claude mcp add --transport http masc http://127.0.0.1:8935/mcp \
  --header "Authorization: Bearer $MASC_TOKEN"
```

### Cursor, and anything else configured with JSON

`~/.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "masc": {
      "url": "http://127.0.0.1:8935/mcp",
      "headers": { "Authorization": "Bearer <paste MASC_TOKEN>" }
    }
  }
}
```

## Managing the tokens

The workspace stores only a SHA-256 of each token. The bearer itself survives in
one place: `.masc/auth/<agent>.token`, mode `0600`.

```bash
masc token list                 # what bearers exist
masc token revoke --agent NAME  # retire one
masc token prune                # only the expired ones
```

Minting the same agent name again replaces the credential — that is how you
rotate.

## Tools a client gets
