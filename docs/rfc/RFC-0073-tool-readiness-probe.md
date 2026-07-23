---
rfc: "0073"
title: "Withdraw pre-turn tool readiness filtering"
status: Withdrawn
created: 2026-05-14
updated: 2026-07-13
author: vincent
implementation_prs: [15064]
---

# RFC-0073 — Withdraw pre-turn tool readiness filtering

Every registered descriptor remains model-visible. Missing input, path-jail
failure, or unavailable sandbox/network state is reported explicitly by the
real handler. MASC does not build a product/tool-name readiness registry or
hide a tool before execution.
