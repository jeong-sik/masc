# Local Dashboard Auth Runbook

This runbook is the local operator path for dashboard-side keeper lifecycle actions such as:

- `POST /api/v1/keepers/:name/boot`
- `POST /api/v1/keepers/:name/shutdown`
- `PATCH /api/v1/keepers/:name/config`

Those routes are stricter than normal local `/mcp` calls:

- they require room auth enabled
- they require `require_token=true`
- they require an admin bearer token

If the dashboard can read state but keeper boot/config/shutdown fails, use this runbook.

## 1. Confirm the Real Base Path

Always check which `.masc` root the server is actually using before editing auth state.

```bash
curl -sS http://127.0.0.1:8935/health | jq '.paths'
```

Truth fields:

- `effective_base_path`
- `effective_masc_root`
- `cwd_masc_root`
- `roots_diverge`
- `strict_mode_requested`
- `startup_rejected`

If `effective_base_path` is not the base path you expected, fix that first. In shared `~/me` setups, the live auth store may be `~/me/.masc/auth` even when the server process is running from a sub-repo worktree.

## 2. Understand the Gate

Quick read:

```bash
curl -sS http://127.0.0.1:8935/api/v1/dashboard/shell | jq '.auth'
```

Important fields:

- `enabled`
- `require_token`
- `effective_role`
- `can_keeper_msg`
- `keeper_msg_error`

For dashboard-side keeper lifecycle control, the target shape is:

```json
{
  "enabled": true,
  "require_token": true,
  "effective_role": "admin"
}
```

## 3. Run `doctor auth`

Use the auth doctor before editing tokens or role files:

```bash
BASE_PATH="${MASC_BASE_PATH:-$HOME}"
./_build/default/bin/main_eio.exe doctor auth --base-path "$BASE_PATH"
```

Useful interpretations:

- `codex is role=worker, so requests authenticated as codex cannot satisfy CanAdmin.`
  - your bearer is valid, but it is the wrong role for admin-only routes
- `codex-mcp-client is role=worker, so dashboard save flows using that bearer will fail on admin-only routes such as POST /api/v1/cascade/config/raw.`
  - the dashboard is presenting a worker bearer, so raw cascade save is expected to 403
- `token_bound_admin_http_ready: no`
  - room auth may be enabled, but no usable admin bearer source was found
- `dashboard_dev_token: available=yes`
  - the easiest local bootstrap path is `GET /api/v1/dashboard/dev-token`
- `codex_mcp.token_status=unset` or `invalid_or_expired`
  - Codex MCP is missing a live bearer token; this is not fixed by `codex mcp login`
- `codex_mcp.config.stages[]`
  - Codex config pipeline checks for `[mcp_servers.masc]`, `bearer_token_env_var`,
    missing hardcoded `Authorization`, and the Streamable HTTP `Accept` header

If you want structured output for automation:

```bash
./_build/default/bin/main_eio.exe doctor auth --base-path "$BASE_PATH" --json \
  | jq '{status,codex_mcp:{token_status:.codex_mcp.token_status,config:.codex_mcp.config},warnings,next_actions}'
```

## 4. Codex MCP Bearer Login

`masc-mcp` uses bearer-token MCP auth. It does not expose an OAuth
authorization endpoint, so `codex mcp login masc` is expected to fail with
`No authorization support detected`.

For the Codex MCP server, the local startup path maintains a private
non-expiring worker bearer at
`$BASE_PATH/.masc/auth/codex-mcp-client.token`. Manual `login` is still useful
when bootstrapping or rotating the bearer; export the printed value as
`MASC_MCP_TOKEN` in the shell that starts Codex:

```bash
BASE_PATH="${MASC_BASE_PATH:-$HOME}"
./_build/default/bin/main_eio.exe login \
  --base-path "$BASE_PATH" \
  --agent codex-mcp-client \
  --role worker \
  --shell
```

Confirm the Codex-side registration points at the bearer env var:

```bash
codex mcp get masc
```

Expected shape:

```text
URL: http://127.0.0.1:8935/mcp
Bearer Token Env Var: MASC_MCP_TOKEN
```

If Codex still reports that `masc` is not logged in, check the pipeline
projection instead of retrying OAuth login:

```bash
./_build/default/bin/main_eio.exe doctor auth --base-path "$BASE_PATH" --json \
  | jq '.codex_mcp.config.stages'
```

Every required config stage should be `pass`; `codex_oauth_login` is expected
to be `skip` because MASC uses bearer-token auth.

### Codex Config Drift and Authorization Header Hardening

