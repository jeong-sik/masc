---
rfc: "mcp-dual-bearer-oauth"
title: "MCP dual authentication: static bearer and local OAuth 2.1"
status: Draft
created: 2026-08-01
updated: 2026-08-01
author: codex
supersedes: []
superseded_by: null
related: ["0292"]
---

# RFC — MCP dual authentication: static bearer and local OAuth 2.1

Status: Draft
Date: 2026-08-01
Scope: MASC's Streamable HTTP MCP endpoint and the authentication boundary that
protects it.

## 1. Problem

MASC currently accepts a static bearer from `bearer_token_env_var`. This is the
right credential for keepers, scripts, and unattended local workers, but it does
not support an interactive MCP client's OAuth login flow. In particular,
`codex mcp login masc` cannot discover an authorization server and exits with
`No authorization support detected`.

Replacing static bearer authentication would break the non-interactive clients
for which it is the correct mechanism. Adding an OAuth-only check beside the
existing check would be worse: two independent authorization implementations
would inevitably disagree about agent identity and role.

## 2. Decision

MASC supports both credential acquisition modes:

1. **Static bearer** remains unchanged. Existing agent credential files and
   `bearer_token_env_var` clients continue to work.
2. **OAuth 2.1 authorization code with PKCE** is opt-in through
   `MASC_OAUTH_ENABLED=1`. The local MASC server acts as both authorization
   server and protected resource server.
3. Both tokens resolve through one typed `agent_credential` projection before
   existing permission and tool gates run. OAuth must not introduce a second
   RBAC matrix.

The built-in authorization server is deliberately loopback-only. A public MASC
deployment must use a separately reviewed HTTPS authorization server adapter;
the local bootstrap form must never be exposed on a non-loopback authority.

## 3. User-visible flow

```text
Codex                    Browser                    MASC
  | GET /mcp (no token)     |                        |
  |<-- 401 + resource_metadata ---------------------|
  | GET protected-resource metadata -------------->|
  | GET authorization-server metadata ------------>|
  | POST /oauth/register -------------------------->|
  | GET /oauth/authorize + PKCE ------------------->|
  |---------------- opens URL ---->|                |
  |                                | paste existing |
  |                                | MASC bearer -->|
  |                                |<-- redirect code
  |<--------------- loopback callback--------------|
  | POST /oauth/token + verifier ----------------->|
  |<-- access token + rotating refresh token -------|
  | POST /mcp Authorization: Bearer oauth-token --->|
```

The existing bearer is used once as the user's proof of an already provisioned
MASC identity. OAuth does not invent a parallel username/password database. The
bootstrap bearer is submitted only to the loopback authorization endpoint and
is never written into OAuth state.

## 4. Protocol surface

When enabled, MASC exposes:

| Method | Path | Contract |
|---|---|---|
| GET | `/.well-known/oauth-protected-resource` | RFC 9728 protected resource metadata |
| GET | `/.well-known/oauth-protected-resource/mcp` | resource-specific RFC 9728 alias |
| GET | `/.well-known/oauth-authorization-server` | RFC 8414 authorization server metadata |
| POST | `/oauth/register` | RFC 7591 public-client dynamic registration |
| GET | `/oauth/authorize` | authorization request validation and local approval form |
| POST | `/oauth/authorize` | bearer bootstrap and one-time code issuance |
| POST | `/oauth/token` | authorization-code exchange and refresh-token rotation |

An unauthenticated `/mcp` response includes:

```http
WWW-Authenticate: Bearer resource_metadata="http://127.0.0.1:8935/.well-known/oauth-protected-resource", scope="mcp:tools"
```

OAuth-disabled servers keep the existing bare `WWW-Authenticate: Bearer`
challenge and do not expose the OAuth routes.

### 4.1 Client registration

Dynamic registration accepts public clients only:

- `token_endpoint_auth_method` is `none`.
- every redirect URI must be an absolute loopback HTTP URI;
- fragments and userinfo are rejected;
- the exact redirect URI set is persisted with the generated client ID;
- later authorization requests require an exact registered URI match.

Client metadata is stored below `.masc/auth/oauth/clients/`. No client secret is
created because a secret embedded in a CLI client would not be confidential.

### 4.2 Authorization request

