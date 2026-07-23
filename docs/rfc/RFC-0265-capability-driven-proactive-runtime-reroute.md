---
rfc: "0265"
title: "Withdraw MASC modality capability rerouting"
status: Withdrawn
created: 2026-06-19
updated: 2026-07-13
---

# RFC-0265 — Withdraw MASC modality capability rerouting

MASC does not predict modality support from a provider/model catalog and does
not drop a turn at a pre-dispatch capability gate. Multimodal input is passed
to OAS; actual unsupported results are explicit and configured fallback may
continue without pausing the Keeper.
