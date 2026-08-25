---
rfc: "0340"
title: "Loopback dashboard token-only auth"
status: Active
updated: 2026-08-03
---

# RFC-0340: Loopback dashboard token-only auth

- Status: Active
- Date: 2026-07-10
- Related: issue #24031
- Subsystem: credential / identity / auth

## Contract

`GET /api/v1/dashboard/dev-token` is a loopback bootstrap boundary for the
browser dashboard. It returns exactly:

```json
{
  "token": "<64 lowercase hex characters>",
  "actor": "dashboard",
  "role": "worker"
}
```

The endpoint is unavailable on a non-loopback bind or with strict HTTP auth.
The admitted request authority must also be an exact loopback host before any
token or credential I/O occurs. Host suffix and substring matching are not
part of the contract.

The credential's role is `RFC-dashboard-dev-token-configured-role`'s decision,
not this RFC's; that RFC issues it as `Admin`. Known MCP tools continue to use
their typed tool permission, and the dev-token does not create a path-based
exception — the endpoint's own gate is the exact loopback `Host`, which this
RFC specifies above.

## Durable rotation

Only a valid credential whose actor is exactly `dashboard` and whose role is
exactly the configured issuance role is reusable. Every other stored candidate enters one serialized
rotation:

1. Persist the new raw token at `.masc/auth/dashboard.token.pending`.
2. Revoke the current `dashboard` credential.
3. Persist the new credential for the journalled raw token.
4. Atomically publish the raw token at `.masc/auth/dashboard.token` with private
   file permissions.
5. Remove the pending journal.

If the process or request is interrupted after step 1, the next call resumes
with the same raw token. A missing, unreadable, or malformed journal is a typed
failure; it is never interpreted as permission to mint repeatedly. The rotation
is protected by one cross-context durable lock.

## Request identity

A bearer-bound request must resolve to a credential identity. A present token
with no resolved actor is rejected as `invalid_token`; it is never assigned the
string actor `dashboard`. An unauthenticated public-read request remains a
separate typed case.

The dashboard stores token provenance as one of:

- `{source: "dev", actor: "dashboard", role: "worker"}`
- `{source: "manual"}`
- `{source: "url"}`

Manual and URL tokens cannot assert an actor or role in browser storage. Until
the server returns the credential's canonical actor, those requests omit the
implicit actor header.

## Typed self-healing

Loopback sessions may replace a managed dev-token and retry once only when the
server returns `auth_error_code` equal to `invalid_token`, `token_expired`, or
`actor_mismatch`. REST, Keeper streaming, MCP initialization, and MCP tool
results use that same typed set.

Human-readable `error`, `message`, content text, HTTP status alone, and string
fragments never authorize token replacement. A manual token is never replaced.
MCP calls carrying an explicit actor are never replayed by this recovery path.

## Verification

- Invalid request authority performs zero dev-token file I/O.
- The response has the exact actor and role contract.
- A dashboard credential whose role differs from the configured issuance role
  is revoked, and its bearer becomes invalid.
- Corrupt journals and injected read/write failures fail closed with stable
  error codes.
- `POST /api/v1/dashboard/gate/mode` (`CanAdmin`) answers `403` to a bearer
  below that permission. `test_sse_storm_e2e` pins this with a minted `Worker`,
  not with the dashboard bearer, whose role this RFC does not decide.
- Typed REST and MCP auth failures retry once; prose-only failures do not retry.
- The issuance role is read from one constant
  (`Server_routes_http_dashboard_dev_token.dashboard_dev_role`), never inlined
  per call site.
