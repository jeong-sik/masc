---
rfc: "0058"
title: "Withdraw terminal capability hierarchy"
status: Withdrawn
updated: 2026-07-13
---

# RFC-0058: Withdrawn terminal capability hierarchy

| | |
|---|---|
| Status | Withdrawn |
| Withdrawn | 2026-07-13 |
| Reason | Static capability tiers and terminal exemptions duplicated OAS runtime truth and denied usable fallback calls before execution. |

## Historical disposition

The proposed `Tool_strict`, `Local_inline`, and terminal-exemption hierarchy is
retired. MASC does not rank providers, models, or fallback positions and does
not infer authorization from runtime MCP header support.

OAS owns provider/model capability discovery and returns an explicit result
for the actual call. MASC may select another configured runtime after an
explicit unsupported or unavailable result, but it does not apply a static
capability floor first. Keeper identity is the exact authenticated token owner;
headers and model/provider labels are observational metadata only.

This document is historical only. It defines no active runtime behavior and no
compatibility surface.
