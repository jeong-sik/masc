---
rfc: "0340"
title: "Loopback dashboard Worker credential"
status: Active
updated: 2026-08-03
---

# RFC-0340: Loopback dashboard Worker credential

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

The credential grants `Worker` permissions. It cannot satisfy `CanAdmin`,
`CanInit`, or `CanReset`. Dashboard operations that require those permissions
need an explicit operator credential. Known MCP tools continue to use their
typed tool permission; the dev-token does not create a path-based exception.

## Durable rotation

Only a valid credential whose actor is exactly `dashboard` and whose role is
exactly `Worker` is reusable. Every other stored candidate enters one serialized
rotation:

1. Persist the new raw token at `.masc/auth/dashboard.token.pending`.
2. Revoke the current `dashboard` credential.
3. Persist the new `Worker` credential for the journalled raw token.
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
- An existing `Admin` dashboard credential is revoked; its bearer becomes
  invalid and the replacement bearer resolves to `Worker`.
- Corrupt journals and injected read/write failures fail closed with stable
  error codes.
- The Worker bearer receives `403` from
  `POST /api/v1/dashboard/gate/mode` (`CanAdmin`) and can use an allowed
  `CanVote` route.
- Typed REST and MCP auth failures retry once; prose-only failures do not retry.
- `rg "~role:Masc_domain.Admin" lib/server/server_routes_http_dashboard_dev_token.ml`
  returns no matches.
