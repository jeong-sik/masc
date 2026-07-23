---
rfc: "0194"
title: "Withdraw tool semantics as an authorization SSOT"
status: Withdrawn
created: 2026-05-27
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: null
related: ["0179", "0190", "0191"]
implementation_prs: []
---

# RFC-0194: Withdraw tool semantics as an authorization SSOT

## Decision

This RFC is withdrawn. Moving command/effect classification from substring
patterns into typed tool tables removes a string heuristic but still makes the
descriptor catalog a product-policy hierarchy. Dispatch metadata cannot decide
the meaning of every concrete invocation.

Tool descriptors remain the SSOT for schema, identity, transport aliases,
examples, and dispatch. They do not carry a hidden authorization rank or make
model-visible tools disappear. Every actual external effect reaches the
product-neutral Keeper Gate with normalized input and is settled by exact
Always Allowed, configured LLM Auto Judge, or non-blocking HITL.
