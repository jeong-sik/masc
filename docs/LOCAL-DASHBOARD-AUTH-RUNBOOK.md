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

## 3. Mint an Admin Dashboard Bearer

The Dashboard lifecycle routes in this runbook need an admin bearer. Mint one
for a dedicated local operator identity, then open the emitted Dashboard URL:

```bash
BASE_PATH="${MASC_BASE_PATH:-/path/to/base}"
eval "$(MASC_BASE_PATH="$BASE_PATH" ./_build/default/bin/main_eio.exe login \
  --base-path "$BASE_PATH" \
  --agent local-dashboard-admin \
  --role admin \
  --client-env MASC_ADMIN_TOKEN \
  --no-expiry \
  --shell)"
open "$MASC_DASHBOARD_URL"
```

Use `xdg-open` instead of `open` on Linux. The URL contains the bearer, so do
not paste it into logs, chat, or issue trackers.

To inspect the machine-readable login result without inventing diagnostic
fields, run the same mint with `--json`:

```bash
MASC_BASE_PATH="$BASE_PATH" ./_build/default/bin/main_eio.exe login \
  --base-path "$BASE_PATH" \
  --agent local-dashboard-admin \
  --role admin \
  --client-env MASC_ADMIN_TOKEN \
  --no-expiry \
  --json \
  | jq '{status,auth_change,agent_name,role,raw_token_file,dashboard_url,mcp_url,mcp_client}'
```

Expected invariants are `status == "ok"`, `role == "admin"`, and
`mcp_client.token_env_var == "MASC_ADMIN_TOKEN"`. `auth_change` reports whether
login found bearer auth already required or enabled it during this mint.

## 4. Agent-Code MCP Bearer or OAuth Login

MASC supports two MCP authentication modes on the same loopback server:

- static bearer remains the default and uses `bearer_token_env_var`;
- OAuth 2.1 authorization code + PKCE is opt-in with
  `MASC_OAUTH_ENABLED=1`.

OAuth discovery, dynamic client registration, browser authorization, and token
refresh are exposed only when OAuth is enabled and the admitted request
authority is loopback. The browser approval form asks for an existing MASC
bearer once to bind the OAuth grant to that bearer’s agent identity. The
bootstrap bearer is not stored in OAuth state.

For the Agent-Code MCP server, the local startup path maintains a private
non-expiring worker bearer at
`$BASE_PATH/.masc/auth/agent-code-mcp-client.token`. Manual `login` is still useful
when bootstrapping or rotating the bearer; export the printed value as
`MASC_TOKEN` in the shell that starts Agent-Code:

```bash
BASE_PATH="${MASC_BASE_PATH:-/path/to/base}"
eval "$(./_build/default/bin/main_eio.exe login \
  --base-path "$BASE_PATH" \
  --agent agent-code-mcp-client \
  --role worker \
  --client-env MASC_TOKEN \
  --no-expiry \
  --shell)"
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

If Agent-Code still reports that `masc` is not logged in while using static
bearer mode, compare its registration above with the login contract:

```bash
MASC_BASE_PATH="$BASE_PATH" ./_build/default/bin/main_eio.exe login \
  --base-path "$BASE_PATH" \
  --agent agent-code-mcp-client \
  --role worker \
  --client-env MASC_TOKEN \
  --no-expiry \
  --json \
  | jq '{mcp_url,mcp_client}'
```

The URLs must match, and `mcp_client.token_env_var` must be the same env var
named by Agent-Code. `login --json` does not inspect Agent-Code's config.

### OAuth mode

Start MASC with an exact public MCP resource identity:

```bash
export MASC_OAUTH_ENABLED=1
export MASC_HTTP_BASE_URL=http://127.0.0.1:8935
export MASC_URL=http://127.0.0.1:8935/mcp
./_build/default/bin/main_eio.exe start --host 127.0.0.1 --port 8935 \
  --base-path "$BASE_PATH"
