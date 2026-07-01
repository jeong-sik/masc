# Auth bootstrap-grace requires proof of token possession

- Status: Implemented
- Author: Claude (Sonnet 5), on behalf of jeong-sik (vincent)
- Date: 2026-07-01
- Related: RFC-0292 (Complete lib/auth de-duplication — out of scope: auth behavior; this RFC is exactly that behavior)
- Tracking: masc-oas keeper-fleet audit 2026-07-01, item 12 (auth/dashboard token)

## 1. Problem

`Auth.check_permission` and `Auth.resolve_role_with_auth_config`
(`lib/auth/auth.ml`) both had a "bootstrap grace" branch intended to let the
agent who ran `enable_auth` always regain access (comment: "the agent who
enabled auth always has full access", added to prevent BUG-025's circular
permission deadlock — an admin who can't produce a valid token could
otherwise never mint themselves a new one).

The branch matched only on `agent_name`:

```ocaml
else if
  match read_initial_admin config with
  | Some admin -> String.equal agent_name admin
  | None -> false
then (ignore permission; Ok ())   (* no token check at all *)
```

`agent_name` reaching this function is not authenticated. On the HTTP path
(`lib/server/server_auth.ml`, `authorize_permission_request` /
`authorize_tool_request`), it comes from `agent_from_request`, which reads
the client-controlled `x-gate-agent` / `x-masc-agent` / `x-masc-agent-name`
headers or `agent`/`agent_name` query params verbatim, with no signature or
token binding. When no such header is present at all, those call sites
additionally default the unresolved identity to the literal string
`"dashboard"`.

Net effect: any HTTP request that sets `X-MASC-Agent: <initial_admin value>`
(or, on instances where the unauthenticated default `"dashboard"` happens to
equal the `initial_admin` file's contents, any request with **no**
identifying header at all) was granted Admin — including on
`/api/v1/operator/action`, which can boot/recover keepers — with **zero**
token, credential, or secret presented. Confirmed live on this machine's
running instance (`~/.masc/auth/initial_admin` = `"dashboard"`, matching the
unauthenticated-request default in `server_auth.ml`).

`enable_auth` already mints a real, verifiable Admin credential for that
agent via `create_token` at the moment auth is enabled, so the bare
string-match branch was also redundant with the normal, token-verified
path in the common case — it only mattered once that credential's token
expired or was lost, i.e. exactly the BUG-025 recovery scenario it was
built for.

## 2. Fix

Require proof of possession instead of a self-declared name. `enable_auth`
already mints a **workspace secret** (`init_workspace_secret`) at the same
time as the bootstrap admin token, hashes and persists it
(`workspace_secret_hash`), and returns the raw value once for the operator
to keep. `verify_workspace_secret` (defined, but with zero callers before
this change — a second, independent audit finding) already implements
constant-effort hash comparison against that stored value.

The bootstrap/recovery grace branch in both `check_permission` and
`resolve_role_with_auth_config` now requires the caller's `token` to verify
against the workspace secret, not `agent_name` to string-match
`read_initial_admin`:

```ocaml
else if
  match token with
  | Some raw -> verify_workspace_secret config raw
  | None -> false
then (ignore permission; Ok ())
```

This preserves the original recovery property (whoever holds the workspace
secret — shown once, out of band, to the operator at `enable_auth` time —
can always regain Admin, so BUG-025's deadlock is still prevented) while
closing the self-assertion hole: an attacker who does not know the secret
gets `Unauthorized`/`InvalidToken`, not `Ok ()`.

`read_initial_admin` itself is untouched and keeps its other, legitimate
consumers (`lib/workspace_goals.ml`, `lib/tool_workspace.ml`,
`lib/workspace_metric_hooks.ml`, `lib/server/server_runtime_startup_credentials.ml`)
that use it purely to look up "who is the recorded admin name" for
domain logic, not to authorize a request.

## 3. Non-goals

- `server_auth.ml`'s `Option.value ~default:"dashboard"` fallback for an
  unresolved agent name is unchanged. With this fix it is no longer a
  privilege-escalation vector (the defaulted identity can no longer reach
  Admin without the workspace secret), but the fallback itself is still a
  hardcoded literal worth revisiting separately — out of scope here to keep
  this change to the actual vulnerability.
- The `lib/` vs `lib/auth/` module de-duplication (RFC-0292) is unrelated:
  `lib/auth.ml` is already a thin `include Auth_leaf` facade over the single
  real implementation in `lib/auth/auth.ml` that this RFC changes, so there
  is only one copy of `check_permission`/`resolve_role_with_auth_config` to
  fix.
- Per-tool permission granularity (`tool_catalog` `requiredPermission` not
  being consulted by `authorize_tool_for_role`) and `Auth_strict_mode`'s
  Phase B (reject, not just count) are real, separately-scoped gaps found in
  the same audit — not addressed by this RFC.

## 4. Verification

- `test/test_auth.ml`: 5 new regression cases — impersonation via bare
  `agent_name` with no token is rejected (`Unauthorized`), impersonation
  with a wrong/guessed token is rejected (`InvalidToken`), and presenting
  the actual workspace secret grants Admin via both `check_permission` and
  `resolve_role`/`resolve_role_with_auth_config`. All 51 `test_auth.ml`
  cases pass (46 pre-existing + 5 new).
- `dune build` (full project) and `test_server_auth_warn_log_bound.exe`,
  `test_masc_error_dashboard_auth_code.exe` pass unchanged.
