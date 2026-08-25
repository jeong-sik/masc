---
rfc: "dashboard-dev-token-configured-role"
status: Draft
---

# RFC: Loopback dashboard dev-token issues Admin

Status: Draft

## Problem

The loopback dashboard bootstraps its bearer via
`GET /api/v1/dashboard/dev-token`, which issued the `dashboard` credential
as `Worker`. Admin-gated dashboard surfaces (Keeper GitHub CLI identity,
operator controls behind `CanAdmin`) therefore refused the bootstrapped
session, and the only admin path was pasting a long-lived bearer from
`.masc/auth/` by hand — which the route's role-aware rotation then revoked
on the next bootstrap cycle because its role differed from the Worker
target. The local operator experienced this as recurring, silent
de-authorization.

The Worker ceiling defended nothing: the endpoint answers exact loopback
Hosts only and is absent under strict-auth, and any process on the machine
can already read `.masc/auth/*.token`. On this surface the restriction was
friction, not a boundary.

## Decision

The loopback dev-token issues the `dashboard` credential as `Admin`. No
configuration is added; the role is a compile-time constant, and the
role-aware rotation that previously enforced Worker now converges stored
Worker tokens to Admin on their first bootstrap after upgrade. The
dashboard client's identity contract (`actor === 'dashboard'`,
`role === 'admin'`) rejects a stale Worker response the same way it
previously rejected a non-Worker one, and an older stored `worker` dev
meta parses as null, which triggers one silent re-bootstrap.

## Explicit non-goals

- No env knob, endpoint, header, or query parameter; the role is not
  selectable anywhere.
- No change to remote or OAuth dashboard authentication, keeper/agent
  credentials, or strict-auth behavior.
- No TTL semantics change; file-token credentials remain non-expiring.

## Failure behavior

Unchanged from the existing rotation transaction: a failure after the
pending-journal write leaves the exact raw token available for an
idempotent retry, and non-loopback Hosts are refused before any token or
credential I/O.
