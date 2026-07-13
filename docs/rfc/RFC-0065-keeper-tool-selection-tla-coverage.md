---
title: Withdraw policy-bearing tool-selection model
rfc: 0065
status: Withdrawn
created: 2026-05-11
updated: 2026-07-13
implementation_prs: []
---

# RFC-0065 — Withdraw policy-bearing tool-selection model

The former model encoded admission, filtered tool surfaces, blocker classes,
rollover gates, and terminal post-turn policy. Registered descriptors are now
model-visible, while actual effects are judged at their handlers by the generic
Gate. The old formalization is retired.
