---
rfc: "0038-phase-2"
title: "Withdraw identity-alias migration"
status: Withdrawn
updated: 2026-07-13
---

# RFC-0038 Phase 2: Withdrawn identity-alias migration

| | |
|---|---|
| Status | Withdrawn |
| Withdrawn | 2026-07-13 |
| Reason | Heuristic alias canonicalization and compatibility mappings are not an authentication boundary. |

## Historical disposition

Inbound authority is the exact owner of the authenticated token. A
caller-supplied Keeper name, generated nickname, transport alias, header,
provider, or model cannot replace that identity.

Domain records may still carry a Keeper identifier for Goal, Task, Board, and
lane correlation, but any display alias is metadata and is never consulted to
grant access. This rejected draft is retained only as historical context.
