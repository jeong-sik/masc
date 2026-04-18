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

## 0. Copy-Paste Example

Start the server on loopback:

```bash
cd ~/me/workspace/yousleepwhen/masc-mcp
BASE_PATH="${MASC_BASE_PATH:-$HOME}"
MASC_BASE_PATH="$BASE_PATH" \
  dune exec --root . ./bin/main_eio.exe -- \
  --host 127.0.0.1 \
  --port 8935 \
  --base-path "$BASE_PATH"
```

In another shell, do the whole local admin flow in one command:

```bash
~/me/scripts/masc dashboard-admin
```

That command:

- mints or rotates the admin bearer
- prints `token=...` and `export MASC_OPERATOR_TOKEN=...`
- opens the dashboard URL once
- verifies `/api/v1/dashboard/shell`

If you want the raw values without opening a browser:

```bash
~/me/scripts/masc dashboard-admin --no-open
```

If you need raw JSON for scripting:

```bash
LOGIN_JSON="$(~/me/scripts/masc login --json --agent codex-local-admin)"
TOKEN="$(printf '%s\n' "$LOGIN_JSON" | jq -r '.bearer_token')"
URL="$(printf '%s\n' "$LOGIN_JSON" | jq -r '.dashboard_url')"
printf 'token=%s\nurl=%s\n' "$TOKEN" "$URL"
```

Expected quick checks:

- `enabled=true`
- `require_token=true`
- `effective_role="admin"`

Common next actions:

```bash
# boot a keeper
curl -sS -X POST http://127.0.0.1:8935/api/v1/keepers/<keeper>/boot \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-MASC-Agent: codex-local-admin"

# rotate the same admin token
~/me/scripts/masc login --json --agent codex-local-admin

# mint a separate admin identity
~/me/scripts/masc login --json --agent ops-admin
```

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

## 3. Supported Local Start

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

## 4. Fast Path: Mint an Admin Bearer with `login`

If you already have an admin bearer, skip to step 5.

Fastest path if you want the browser + verification too:

```bash
~/me/scripts/masc dashboard-admin
```

JSON path if you are scripting around the token:

```bash
~/me/scripts/masc login --json --agent codex-local-admin
```

If you are inside the repo and do not have the wrapper yet:

```bash
dune exec --root . ./bin/main_eio.exe -- login --json --agent codex-local-admin
```

What this does:

- enables room auth if it is still off
- forces `require_token=true`
- creates or rotates an admin bearer for the requested `agent_name`
- prints a one-shot dashboard URL and the raw bearer token

Typical JSON output:

```json
{
  "base_path": "/Users/you/me",
  "auth_root": "/Users/you/me/.masc/auth",
  "auth_config_path": "/Users/you/me/.masc/auth/config.json",
  "agents_root": "/Users/you/me/.masc/auth/agents",
  "credential_path": "/Users/you/me/.masc/auth/agents/codex-local-admin.json",
  "agent_name": "codex-local-admin",
  "require_token": true,
  "reused_auth": true,
  "room_secret": null,
  "bearer_token": "<raw-token>",
  "dashboard_url": "http://127.0.0.1:8935/dashboard?agent=codex-local-admin&token=<raw-token>"
}
```

Recommended shell flow:

```bash
LOGIN_JSON="$(~/me/scripts/masc login --json --agent codex-local-admin)"
TOKEN="$(printf '%s\n' "$LOGIN_JSON" | jq -r '.bearer_token')"
URL="$(printf '%s\n' "$LOGIN_JSON" | jq -r '.dashboard_url')"
printf 'token=%s\nurl=%s\n' "$TOKEN" "$URL"
```

Field meanings:

- `reused_auth=true`: auth was already enabled; only the admin bearer was minted or rotated
- `reused_auth=false`: auth was just bootstrapped now
- `room_secret!=null`: a brand-new room secret was created during bootstrap
- `room_secret=null`: auth already existed, so the raw room secret cannot be shown again

Notes:

- the server stores only the SHA256 hash, not the raw bearer
- keep the raw bearer outside the repo
- rerunning `login` is the supported local rotation path
- this is for trusted local operator use, not a remote/public bootstrap path

## 5. Open the Dashboard as Admin

Pass the token once via query string. The dashboard moves it into `sessionStorage` and removes it from the URL.

```text
http://127.0.0.1:8935/dashboard?agent=codex-local-admin&token=<raw-token>
```

You can verify the session with:

```bash
curl -sS http://127.0.0.1:8935/api/v1/dashboard/shell \
  -H "Authorization: Bearer <raw-token>" \
  -H "X-MASC-Agent: codex-local-admin" \
  | jq '.auth'
```

Expected:

- `token_present=true`
- `effective_agent="codex-local-admin"`
- `effective_role="admin"`

## 6. Verify Keeper Lifecycle Routes

Use a low-risk keeper first.

Boot:

```bash
curl -sS -X POST http://127.0.0.1:8935/api/v1/keepers/<keeper>/boot \
  -H "Authorization: Bearer <raw-token>" \
  -H "X-MASC-Agent: codex-local-admin"
```

Shutdown:

```bash
curl -sS -X POST http://127.0.0.1:8935/api/v1/keepers/<keeper>/shutdown \
  -H "Authorization: Bearer <raw-token>" \
  -H "X-MASC-Agent: codex-local-admin"
```

Then inspect the execution snapshot:

```bash
curl -sS http://127.0.0.1:8935/api/v1/dashboard/execution \
  -H "Authorization: Bearer <raw-token>" \
  -H "X-MASC-Agent: codex-local-admin" \
  | jq '.keepers[] | select(.name=="<keeper>") | {name,status,paused,trace_id,active_model}'
```

## 7. Rotate or Mint Another Admin Token

Rotate the same admin identity:

```bash
~/me/scripts/masc login --json --agent codex-local-admin
```

Mint a second admin identity for a different operator:

```bash
~/me/scripts/masc login --json --agent ops-admin
```

Old raw tokens remain unusable once you rotate the same `agent_name`, because the stored hash in `.masc/auth/agents/<agent>.json` is replaced.

## 8. Manual Fallback: Seed the Auth Store Directly

Use this only if the `login` command is unavailable.

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
  "agent_name": "codex-local-admin",
  "token": "<sha256 hash>",
  "role": "admin",
  "created_at": "<created_at>",
  "expires_at": "<expires_at>"
}
```

Path:

```text
<effective_base_path>/.masc/auth/agents/codex-local-admin.json
```

4. Set `require_token=true` in the live auth config:

```json
{
  "enabled": true,
  "require_token": true,
  "default_role": "worker"
}
```

Path:

```text
<effective_base_path>/.masc/auth/config.json
```

## 9. Rollback

If you need to go back to anonymous loopback behavior:

1. restore the config backup
2. remove the seeded credential file
3. restart the server

Example:

```bash
BASE_PATH="${MASC_BASE_PATH:-$HOME}"
mv "$BASE_PATH/.masc/auth/config.json.bak" "$BASE_PATH/.masc/auth/config.json"
rm -f "$BASE_PATH/.masc/auth/agents/codex-local-admin.json"
```

## 10. Known Failure Modes

- `effective_base_path` points somewhere else:
  you edited the wrong `.masc/auth` tree
- `require_token=false`:
  dashboard keeper boot/config/shutdown remains blocked even with auth enabled
- `effective_role=worker`:
  your bearer is valid but not admin
- `{"error":"not found"}` on keeper boot/shutdown:
  you may still be running an older server build without the fixed route classifier
