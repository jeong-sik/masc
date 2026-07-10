# Local Dashboard Auth Runbook

This runbook is the local operator path for dashboard-side keeper lifecycle actions such as:

- `POST /api/v1/keepers/:name/boot`
- `POST /api/v1/keepers/:name/shutdown`
- `PATCH /api/v1/keepers/:name/config`

Those routes are stricter than normal local `/mcp` calls:

- they require workspace auth enabled
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

If `effective_base_path` is not the base path you expected, fix that first. In shared workspace setups, the live auth store is `<base-path>/.masc/auth` even when the server process is running from a sub-repo worktree.

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

## 3. Run auth login diagnostics

Use login JSON before editing tokens or role files:

```bash
BASE_PATH="${MASC_BASE_PATH:-/path/to/base}"
MASC_BASE_PATH="$BASE_PATH" ./_build/default/bin/main_eio.exe login --json
```

Useful interpretations:

- `agent-code is role=worker, so requests authenticated as agent-code cannot satisfy CanAdmin.`
  - your bearer is valid, but it is the wrong role for admin-only routes
- `agent-code-mcp-client is role=worker, so dashboard save flows using that bearer will fail on admin-only routes such as POST /api/v1/runtime/config/raw.`
  - the dashboard is presenting a worker bearer, so raw runtime save is expected to 403
- `token_bound_admin_http_ready: no`
  - workspace auth may be enabled, but no usable admin bearer source was found
- `dashboard_dev_token: available=yes`
  - the easiest local bootstrap path is `GET /api/v1/dashboard/dev-token`
- `codex_mcp.token_status=unset` or `invalid_or_expired`
  - Agent-Code MCP is missing a live bearer token; this is not fixed by `agent-code mcp login`
- `codex_mcp.config.stages[]`
  - Agent-Code config pipeline checks for `[mcp_servers.masc]`, `bearer_token_env_var`,
    missing hardcoded `Authorization`, and the Streamable HTTP `Accept` header

If you want structured output for automation:

```bash
MASC_BASE_PATH="$BASE_PATH" ./_build/default/bin/main_eio.exe login --json \
  | jq '{status,codex_mcp:{token_status:.codex_mcp.token_status,config:.codex_mcp.config},warnings,next_actions}'
```

## 4. Agent-Code MCP Bearer Login

`masc` uses bearer-token MCP auth. It does not expose an OAuth
authorization endpoint, so `agent-code mcp login masc` is expected to fail with
`No authorization support detected`.

For the Agent-Code MCP server, the local startup path maintains a private
non-expiring worker bearer at
`$BASE_PATH/.masc/auth/agent-code-mcp-client.token`. Manual `login` is still useful
when bootstrapping or rotating the bearer; export the printed value as
`MASC_TOKEN` in the shell that starts Agent-Code:

```bash
BASE_PATH="${MASC_BASE_PATH:-/path/to/base}"
./_build/default/bin/main_eio.exe login \
  --base-path "$BASE_PATH" \
  --agent agent-code-mcp-client \
  --role worker \
  --shell
```

Confirm the Agent-Code-side registration points at the bearer env var:

```bash
agent-code mcp get masc
```

Expected shape:

```text
URL: http://127.0.0.1:8935/mcp
Bearer Token Env Var: MASC_TOKEN
```

If Agent-Code still reports that `masc` is not logged in, check the pipeline
projection instead of retrying OAuth login:

```bash
MASC_BASE_PATH="$BASE_PATH" ./_build/default/bin/main_eio.exe login --json \
  | jq '.codex_mcp.config.stages'
```

Every required config stage should be `pass`; `codex_oauth_login` is expected
to be `skip` because MASC uses bearer-token auth.

### Agent-Code Config Drift and Authorization Header Hardening

External config generation scripts (e.g. `init-agent-code-config.sh`,
`mcp-sync.sh`) can regress the Agent-Code config if they overwrite
`~/.agent-code/config.toml` without preserving the `[mcp_servers.masc]` stanza, or
if they inject a literal `Authorization = "Bearer ..."` header.

The canonical `[mcp_servers.masc]` shape — as checked by login JSON — is:

```toml
[mcp_servers.masc]
url = "http://127.0.0.1:8935/mcp"
bearer_token_env_var = "MASC_TOKEN"
http_headers = { "Accept" = "application/json, text/event-stream", "X-MASC-Agent" = "agent-code-mcp-client" }
```

