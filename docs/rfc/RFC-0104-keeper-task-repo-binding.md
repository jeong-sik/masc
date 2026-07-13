---
rfc: "0104"
title: "Withdraw Task-to-repository authorization"
status: Withdrawn
created: 2026-05-17
updated: 2026-07-13
author: vincent
implementation_prs: []
---

# RFC-0104 — Withdraw Task-to-repository authorization

A Task may carry a path or workspace reference as typed input, but repository
catalog membership is not access authority. Execution resolves against
BasePath and objective path/sandbox containment only. Product-specific git/gh
cwd rules are retired.
