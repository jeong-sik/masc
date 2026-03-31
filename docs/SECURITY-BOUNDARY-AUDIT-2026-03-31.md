# Security Boundary Audit 2026-03-31

## Summary

- Scope: full boundary audit across `/mcp`, `/mcp/operator`, dashboard HTTP routes, WebRTC signaling, code tools, and dashboard auth plumbing.
- Environment used for repro:
  - Server: `main_eio.exe --host=127.0.0.1 --port=9127`
  - Effective base path from `/health`: repo git root, not the worktree input path
  - Auth state: room auth disabled, default local-first posture
- Result:
  - `critical`: 1
  - `high`: 2
  - `medium`: 2

## Findings

### Critical: code tool path validation is prefix-only and escapes repository boundaries

- Code basis:
  - [lib/tool_code.ml](/Users/dancer/me/workspace/yousleepwhen/masc-mcp/.worktrees/audit-boundaries-20260331/lib/tool_code.ml#L44)
  - [lib/tool_code_write.ml](/Users/dancer/me/workspace/yousleepwhen/masc-mcp/.worktrees/audit-boundaries-20260331/lib/tool_code_write.ml#L25)
- Why it fails:
  - `validate_path` concatenates raw input and accepts it when `String.starts_with ~prefix:git_root absolute_path`.
  - No `realpath` or separator-aware containment check is applied.
  - `validate_writable_path` reuses the same unchecked path and applies another prefix check to `.worktrees`.
- Repro:
  - `masc_code_read` successfully read `/Users/dancer/me/workspace/yousleepwhen/masc-mcp-audit-sibling/proof.txt`, a sibling path outside repo root.
  - `masc_code_write` successfully wrote `.worktrees/../../masc-mcp-write-outside/proof-write.txt`, which resolved to `/Users/dancer/me/workspace/yousleepwhen/masc-mcp-write-outside/proof-write.txt`.
- Impact:
  - Full MCP callers can read outside-repo files.
  - Full MCP callers can write outside `.worktrees/` and outside the repo entirely.
  - `masc_code_edit`, `masc_code_delete`, and `masc_code_shell` inherit the same boundary weakness through shared validation.
- Classification: `code bug`
- Remediation order: `P0`
- Tracking issue: `#4241`

### High: `with_tool_auth` routes permit unauthenticated HTTP mutation when room auth is disabled

- Code basis:
  - [lib/server/server_auth.ml](/Users/dancer/me/workspace/yousleepwhen/masc-mcp/.worktrees/audit-boundaries-20260331/lib/server/server_auth.ml#L343)
  - [lib/server/server_routes_http_routes_command_plane_write.ml](/Users/dancer/me/workspace/yousleepwhen/masc-mcp/.worktrees/audit-boundaries-20260331/lib/server/server_routes_http_routes_command_plane_write.ml#L383)
  - [lib/server/server_routes_http_routes_frontend.ml](/Users/dancer/me/workspace/yousleepwhen/masc-mcp/.worktrees/audit-boundaries-20260331/lib/server/server_routes_http_routes_frontend.ml#L39)
- Why it fails:
  - No-token requests only run `ensure_same_origin_browser_request` when an `Origin` header exists.
  - Plain `curl` without `Origin` passes.
  - When auth is disabled and strict HTTP auth is off, `Auth.authorize_tool` allows the request as default actor `dashboard`.
- Repro:
  - `POST /api/v1/operator/action` without token returned `confirm_required=true` and minted a live confirm token.
  - `POST /api/v1/operator/confirm` without token executed the previously previewed `room_pause`.
  - `POST /api/v1/tools/masc_board_post` without token created a board post as `dashboard`.
  - `POST /webrtc/offer` without token returned a valid `offer_id`.
- Impact:
  - Any local process can mutate room state, operator state, board state, and transport signaling over HTTP.
  - The route comments imply "localhost-friendly browser" behavior, but the actual contract is "unauthenticated client allowed when auth is off".
  - This is materially weaker than `/mcp/operator`, which correctly rejected unauthenticated access with `401`.
- Classification: `code bug`
- Remediation order: `P0`
- Tracking issue: `#4240`

### High: dashboard bearer token is sourced from query string and propagated into SSE URL

- Code basis:
  - [dashboard/src/api/core.ts](/Users/dancer/me/workspace/yousleepwhen/masc-mcp/.worktrees/audit-boundaries-20260331/dashboard/src/api/core.ts#L26)
  - [dashboard/src/sse.ts](/Users/dancer/me/workspace/yousleepwhen/masc-mcp/.worktrees/audit-boundaries-20260331/dashboard/src/sse.ts#L140)
- Why it fails:
  - The dashboard reads `?token=` from `window.location.search`.
  - The same token is copied into the EventSource URL `/mcp?...&token=...`.
- Impact:
  - Bearer credentials can leak via browser history, screenshots, shared links, referrer propagation, and logs that capture URLs.
  - SSE reconnect logic keeps reusing the query token, extending the exposure window.
- Classification: `code bug`
- Remediation order: `P1`
- Tracking issue: `#4242`

### Medium: transport defaults and auth defaults leave the boundary model easy to misread

- Code basis:
  - [lib/config/env_config_runtime.ml](/Users/dancer/me/workspace/yousleepwhen/masc-mcp/.worktrees/audit-boundaries-20260331/lib/config/env_config_runtime.ml#L244)
  - [lib/server/server_auth.ml](/Users/dancer/me/workspace/yousleepwhen/masc-mcp/.worktrees/audit-boundaries-20260331/lib/server/server_auth.ml#L47)
- Observation:
  - `MASC_WS_ENABLED` and `MASC_WEBRTC_ENABLED` default to `true`.
  - `MASC_HTTP_AUTH_STRICT` defaults to `false`.
  - Strict token auth only turns on automatically for non-loopback bind or public `MASC_HTTP_BASE_URL`.
- Impact:
  - The server is explicitly local-first, but the active transport footprint is broader than a reader may assume.
  - Operators can think "operator remote is protected" while adjacent local HTTP write surfaces remain weak by default.
- Classification: `boundary ambiguity`
- Remediation order: `P2`

### Medium: command-plane policy allowlists are stored but not enforced on main

- Code basis:
  - [lib/tool_misc_admin.ml](/Users/dancer/me/workspace/yousleepwhen/masc-mcp/.worktrees/audit-boundaries-20260331/lib/tool_misc_admin.ml#L173)
- Observation:
  - `unit.policy.tool_allowlist` and `unit.policy.model_allowlist` are explicitly reported as `advisory_only`.
- Impact:
  - Control-plane topology can imply a stronger runtime boundary than actually exists.
  - This is not a direct exploit by itself, but it weakens operator assumptions during incident response and supervision.
- Classification: `boundary ambiguity`
- Remediation order: `P3`

## Route Notes

- Correctly locked:
  - `/mcp/operator` rejected unauthenticated access with `401` during audit.
- Dangerous by default when room auth is off:
  - `/api/v1/operator/action`
  - `/api/v1/operator/confirm`
  - `/api/v1/tools/masc_board_post`
  - `/webrtc/offer`
- Full MCP surface is also unauthenticated in the default local-first posture, which makes the path validation bug immediately reachable.

## Recommended Fix Order

1. Replace prefix-based path checks with canonical, separator-aware containment checks in code read/write tools.
2. Make `with_tool_auth` genuinely token-bound for mutation routes, or reject no-token requests unless an explicit dev-only mode is enabled.
3. Remove query-string bearer handling from the dashboard and SSE bootstrap.
4. Make the public docs and `/health` posture explicit about which boundaries are convenience-mode vs enforced-mode.
5. Either enforce command-plane allowlists or stop presenting them as policy surfaces.
