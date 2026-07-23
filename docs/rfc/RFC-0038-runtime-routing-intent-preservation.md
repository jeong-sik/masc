---
rfc: "0038"
title: "Withdraw MASC capability-routing plan"
status: Withdrawn
updated: 2026-07-13
---

# RFC-0038: Withdrawn MASC capability-routing plan

| | |
|---|---|
| Status | Withdrawn |
| Withdrawn | 2026-07-13 |
| Reason | MASC-side provider/model capability classification and implicit routing gates duplicated OAS runtime truth. |

## Historical disposition

This draft proposed model-id probes, pattern tables, provider capability
classes, and MASC-side pre-dispatch routing decisions. That direction is
retired. OAS reports the actual result and capabilities of a configured
provider/model call; MASC neither predicts them from names nor turns them into
Keeper authorization.

Configured runtime and fallback order remain explicit configuration. A failed
or unsupported attempt is recorded explicitly, and another configured runtime
may be attempted without pausing the Keeper. External-effect authorization is
owned by the generic Keeper Gate, independently of provider or model identity.

This file is historical only and defines no compatibility surface.