External config generation scripts (e.g. `init-codex-config.sh`,
`mcp-sync.sh`) can regress the Codex config if they overwrite
`~/.codex/config.toml` without preserving the `[mcp_servers.masc]` stanza, or
if they inject a literal `Authorization = "Bearer ..."` header.

The canonical `[mcp_servers.masc]` shape — as checked by `doctor auth` — is:

```toml
[mcp_servers.masc]
url = "http://127.0.0.1:8935/mcp"
bearer_token_env_var = "MASC_MCP_TOKEN"
http_headers = { "Accept" = "application/json, text/event-stream", "X-MASC-Agent" = "codex-mcp-client" }
```

**Do not include `Authorization = "Bearer ..."` inside `[mcp_servers.masc]`.**
The server reads the token from `MASC_MCP_TOKEN` at runtime via
`bearer_token_env_var`; hardcoding a literal token in the config file persists
the raw value on disk and causes auth drift when the token is rotated.

To initialise or repair the Codex config from the repo:

```bash
BASE_PATH="${MASC_BASE_PATH:-$HOME}"
scripts/init-codex-mcp-config.sh --base-path "$BASE_PATH"
```

To let the server auto-repair the config on startup, set:

```bash
export MASC_SYNC_CODEX_MCP_CONFIG=1
```

The startup sync replaces any `http_headers` binding with the canonical form
and strips any bare `Authorization = ...` binding directly in
`[mcp_servers.masc]`.  It does **not** touch other MCP server sections or
sub-sections.

## 5. Claude / Gemini MCP Bearers

Claude and Gemini must not reuse the Codex bearer. Mint each local MCP client
as its own worker identity, then sync the shared client config:

```bash
BASE_PATH="${MASC_BASE_PATH:-$HOME/me}"

./_build/default/bin/main_eio.exe login \
  --base-path "$BASE_PATH" \
  --agent claude \
  --role worker \
  --shell

./_build/default/bin/main_eio.exe login \
  --base-path "$BASE_PATH" \
  --agent gemini \
  --role worker \
  --shell

~/me/scripts/mcp-sync.sh
```

Local startup also self-heals private non-expiring token files for `claude` and
`gemini`. Manual `login` is for first-time setup or explicit rotation; after
that, `~/me/scripts/mcp-sync.sh` can project those token files into client
config.

**Gemini and Claude configs should also use `bearer_token_env_var` (not a
hardcoded `Authorization` header).** The `mcp-sync.sh` pattern should export
`MASC_CLAUDE_MCP_TOKEN` and `MASC_GEMINI_MCP_TOKEN` from the respective token
files rather than embedding literal tokens in the config.

`doctor auth --json` exposes `.mcp_clients[]`; `claude` should use
`MASC_CLAUDE_MCP_TOKEN` / `X-MASC-Agent: claude`, and `gemini` should use
`MASC_GEMINI_MCP_TOKEN` / `X-MASC-Agent: gemini`.

## 6. Supported Local Start

When running from a worktree but using a shared local coordination root, start the server with an explicit base path:

```bash
BASE_PATH="${MASC_BASE_PATH:-$HOME}"
MASC_BASE_PATH="$BASE_PATH" \
./_build/default/bin/main_eio.exe \
  --host 127.0.0.1 \
  --port 8935 \
  --base-path "$BASE_PATH"
```

Then run `./_build/default/bin/main_eio.exe doctor --base-path "$BASE_PATH"` and re-check `/health` to confirm the effective base path is the path you intended.

## 7. Bootstrap an Admin Bearer

If you already have an admin bearer, skip to step 7.

The shortest local CLI path is:

```bash
BASE_PATH="${MASC_BASE_PATH:-$HOME}"
./_build/default/bin/main_eio.exe login \
  --base-path "$BASE_PATH" \
  --agent codex-local-admin \
  --role admin
```

The command prints the raw bearer once, writes the matching private raw-token
file under the live auth root, and includes a dashboard URL.

If `doctor auth` says `dashboard_dev_token: available=yes`, the easiest local path is the dev-token bootstrap:

```bash
TOKEN="$(curl -sS http://127.0.0.1:8935/api/v1/dashboard/dev-token | jq -r '.token')"
printf 'token=%s\n' "$TOKEN"
```

This endpoint is loopback-only and disabled when HTTP strict auth is enabled.

If you do not have that path, the reliable local fallback is to seed the auth store directly.

1. Back up the auth config:

```bash
BASE_PATH="${MASC_BASE_PATH:-$HOME}"
cp "$BASE_PATH/.masc/auth/config.json" "$BASE_PATH/.masc/auth/config.json.bak"
```