Only these values are accepted:

- `response_type=code`;
- `code_challenge_method=S256`;
- a 43–128 character RFC 7636 code challenge;
- an exact registered `client_id` and `redirect_uri`;
- `resource` exactly equal to the advertised `/mcp` URL;
- supported scopes only.

Authorization codes are cryptographically random, expire after the configured
code TTL, are bound to client, redirect URI, resource, scopes, agent, role, and
PKCE challenge, and are consumed atomically at most once. Raw codes are never
persisted.

### 4.3 Token request

The authorization-code grant requires the same `client_id`, exact
`redirect_uri`, exact `resource`, and a verifier whose SHA-256 base64url value
equals the stored challenge. A validation failure does not consume a valid code;
a validated exchange attempt consumes it before token minting begins. If the
durable store fails, the client must start a fresh authorization flow; the code
is never restored for retry.

The refresh grant rotates both access and refresh tokens. The refresh token
carries its opaque family ID and random secret. The family record stores only
the hash of the current complete token, so presenting any older token for that
family revokes the current access and refresh tokens and fails with
`invalid_grant` without retaining per-rotation tombstone records.

An access-token record stores its SHA-256 hash, family ID, issue time, and
expiry. The family is the single authority for agent, effective role, resource,
scope set, client ID, live bootstrap-credential hash, and current token hashes.
Access files use the hash as the lookup key, so resource authentication is an
exact O(1) lookup rather than a directory scan.

## 5. Typed authorization convergence

The OAuth store resolves an access token to:

```ocaml
type oauth_principal = {
  agent_name : string;
  role : Masc_domain.agent_role;
  scopes : scope list;
  resource : string;
  client_id : string;
  issued_at : string;
  expires_at : string;
}
```

`Auth.find_credential_by_token` and `Auth.verify_token` form the unified
downstream bearer resolver. They distinguish the existing static credential
index from the OAuth access-token store with typed lookup outcomes. A valid
OAuth principal is projected to the existing immutable `agent_credential`
shape; exact agent-name ownership is rechecked by `verify_token`. Consequently
`resolve_agent_from_token`, `check_permission`, tool authorization, MCP actor
injection, rate limiting, and all existing callers keep one authorization path.

OAuth scopes can only reduce privilege:

- `mcp:tools` projects the authenticated identity to `Worker`;
- `mcp:admin` is issued only when the bootstrap credential is already `Admin`
  and projects to `Admin`;
- omitting `scope` defaults to `mcp:tools` for MCP client interoperability;
- an unsupported or privilege-expanding request is rejected, never repaired.

## 6. State and configuration SSOT

```text
.masc/auth/oauth/
  clients/<sha256(client-id)>.json
  access_tokens/<sha256(raw-access-token)>.json
  families/<sha256(family-id)>.json
  .store.lock
```

Authorization codes and pending browser approvals are process-local bounded
state. A server restart invalidates an in-flight browser flow, which the client
can restart safely. Durable client and token records survive restarts.

Configuration lives in one typed module and is re-read at request boundaries:

| Environment key | Meaning |
|---|---|
| `MASC_OAUTH_ENABLED` | opt-in built-in OAuth server |
| `MASC_OAUTH_CODE_TTL_SEC` | authorization-code lifetime |
| `MASC_OAUTH_ACCESS_TOKEN_TTL_SEC` | access-token lifetime |
| `MASC_OAUTH_REFRESH_TOKEN_TTL_SEC` | refresh-token lifetime |
| `MASC_OAUTH_MAX_PENDING_CODES` | hard bound on process-local grants |
| `MASC_OAUTH_MAX_CLIENTS` | hard bound on durable dynamic clients |

Defaults are named policy values in the typed configuration module, not literals
distributed through handlers or stores. At the dynamic-client bound, the store
rejects a distinct registration without deleting another client's durable
identity. An exact retry still returns its existing registration.

## 7. Threat model and invariants

OAuth implementation files carry `HIGH-RISK-UNREVIEWED` until a human reviewer
has checked the implementation and the marker is removed in a separate reviewed
commit.

