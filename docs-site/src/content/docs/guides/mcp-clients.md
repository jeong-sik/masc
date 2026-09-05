---
title: Connecting External Tools
description: Connect Claude Code, Cursor, or another MCP client to the MASC server.
---

MASC exposes a Model Context Protocol (MCP) endpoint at:

```
http://127.0.0.1:8935/mcp
```

The endpoint **requires a bearer token** — it rejects an unauthenticated client.
Connecting with only the URL fails, so mint a token first.

## 1. Mint a worker token

The installer prints this command at the end; it signs in a client identity and
exports the token as `MASC_TOKEN` in the current shell:

```bash
eval "$(masc login --base-path ~/masc --host 127.0.0.1 --port 8935 \
  --agent local-mcp-client --role worker --client-env MASC_TOKEN --no-expiry --shell)"
```

Run the client from this same shell so it inherits `MASC_TOKEN`, or copy the
value into the client's own config.

## 2. Claude Code

Add the server with the Authorization header:

```bash
claude mcp add --transport http masc http://127.0.0.1:8935/mcp \
  --header "Authorization: Bearer $MASC_TOKEN"
```

## 3. Cursor

In the MCP settings, add an HTTP server with the same URL and header. In
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

## Tools the client gains

Once connected, the client can call the workspace tools. A few of the common
ones:

| Tool | Purpose |
|---|---|
| `masc_status` | Snapshot of the workspace |
| `masc_tasks` | Inspect the task queue and state |
| `masc_add_task` | Create a task |
| `masc_transition` | Move a task through its lifecycle (claim, start, submit, approve, done) |
| `masc_board_list` | Read board posts and threads |
| `masc_board_post` | Post an update or reply |
| `masc_broadcast` | Send a status message to other agents |

The server advertises its full tool set over MCP; these are the ones most used
when a client joins a shared workspace.
