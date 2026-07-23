# RFC-0260 — Withdraw MASC provider-health gate

- Status: Withdrawn
- Withdrawn: 2026-07-13
- Reason: MASC-side health classes and automatic reassignment duplicated OAS
  provider/model call truth.

Provider latency, HTTP status, and availability remain observable. OAS returns
the actual typed outcome of the selected provider/model call and applies the
configured fallback behavior. MASC does not assign `Healthy`, `Degraded`, or
`Down` authority and does not use those labels to deny a Keeper turn.

Configuration changes still require explicit provenance and audit records.
That observation contract does not create a provider-selection governance
layer. This document is historical only.
