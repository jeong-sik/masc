---
rfc: "0305"
title: "Withdraw global fail-closed governance policy"
status: Withdrawn
created: 2026-07-04
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: null
related: ["0318", "0319"]
implementation_prs: []
---

# RFC-0305: Withdraw global fail-closed governance policy

## Decision

This RFC is withdrawn. It generalized evaluator uncertainty into a
process-wide fail-closed governance posture. In a lane-per-Keeper runtime that
turns an unavailable evaluator or incomplete classification into an unrelated
Keeper stop, which violates the product's liveness boundary.

The replacement is the non-hierarchical Keeper Gate:

- a Gate decision belongs to one request and one Keeper lane;
- explicit HITL remains pending without blocking the Keeper from other work;
- Auto Judge asks the configured model to decide the concrete request;
- an unavailable judge is an explicit request-local error or pending state,
  never an inferred fleet-wide deny;
- schema, sandbox, spawn, permission, and runtime failures remain explicit;
- no risk band, command catalog, or destructive-name classifier supplies a
  hidden terminal wall.

## Historical rationale

The original RFC correctly objected to silent fallback and misleading UI. That
requirement remains: failure must be observed and surfaced. What is retired is
the assumption that visibility requires a global deny posture.

## Non-reintroduction rule

Do not recreate this policy through a default-deny boolean, an unknown-risk
bucket, a global pause, or a pre-tool string classifier. If a product action
requires authorization, represent it as an explicit Keeper Gate request.
