---
rfc: "0262"
title: "Withdraw hierarchical Task-completion authority"
status: Withdrawn
created: 2026-06-19
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: null
related: ["0199", "0220", "0221", "0222"]
implementation_prs: []
---

# RFC-0262: Withdraw hierarchical Task-completion authority

## Decision

This RFC is withdrawn. Replacing a boolean override with a closed hierarchy of
Task authorities improves representation but preserves the wrong question:
which locally ranked actor may bypass completion judgment.

Actor identity, Task ownership, and request provenance remain typed facts and
are always recorded. They do not create an implicit completion bypass. The
configured LLM judges completion from the Task and its evidence. An explicit
operator action is recorded as such, without minting a reusable rank that a
Keeper or generic subsystem can infer.
