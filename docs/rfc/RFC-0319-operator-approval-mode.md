---
rfc: "0319"
title: "Replace hierarchical approval modes with Keeper Gate choices"
status: Withdrawn
created: 2026-07-08
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: null
related: ["0305", "0318"]
implementation_prs: []
---

# RFC-0319: Replace hierarchical approval modes with Keeper Gate choices

## Decision

This RFC is withdrawn. Its manual/automatic mode was coupled to fixed risk
bands, separation floors, and process-wide posture. Those concepts made an
operator convenience setting into a hierarchy that could stop unrelated work.

The replacement surface is a non-hierarchical Keeper Gate with three explicit
ways to settle an individual request:

- **Manual** — an operator decides the request.
- **Auto Judge** — the configured model decides the request from its full
  context.
- **Always allowed** — an operator records an explicit reusable permission
  rule.

These are decision sources, not risk levels. They do not introduce an implicit
fourth source that rejects based on tool names, command strings, provider
brands, repository hosts, or guessed irreversibility.

## Liveness and observability

A pending Gate request is durable and visible, but it does not block the
Keeper lane. The Keeper may continue other work, acknowledge that a response
is deferred, or be awakened when the decision arrives. One Keeper's decision
state never pauses another Keeper.

Every decision records its source, request identity, model/operator identity,
result, and explanation. Failure to invoke Auto Judge is an explicit error and
leaves the request unsettled; it is not converted into a silent decision.

## Boundary

The dashboard may configure and observe these Gate choices. The execution
substrate and OAS remain product-agnostic.
