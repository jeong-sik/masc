---
rfc: "0323"
title: "Withdraw mandatory cross-verifier completion"
status: Withdrawn
created: 2026-07-08
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: null
related: ["0220", "0221", "0308", "0311"]
implementation_prs: []
---

# RFC-0323: Withdraw mandatory cross-verifier completion

## Decision

This RFC is withdrawn. Requiring a second identity, splitting Tasks by a strict
flag, and routing every selected completion through a separate verifier creates
an organizational hierarchy in the runtime. It also lets one missing verifier
stall Task state even though the Keeper should remain productive.

The configured completion LLM is the judgment boundary. Task, Goal, contract,
evidence, prior verdicts, and actor provenance are context for that call rather
than deterministic routing criteria. Re-running completed work may still create
a linked Task, but that data-model choice does not require a second completion
lane or verifier rank.
