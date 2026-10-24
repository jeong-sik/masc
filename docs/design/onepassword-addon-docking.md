# 1Password Add-on docking

Tracking: [#45736](https://github.com/jeong-sik/masc/issues/45736).

The requested outcome is an installed connector a Keeper can use to sign in
through its existing browser, with user approval in 1Password, then continue its
original task. Passwords and OTPs must never reach model arguments, tool results,
retained observations or logs. A status-only tool does not satisfy that outcome.

## Implemented foundation

- `addons/onepassword/oauth.py`: code + S256 PKCE, backend-only token/key storage,
  configuration identity, connection generation, serialized rotating refresh,
  expiration-aware revoke and explicit uncertain-operation recovery states.
- `addons/onepassword/lane.toml`: normal native MCP package, host-context status
  export, packaged skill and declared connection readings. It does not declare
  another Browser service.
- `onepassword_status`: safe account projection, with
  `browser_login_available = false` while browser docking remains unfinished.
- Private operator connection source: discovered `lane_operator`, admin-only
  host ingress, original-incarnation/connection authority, the generic Dashboard
  connection panel, callback fragment capture and transaction-pinned cancel.
  See [operator control contract](lane-addon-operator-controls.md).
- Focused Python checks: 29 OAuth, 10 operator-boundary and 6 native-style MCP
  subprocess scenarios. Dashboard transport and popup/workspace/credential
  admission have 10 focused checks. These use fabricated credentials and fixtures.

On 2026-10-24, candidate `dc3e8ed35ff065c4cff859a8473531b4561373db`
was copied as an explicit development package and installed through the served
workspace's declaration API. The running MASC binary identified itself as
`8eac5c07c290d134a9ef6acb1e298584bf9a1366`; it was not rebuilt from this stack.
Desired and applied declaration revisions matched, the native worker attached,
and its declared connection row was retained. An external coding agent initialized
an MCP session, discovered `onepassword_status`, then invoked it through the
server's normal exported-tool path. The result was:

```json
{"phase":"not_configured","connected":false,"browser_login_available":false}
```

The running Dashboard displayed the attached development installation. Its
existing bundle/server mismatch banner remained visible; no Dashboard upgrade or
broader runtime-health claim is made. Local receipts and screenshot are under
`reports/onepassword-addon-20261024/` in the development worktree. They are not
published account-authentication evidence.

## Remaining work

1. Install and exercise the implemented private connect/callback/cancel path on
   a host built from this stack. Extend it with approval/disconnect controls and
   explicit remote reconciliation for an interrupted exchange or rotation.
2. Attach the supported extension and connector to the existing owned Chromium
   backend. Use the original Browser owner and its existing page-operation
   serialization. The companion does not acquire an independent browser or a
   separate CDP fill path.
3. Run request/status/fill through a private typed exchange. Pin connector
   connection generation, Browser worker incarnation, original session/tab and
   host principal to each login operation. Never follow a replacement owner.
4. Keep reads/screenshots excluded until the original fill is known settled.
   Cancellation must not merely release the existing semaphore while the
   extension continues. An unknown result fences observation and cannot replay
   fill; safe retirement/reconciliation of the original browser is separate.
5. Export login operations and bind durable results to the original Keeper
   continuation. Generic Lane Ask stores question text and does not itself
   resume a Keeper, so it must not carry an opaque approval link.
6. Verify install, model-visible discovery and actual Keeper invocation, real
   user approval, website-level authenticated readback and resumed task work.
   Exercise denial, stale owner, concurrent observation, cancellation, unknown
   result, multi-page login/OTP and disconnect using the same candidate.

Provider setup requires partner preview access, OAuth client registration and a
production HTTPS callback. The required test account and extension/app build
must be confirmed with 1Password. No personal account is connected by the
development status installation above.

References: [1Password partner guide](https://www.1password.dev/agentic-autofill/partners),
[extension API](https://www.1password.dev/agentic-autofill/partners/extension-api),
[Browserbase implementation](https://docs.browserbase.com/integrations/1password/agentic-autofill).
