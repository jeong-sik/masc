# RFC-0167: Withdrawn product-specific runtime authorization cleanup

| | |
|---|---|
| Status | Withdrawn |
| Withdrawn | 2026-07-13 |
| Reason | Renaming product-specific bound-actor checks preserved the wrong authorization boundary. |

## Historical disposition

This draft removed some product labels but retained a central decision that
could omit tools based on provider identity and Keeper-bound MCP behavior. The
rename did not fix the coupling, so the proposal is withdrawn.

The current boundary is provider-agnostic: OAS receives the requested schemas
and reports actual call support, while MASC authenticates inbound requests by
the exact token owner. Product names, headers, and provider capability records
do not grant or remove Keeper authority.

This document is historical only and defines no active behavior.
