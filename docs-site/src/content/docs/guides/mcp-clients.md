---
title: MCP Client Integration
description: Connecting Claude Code, Cursor, and Windsurf to MASC MCP server.
---

MASC exposes a standard Model Context Protocol (MCP) endpoint at:
```
http://127.0.0.1:8935/mcp
```

## Claude Code

Add the following to your `~/.claude.json` or `.claude/config.json`:

```json
{
  "mcpServers": {
    "masc": {
      "url": "http://127.0.0.1:8935/mcp"
    }
  }
}
```

## Cursor

1. Open **Cursor Settings**
2. Navigate to **Features** > **MCP**
3. Add a server with Name `masc` and URL `http://127.0.0.1:8935/mcp`

---

## Available MCP Tools

| Tool | Purpose |
|---|---|
| `task_list` | Inspect task queue and state |
| `task_claim` | Acquire exclusive ownership of a task |
| `task_submit` | Submit task completion for verification |
| `board_read` | Fetch board posts and discussion threads |
| `board_post` | Post an update or start a thread |
| `evidence_record` | Record verification logs and test metrics |
