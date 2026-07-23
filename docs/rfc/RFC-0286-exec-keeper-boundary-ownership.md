---
rfc: "0286"
title: "Superseded exec and Keeper boundary diagnosis"
status: Superseded
created: 2026-06-23
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: "docs/spec/05-keeper-agent.md#inv-keeper-008-non-hierarchical-effect-gate"
related: ["0131", "0160", "0208"]
implementation_prs: []
---

# Superseded exec and Keeper boundary diagnosis

## Decision

This diagnosis is superseded and is not implementation guidance. Execution
syntax, explicit cwd and redirect targets, allowed-path containment, and runtime
sandboxing are structural concerns owned by their concrete boundaries. They do
not feed a parallel effect hierarchy or a Keeper-wide stopping rule.

Subjective external-effect decisions are owned by the
[non-hierarchical Keeper Gate](../spec/05-keeper-agent.md#inv-keeper-008-non-hierarchical-effect-gate).
A pending request affects only that request; turn liveness and other Keeper
lanes continue independently.

## Historical note

The June 2026 incident review found overlapping redirect and lifecycle
authorities. Its useful conclusion was boundary separation; its proposed
cross-layer policy contracts and follow-up implementation plan are retired.
