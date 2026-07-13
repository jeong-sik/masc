---
rfc: "0318"
title: "Replace risk-tier auto approval with request-local Auto Judge"
status: Withdrawn
created: 2026-07-08
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: null
related: ["0305", "0319"]
implementation_prs: []
---

# RFC-0318: Replace risk-tier auto approval with request-local Auto Judge

## Decision

The original overlay resolver is withdrawn. It placed an LLM decision below a
static risk hierarchy and preserved terminal floors above it. That structure
kept the heuristic classifier as the real authority and used the model only
after MASC had already decided which requests were eligible.

The non-hierarchical Keeper Gate replaces it:

- **Auto Judge** evaluates the concrete request, context, target, and expected
  effect with the configured model.
- **Always allowed** is explicit operator intent recorded as a Gate rule. It is
  not inferred from a tool name or a risk score.
- **Manual HITL** remains available for requests the operator wants to decide.
- Gate work is asynchronous and request-local; a waiting decision does not
  pause the Keeper's other activity or any other Keeper lane.
- Judge failure is surfaced explicitly. It does not silently approve, reject,
  or create a global stop.

## Boundary

MASC owns Keeper Gate orchestration. OAS exposes general model, tool, and agent
lifecycle primitives and does not learn MASC approval modes, product names, or
repository-hosting semantics.

## Historical rationale

The original RFC identified a real problem: approval queues stalled autonomous
work even though a model summary already existed. The retained solution is to
make model judgment operative and non-blocking. The retired part is the fixed
risk ladder that constrained when the model was allowed to judge.