**Do not include `Authorization = "Bearer ..."` inside `[mcp_servers.masc]`.**
The server reads the token from `MASC_TOKEN` at runtime via
`bearer_token_env_var`; hardcoding a literal token in the config file persists
the raw value on disk and causes auth drift when the token is rotated.

To initialise or repair the Agent-Code config from the repo:

```bash
BASE_PATH="${MASC_BASE_PATH:-/path/to/base}"
scripts/init-agent-code-mcp-config.sh --base-path "$BASE_PATH"
```

To let the server auto-repair the config on startup, set:

```bash
export MASC_SYNC_AGENT-CODE_MCP_CONFIG=1
```

The startup sync replaces any `http_headers` binding with the canonical form
and strips any bare `Authorization = ...` binding directly in
`[mcp_servers.masc]`.  It does **not** touch other MCP server sections or
sub-sections.

## 5. Agent-LLM-A / Provider-F MCP Bearers

> **MASC is MCP-client-agnostic.** The server holds no list of "known" clients
> and does not derive env-var names from `--agent`. The operator names the env
> var with `--client-env <VAR>` and chooses the lifetime with `--no-expiry`.
> The conventions below are recommendations for the local wrapper script
> (`~/me/scripts/mcp-sync.sh`), not server policy.

Each local MCP client must mint its own worker identity so its bearer is
distinct from the Agent-Code bearer. Pick a per-client env var name (e.g.
`MASC_AGENT-LLM-A_MCP_TOKEN`, `MASC_PROVIDER-F_MCP_TOKEN`) and pass it in via
`--client-env`. Long-running local MCP daemons typically want `--no-expiry` so
their bearer survives across daemon restarts.

```bash
BASE_PATH="${MASC_BASE_PATH:-/path/to/base}"

./_build/default/bin/main_eio.exe login \
  --base-path "$BASE_PATH" \
  --agent agent-llm-a \
  --role worker \
  --client-env MASC_AGENT-LLM-A_MCP_TOKEN \
  --no-expiry \
  --shell

./_build/default/bin/main_eio.exe login \
  --base-path "$BASE_PATH" \
  --agent provider-f \
  --role worker \
  --client-env MASC_PROVIDER-F_MCP_TOKEN \
  --no-expiry \
  --shell

~/me/scripts/mcp-sync.sh
```

Manual `login` is for first-time setup or explicit rotation; after that,
`~/me/scripts/mcp-sync.sh` projects the token files into client config.

**Provider-F and Agent-LLM-A configs should use `bearer_token_env_var` (not a
hardcoded `Authorization` header).** The `mcp-sync.sh` pattern should export
`MASC_AGENT-LLM-A_MCP_TOKEN` and `MASC_PROVIDER-F_MCP_TOKEN` from the respective token
files rather than embedding literal tokens in the config.

Recommended local convention (enforced by the operator's wrapper, not the
server): `agent-llm-a` should use `MASC_AGENT-LLM-A_MCP_TOKEN` / `X-MASC-Agent: agent-llm-a`,
and `provider-f` should use `MASC_PROVIDER-F_MCP_TOKEN` / `X-MASC-Agent: provider-f`.

`login --json` no longer exposes a `.mcp_clients[]` section; compose
per-client readiness checks externally over the raw login output and your
own client roster.

## 6. Supported Local Start

When running from a worktree but using a shared local workspace collaboration root, start the server with an explicit base path:

```bash
BASE_PATH="${MASC_BASE_PATH:-/path/to/base}"
MASC_BASE_PATH="$BASE_PATH" \
./_build/default/bin/main_eio.exe \
  --host 127.0.0.1 \
  --port 8935 \
  --base-path "$BASE_PATH"
```

Then rerun the login JSON and `/health` checks with `MASC_BASE_PATH="$BASE_PATH"` to confirm the effective base path is the path you intended.

## 7. Bootstrap an Admin Bearer

If you already have an admin bearer, skip to step 7.

The shortest local CLI path is:

```bash
BASE_PATH="${MASC_BASE_PATH:-/path/to/base}"
./_build/default/bin/main_eio.exe login \
  --base-path "$BASE_PATH" \
  --agent agent-code-local-admin \
  --role admin
```

The command prints the raw bearer once, writes the matching private raw-token
file under the live auth root, and includes a dashboard URL.

