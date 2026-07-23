---
rfc: "0331"
title: "Withdraw authorization by tool effect class"
status: Withdrawn
created: 2026-07-08
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: null
related: ["0190", "0191", "0318", "0319"]
implementation_prs: []
---

# RFC-0331: Withdraw authorization by tool effect class

## Decision

This RFC is withdrawn. Replacing free-text matching with a required
`Read_only | Mutating` label removes one string classifier but preserves a
subjective two-level policy. Tool authors cannot truthfully summarize every
invocation's effect in one registration flag, and undeclared or composite
behavior would still be judged by a local default.

Descriptors describe schemas and dispatch metadata, not authorization rank.
Every actual external effect reaches the same Keeper Gate with its normalized
input. The Gate knows no tool-name taxonomy and settles the concrete request by
exact Always Allowed, configured LLM Auto Judge, or non-blocking HITL.
