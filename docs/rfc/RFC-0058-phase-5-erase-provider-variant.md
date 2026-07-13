---
rfc: "0058-phase-5"
title: "Withdraw provider-variant migration plan"
status: Withdrawn
updated: 2026-07-13
---

# RFC-0058 Phase 5: Withdrawn provider-variant migration plan

| | |
|---|---|
| Status | Withdrawn |
| Withdrawn | 2026-07-13 |
| Reason | Runtime capability truth belongs to OAS; MASC does not infer Keeper authorization from provider identity, model identity, or MCP header support. |

## Historical disposition

This proposal coupled MASC authorization to provider-specific capability
records and identity-bearing runtime MCP headers. That boundary is retired.

The current contract is:

- OAS reports the actual capabilities of the selected provider/model call.
- MASC supplies the tool schemas requested for that call without reclassifying
  them by provider, model, command, or product name.
- An inbound Keeper request is authenticated by its exact token owner. A
  caller-supplied Keeper name or provider capability does not grant authority.
- External effects converge on the generic Keeper Gate: exact Always Allowed,
  LLM Auto Judge, then non-blocking HITL. Objective path and sandbox
  invariants remain at their execution boundaries.

This document is retained only as a record of the rejected migration. It is
not an implementation plan and provides no compatibility contract.