If login JSON says `dashboard_dev_token: available=yes`, the easiest local path is the dev-token bootstrap:

```bash
TOKEN="$(curl -sS http://127.0.0.1:8935/api/v1/dashboard/dev-token | jq -r '.token')"
printf 'token=%s\n' "$TOKEN"
```

This endpoint is loopback-only and disabled when HTTP strict auth is enabled.

If you do not have that path, the reliable local fallback is to seed the auth store directly.

1. Back up the auth config:

```bash
BASE_PATH="${MASC_BASE_PATH:-/path/to/base}"
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
  "agent_name": "agent-code-tool-matrix",
  "token": "<sha256 hash>",
  "role": "admin",
  "created_at": "<created_at>",
  "expires_at": "<expires_at>"
}
```

Path:

```text
<effective_base_path>/.masc/auth/agents/agent-code-tool-matrix.json
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

Open the dashboard without putting the bearer in the URL:

```text
http://127.0.0.1:8935/dashboard?agent=agent-code-tool-matrix
```

Paste the raw bearer into the dashboard auth control. The dashboard keeps that
manual token in `sessionStorage` and sends it in the `Authorization` header;
it does not put the credential in URL history, request logs, or referrers.

For a dev-token bootstrap, use `agent=dashboard-dev` instead. The bootstrap
credential is still transported in the `Authorization` header.

You can verify the session with:

```bash
curl -sS http://127.0.0.1:8935/api/v1/dashboard/shell \
  -H "Authorization: Bearer <raw-token>" \
  -H "X-MASC-Agent: agent-code-tool-matrix" \
  | jq '.auth'
```

Expected:

- `token_present=true`
- `effective_agent="agent-code-tool-matrix"`
- `effective_role="admin"`

## 9. Verify Admin-Only Routes

Use a low-risk keeper first.

Raw runtime save:

```bash
curl -sS -X POST http://127.0.0.1:8935/api/v1/runtime/config/raw \
  -H "Authorization: Bearer <raw-token>" \
  -H "X-MASC-Agent: <admin-agent>" \
  -H "Content-Type: application/json" \
  -d @payload.json
```

`payload.json`:

```json
{
  "source_text": "[runtime]\ndefault = \"provider.model\"\n"
}
```

If the request is authenticated as `agent-code` or `agent-code-mcp-client` with `role=worker`,
this route should fail with a `CanAdmin` error by design.

Boot:

```bash
curl -sS -X POST http://127.0.0.1:8935/api/v1/keepers/<keeper>/boot \
  -H "Authorization: Bearer <raw-token>" \
  -H "X-MASC-Agent: agent-code-tool-matrix"
```

Shutdown:

```bash
curl -sS -X POST http://127.0.0.1:8935/api/v1/keepers/<keeper>/shutdown \
  -H "Authorization: Bearer <raw-token>" \
  -H "X-MASC-Agent: agent-code-tool-matrix"
```

Then inspect the execution snapshot:

```bash
curl -sS http://127.0.0.1:8935/api/v1/dashboard/execution \
  -H "Authorization: Bearer <raw-token>" \
  -H "X-MASC-Agent: agent-code-tool-matrix" \
  | jq '.keepers[] | select(.name=="<keeper>") | {name,status,paused,trace_id,active_model}'
```

## 10. Rollback

If you need to go back to anonymous loopback behavior:

1. restore the config backup
2. remove the seeded credential file
3. restart the server

Example:

```bash
BASE_PATH="${MASC_BASE_PATH:-/path/to/base}"
mv "$BASE_PATH/.masc/auth/config.json.bak" "$BASE_PATH/.masc/auth/config.json"
rm -f "$BASE_PATH/.masc/auth/agents/agent-code-tool-matrix.json"
```

If you used only `dashboard-dev` dev-token bootstrap, there may be no auth files to roll back.

## 10. Known Failure Modes

- `effective_base_path` points somewhere else:
  you edited the wrong `.masc/auth` tree
- `require_token=false`:
  dashboard keeper boot/config/shutdown remains blocked even with auth enabled
- `effective_role=worker`:
  your bearer is valid but not admin
- `agent-code cannot CanAdmin` or `agent-code-mcp-client is role=worker`:
  the request is authenticated with a worker bearer; rerun login JSON and switch to an admin bearer
- `{"error":"not found"}` on keeper boot/shutdown:
  you may still be running an older server build without the fixed route classifier
