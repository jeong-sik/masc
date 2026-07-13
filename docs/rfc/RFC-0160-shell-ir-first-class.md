---
rfc: "0160"
title: "Withdrawn Shell IR decision-substrate plan"
status: Withdrawn
created: 2026-05-23
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: "docs/spec/05-keeper-agent.md#inv-keeper-008-non-hierarchical-effect-gate"
related: ["0042", "0086", "0088", "0091", "0131"]
implementation_prs: [17873, 17884, 17887, 17898, 17903, 17907, 17918, 17919, 17925, 17926, 17930, 17970, 18023, 18026, 18027, 18054, 18060, 18063, 18071, 18116, 18153, 18193, 18195, 18204, 18209, 18211, 18216, 18221, 18236, 18239, 18240, 18241]
---

# Withdrawn Shell IR decision-substrate plan

## Decision

The part of this RFC that made Shell IR a local policy and execution-ranking
authority is withdrawn. Shell IR may remain a typed representation for parsing,
structured dispatch, cwd and redirect validation, and sandbox propagation; it
must not carry or reconstruct a subjective hierarchy for Keeper actions.

External-effect disposition is owned by the
[non-hierarchical Keeper Gate](../spec/05-keeper-agent.md#inv-keeper-008-non-hierarchical-effect-gate).
Objective containment stays at the structural execution boundary described by
[INV-KEEPER-012](../spec/05-keeper-agent.md#inv-keeper-012-structural-execution-invariants).

## Historical note

The May 2026 work consolidated several parsers and command representations.
Those representation improvements can stand independently; the decision stamp,
policy-classification phases, and hierarchy-oriented metrics are not current
requirements.