2. Generate a token and its SHA256 hash:

```bash
TOKEN="$(openssl rand -hex 32)"
HASH="$(printf '%s' "$TOKEN" | shasum -a 256 | awk '{print $1}')"
CREATED="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
EXPIRES="$(date -u -v+72H +"%Y-%m-%dT%H:%M:%SZ")"  # BSD (macOS)
# GNU/Linux alternative:
# EXPIRES="$(date -u -d '+72 hours' +"%Y-%m-%dT%H:%M:%SZ")"
printf 'token=%s\nhash=%s\n' "$TOKEN" "$HASH"
```

3. Write an admin credential file under the live auth root:

```json
{
  "agent_name": "codex-tool-matrix",
  "token": "<sha256 hash>",
  "role": "admin",
  "created_at": "<created_at>",
  "expires_at": "<expires_at>"
}
```

Path:

```text
<effective_base_path>/.masc/auth/agents/codex-tool-matrix.json
```

4. Set `require_token=true` in the live auth config:

```json
{
  "enabled": true,
  "require_token": true
}
```

Path:

```text
<effective_base_path>/.masc/auth/config.json
```

Notes:

- the server stores only the SHA256 hash, not the raw bearer
- keep the raw bearer outside the repo
- this is for trusted local operator use, not a remote/public bootstrap path

## 8. Open the Dashboard as Admin

Pass the token once via query string. The dashboard moves it into `sessionStorage` and removes it from the URL.

```text
http://127.0.0.1:8935/dashboard?agent=codex-tool-matrix&token=<raw-token>
```

For a dev-token bootstrap, use `agent=dashboard-dev` instead.

You can verify the session with:

```bash
curl -sS http://127.0.0.1:8935/api/v1/dashboard/shell \
  -H "Authorization: Bearer <raw-token>" \
  -H "X-MASC-Agent: codex-tool-matrix" \
  | jq '.auth'
```

Expected:

- `token_present=true`
- `effective_agent="codex-tool-matrix"`
- `effective_role="admin"`

## 9. Verify Admin-Only Routes

Use a low-risk keeper first.

Raw cascade save:

```bash
curl -sS -X POST http://127.0.0.1:8935/api/v1/cascade/config/raw \
  -H "Authorization: Bearer <raw-token>" \
  -H "X-MASC-Agent: <admin-agent>" \
  -H "Content-Type: application/json" \
  -d @payload.json
```

`payload.json`:

```json
{
  "source_text": "{ ...raw cascade json... }"
}
```

If the request is authenticated as `codex` or `codex-mcp-client` with `role=worker`,
this route should fail with a `CanAdmin` error by design.

Boot:

```bash
curl -sS -X POST http://127.0.0.1:8935/api/v1/keepers/<keeper>/boot \
  -H "Authorization: Bearer <raw-token>" \
  -H "X-MASC-Agent: codex-tool-matrix"
```

Shutdown:

```bash
curl -sS -X POST http://127.0.0.1:8935/api/v1/keepers/<keeper>/shutdown \
  -H "Authorization: Bearer <raw-token>" \
  -H "X-MASC-Agent: codex-tool-matrix"
```

Then inspect the execution snapshot:

```bash
curl -sS http://127.0.0.1:8935/api/v1/dashboard/execution \
  -H "Authorization: Bearer <raw-token>" \
  -H "X-MASC-Agent: codex-tool-matrix" \
  | jq '.keepers[] | select(.name=="<keeper>") | {name,status,paused,trace_id,active_model}'
```

## 10. Rollback

If you need to go back to anonymous loopback behavior:

1. restore the config backup
2. remove the seeded credential file
3. restart the server

Example:

```bash
BASE_PATH="${MASC_BASE_PATH:-$HOME}"
mv "$BASE_PATH/.masc/auth/config.json.bak" "$BASE_PATH/.masc/auth/config.json"
rm -f "$BASE_PATH/.masc/auth/agents/codex-tool-matrix.json"
```

If you used only `dashboard-dev` dev-token bootstrap, there may be no auth files to roll back.

## 10. Known Failure Modes

- `effective_base_path` points somewhere else:
  you edited the wrong `.masc/auth` tree
- `require_token=false`:
  dashboard keeper boot/config/shutdown remains blocked even with auth enabled
- `effective_role=worker`:
  your bearer is valid but not admin
- `codex cannot CanAdmin` or `codex-mcp-client is role=worker`:
  the request is authenticated with a worker bearer; rerun `doctor auth` and switch to an admin bearer
- `{"error":"not found"}` on keeper boot/shutdown:
  you may still be running an older server build without the fixed route classifier
