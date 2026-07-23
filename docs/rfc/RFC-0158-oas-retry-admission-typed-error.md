---
rfc: "0158"
title: "Withdraw MASC retry-admission denial"
status: Withdrawn
created: 2026-05-21
updated: 2026-07-13
author: agent-llm-a-opus
implementation_prs: []
---

# RFC-0158 — Withdraw MASC retry-admission denial

MASC does not estimate input tokens, remaining time, or a minimum attempt
budget to refuse an OAS call. OAS call errors remain typed and explicit; they
do not feed rotation suppression or Keeper pause policy.