| Threat | Required invariant |
|---|---|
| authorization-code interception | S256 PKCE is mandatory; `plain` is rejected |
| redirect theft | redirect URI is exact-match registered and loopback-only |
| code replay | a validated exchange attempt consumes one code before minting; store failure does not restore it |
| refresh replay | replay of a known old refresh token revokes the entire token family atomically |
| bootstrap revocation | deleting, rotating, expiring, or demoting the bound static credential revokes the derived OAuth family |
| token leak at rest | only SHA-256 hashes are persisted; files are mode 0600 |
| cross-resource token use | authorization and token requests bind the exact resource derived from admitted request authority; MCP credential lookup requires that same fiber-local resource context |
| privilege escalation | requested scope intersects downward with bootstrap role; it never upgrades role |
| host-header injection | issuer/resource URLs derive only from admitted `Server_request_authority`; OAuth routes additionally require a loopback `Configured_bind` authority, so an explicit loopback Host cannot expose them on a public listener |
| CSRF/form injection | browser POST requires same-origin checks; every reflected value is HTML escaped |
| malicious DCR | only bounded metadata and exact loopback redirect URIs are accepted; exact retries are idempotent and OAuth is available only on the actual loopback listener |
| state exhaustion | pending grants are bounded; rotation overwrites one family SSOT and removes the superseded access record instead of accumulating generation records |
| concurrent writers | one blocking process mutex and one blocking OS store lock serialize read-modify-publish across processes sharing a base path |
| credential ambiguity | static and OAuth stores use typed lookup outcomes; no error-string fallback |

OAuth endpoints return protocol error codes (`invalid_request`,
`invalid_client`, `invalid_grant`, `invalid_scope`) without exposing stored
credential details. Detailed typed failures may be logged only after secret
redaction.

## 8. Compatibility and blast radius

- Existing static bearer files and their JSON schema are unchanged.
- `bearer_token_env_var` remains supported.
- OAuth is off unless explicitly enabled.
- No agent_core dependency or protocol change is introduced.
- No dashboard session or cookie becomes an ambient OAuth login authority.
- MCP authorization changes only token resolution and the 401 challenge header;
  the existing permission matrix remains authoritative.

## 9. Implementation slices

1. Pure OAuth types, validation, PKCE, bounded grant state, and token store under
   `lib/auth/`.
2. Static/OAuth credential convergence in `Auth.find_credential_by_token`.
3. HTTP discovery, registration, authorization, and token handlers under
   `lib/server/`.
4. MCP 401 challenge metadata and route wiring for HTTP/1.1 and HTTP/2 parity.
5. Codex config projection/runbook updates.

## 10. Verification

Focused tests must prove:

- static bearer authentication is unchanged;
- discovery documents contain the exact admitted authority and MCP resource;
- DCR accepts loopback callbacks and rejects public, relative, userinfo, and
  fragment redirect URIs;
- authorization rejects missing/`plain` PKCE, mismatched resource, client, URI,
  or scopes;
- a valid code exchanges once and replay fails;
- wrong verifier does not mint a token;
- refresh rotates once; replay fails and revokes the current token family;
- registration retries are idempotent and distinct valid clients remain durable;
- repeated refresh rotation retains one family SSOT and one current access record;
- expired/revoked/wrong-resource OAuth access tokens fail closed;
- deletion, rotation, expiry, or role demotion of the bootstrap credential fails closed;
- Worker bootstrap cannot obtain admin scope;
- Admin bootstrap receives admin only when explicitly requested;
- both credential kinds produce the same canonical MCP actor;
- HTTP/1.1 and HTTP/2 challenges advertise equivalent resource metadata.

The live acceptance test is:

```bash
MASC_OAUTH_ENABLED=1 \
MASC_URL=http://127.0.0.1:8935/mcp \
MASC_HTTP_BASE_URL=http://127.0.0.1:8935 \
./_build/default/bin/main_eio.exe start
codex mcp login masc --scopes mcp:tools
codex mcp get masc
```

After login, a real MCP `initialize` and `tools/list` request must succeed with
the OAuth token while a separate static-bearer request succeeds unchanged.

## 11. Non-goals

- Federated OIDC/social login.
- Public-network operation of the built-in authorization server.
- Replacing MASC agent provisioning or RBAC.
- Treating MCP session IDs, browser cookies, or loopback presence as identity.
- Accepting bearer material in URL query parameters for OAuth endpoints.