```

The Agent-Code server entry needs only the URL when OAuth is the selected
client mode:

```toml
[mcp_servers.masc]
url = "http://127.0.0.1:8935/mcp"
```

Then log in and request the least-privileged scope:

```bash
codex mcp login masc --scopes mcp:tools
```

Use `mcp:admin` only with an admin bootstrap bearer. A worker bootstrap cannot
be elevated by requesting the admin scope.

If `bearer_token_env_var` is also configured and resolves to a value,
Codex uses that static bearer for MCP calls. Remove that client-side field
when OAuth should be the active mode. MASC itself continues accepting both
credential kinds concurrently.

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

The config is written by whatever external generator the operator uses; MASC
neither ships one nor repairs `~/.agent-code/config.toml` on startup.

## 5. Agent-LLM-A / Provider-F MCP Bearers

> **MASC is MCP-client-agnostic.** The server holds no list of "known" clients
> and does not derive env-var names from `--agent`. The operator names the env
> var with `--client-env <VAR>` and chooses the lifetime with `--no-expiry`.
> The conventions below are recommendations for the local wrapper script
> (`~/me/scripts/mcp-sync.sh`), not server policy.

Each local MCP client must mint its own worker identity so its bearer is
distinct from the Agent-Code bearer. Pick a per-client env var name (e.g.
`MASC_AGENT_LLM_A_MCP_TOKEN`, `MASC_PROVIDER_F_MCP_TOKEN`) and pass it in via
`--client-env`. Long-running local MCP daemons typically want `--no-expiry` so
their bearer survives across daemon restarts.

```bash
BASE_PATH="${MASC_BASE_PATH:-/path/to/base}"

eval "$(./_build/default/bin/main_eio.exe login \
  --base-path "$BASE_PATH" \
  --agent agent-llm-a \
  --role worker \
  --client-env MASC_AGENT_LLM_A_MCP_TOKEN \
  --no-expiry \
  --shell)"

eval "$(./_build/default/bin/main_eio.exe login \
  --base-path "$BASE_PATH" \
  --agent provider-f \
  --role worker \
  --client-env MASC_PROVIDER_F_MCP_TOKEN \
  --no-expiry \
  --shell)"

```

Manual `login` is for first-time setup or explicit rotation; after that,
the client launcher can read the private token files under
`$BASE_PATH/.masc/auth/` into the matching environment variables.

**Provider-F and Agent-LLM-A configs should use `bearer_token_env_var` (not a
hardcoded `Authorization` header).** Export
`MASC_AGENT_LLM_A_MCP_TOKEN` and `MASC_PROVIDER_F_MCP_TOKEN` from the respective
private token files rather than embedding literal tokens in the config.

Recommended local convention (enforced by the operator's wrapper, not the
server): `agent-llm-a` should use `MASC_AGENT_LLM_A_MCP_TOKEN` /
`X-MASC-Agent: agent-llm-a`, and `provider-f` should use
`MASC_PROVIDER_F_MCP_TOKEN` / `X-MASC-Agent: provider-f`.

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
eval "$(./_build/default/bin/main_eio.exe login \
  --base-path "$BASE_PATH" \
  --agent agent-code-local-admin \
  --role admin \
  --client-env MASC_ADMIN_TOKEN \
  --no-expiry \
  --shell)"
```

The command prints the raw bearer once, writes the matching private raw-token
file under the live auth root, and includes a dashboard URL.

If login JSON says `dashboard_dev_token: available=yes`, the browser dashboard
automatically bootstraps a `dashboard` Worker credential from:

```bash
TOKEN="$(curl -sS http://127.0.0.1:8935/api/v1/dashboard/dev-token | jq -r '.token')"
printf 'token=%s\n' "$TOKEN"
```

This endpoint is loopback-only and disabled when HTTP strict auth is enabled.
It is suitable for dashboard reads and Worker-authorized operations, not the
admin-only keeper lifecycle actions covered by this runbook.

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

Pass the token once via query string. The dashboard moves it into `sessionStorage` and removes it from the URL.

```text
http://127.0.0.1:8935/dashboard?agent=agent-code-tool-matrix&token=<raw-token>
```

Do not paste the dev-token into this admin URL. The loopback dashboard obtains
its Worker credential directly and binds it to the exact `dashboard` actor.

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

The automatic dev-token is a persistent `dashboard` Worker credential and is
independent of the explicit admin credential created by this runbook.

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
