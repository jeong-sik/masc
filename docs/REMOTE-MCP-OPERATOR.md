# Remote MCP Operator

`/mcp/operator` is the remote-safe MCP surface for operating a MASC room from external MCP clients.

## Purpose

- Keep the public remote surface small and deterministic.
- Expose only the operator control plane, not the full `masc_*` tool inventory.
- Enforce preview and confirmation for disruptive actions.

## Endpoint

- Streamable HTTP / SSE endpoint: `GET|POST|DELETE /mcp/operator`
- Authentication: bearer token only
- Tool surface: exactly 4 tools
  - `masc_operator_snapshot`
  - `masc_operator_digest`
  - `masc_operator_action`
  - `masc_operator_confirm`

Unlike the local `/mcp` endpoint, `/mcp/operator` does not expose the full room tool set.

## Authentication

`/mcp/operator` requires room auth to be enabled with `require_token=true`.

- If auth is disabled, initialize fails.
- If bearer token auth is not enabled, initialize fails.
- Clients must send `Authorization: Bearer <token>`.
- When a token is present, the server resolves operator identity from the token-bound credential and does not let transient MCP session aliases override it.

## Tool Model

### `masc_operator_snapshot`

Read-only room control-plane view.

- Returns room summary, sessions, keepers, recent messages, pending confirmations, available actions, `trace_id`, and server profile metadata.
- Supports `view` values: `summary`, `sessions`, `keepers`, `messages`, `full`.
- `view="summary"` and `view="full"` also include lightweight `attention_summary` and `recommendation_summary` counts.

### `masc_operator_digest`

Intervention-oriented read model.

- Use this when raw snapshot data is too low-level and you need actionable supervision hints.
- Returns `health`, prioritized `attention_items`, advisory `recommended_actions`, and session/worker cards.
- Supports room-wide digests and session-targeted digests through `target_type` and `target_id`.

### `masc_operator_action`

Structured operator action preview/execute entrypoint.

Supported `action_type` values on the remote surface:

- `broadcast`
- `room_pause`
- `room_resume`
- `team_note`
- `team_broadcast`
- `team_task_inject`
- `team_stop`
- `keeper_message`

Legacy aliases such as `team_turn`, `task_inject`, and `keeper_msg` remain accepted on the local operator surface, but are intentionally excluded from the remote MCP schema.

### `masc_operator_confirm`

Second-step execution entrypoint for actions that return `confirm_required=true`.

- Confirm tokens are short-lived.
- Expired or reused tokens are rejected.
- Remote clients should treat `masc_operator_action` as the only way to obtain a confirm token.

## Confirmation Policy

Immediate actions:

- `broadcast`
- `room_resume`
- `team_note`
- `team_broadcast`
- `keeper_message`

Preview + confirm actions:

- `room_pause`
- `team_task_inject`
- `team_stop`

The server also marks read-only vs write actions through MCP annotations so clients that respect `readOnlyHint` can present safer UX defaults.

## Codex Configuration

Use a streamable HTTP MCP server entry in `~/.codex/config.toml` or project `.codex/config.toml`.

```toml
[mcp_servers.masc_operator]
url = "https://your-host.example.com/mcp/operator"
bearer_token_env_var = "MASC_OPERATOR_TOKEN"
enabled_tools = [
  "masc_operator_snapshot",
  "masc_operator_digest",
  "masc_operator_action",
  "masc_operator_confirm",
]
startup_timeout_sec = 20
tool_timeout_sec = 60
```

Optional static or environment-backed headers can also be used when the client supports them.

## Claude Code

Claude Code can connect to remote MCP servers. Register the same `/mcp/operator` URL and bearer token in the client's MCP configuration, and keep the exposed tool allowlist restricted to the operator quartet.

Recommended usage pattern:

1. Call `masc_operator_snapshot(view="summary")`.
2. Call `masc_operator_digest`.
3. Call `masc_operator_action`.
4. If `confirm_required=true`, inspect the preview and then call `masc_operator_confirm`.

## ChatGPT Developer Mode

This endpoint is shaped to be compatible with remote MCP onboarding patterns used by ChatGPT Developer Mode:

- transport: `SSE` and streamable HTTP
- tool descriptions: action-oriented and explicit
- read/write detection: `readOnlyHint`
- write safety: confirmation-first flow

This repo does not yet implement the OAuth/DCR flow needed for first-class ChatGPT app onboarding. Treat ChatGPT Developer Mode support as protocol-ready, not fully productized.

## Scope Boundaries

`/mcp/operator` intentionally excludes:

- full `masc_*` tool inventory
- A2A delegation surface
- swarm control tools
- TRPG tools
- keeper lifecycle mutation tools such as `masc_keeper_up`

If you need the complete local tool surface, use `/mcp` in a trusted environment instead.

## Operational Notes

- Keep the remote actor name stable so audit logs remain attributable.
- Prefer `view="summary"` for polling dashboards and `view="full"` for active interventions.
- For automation, treat `trace_id` as the correlation key for operator action logs.

## References

- OpenAI Codex MCP config reference: https://developers.openai.com/codex/mcp/#streamable-http-servers
- OpenAI Codex config reference: https://developers.openai.com/codex/config-reference/#configtoml
- OpenAI ChatGPT Developer Mode: https://developers.openai.com/api/docs/guides/developer-mode/#how-to-use
- Anthropic Claude Code MCP docs: https://docs.anthropic.com/en/docs/claude-code/mcp
