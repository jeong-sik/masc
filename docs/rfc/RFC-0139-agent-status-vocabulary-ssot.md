---
rfc: "0139"
title: "Withdraw parallel agent and judge status hierarchies"
status: Withdrawn
created: 2026-05-19
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: null
related: ["0135"]
implementation_prs: [16698, 16707, 16708, 16711, 16714, 16755]
---

# RFC-0139: Withdraw parallel agent and judge status hierarchies

## Decision

Withdraw the proposal to maintain overlapping Keeper, agent, and judge status
vocabularies in the dashboard.

The dashboard may project typed source facts, but it must not invent a parallel
runtime hierarchy or infer lifecycle from presentation labels. Keeper identity
and lifecycle come from the Keeper runtime SSOT. Configured LLM judgments and
Gate resolutions are source events, not a second actor lifecycle.

Historical implementation PRs remain available in Git. Their presentation
helpers do not authorize Keeper pause, stop, scheduling, tool access, or Task
and Goal transitions.
