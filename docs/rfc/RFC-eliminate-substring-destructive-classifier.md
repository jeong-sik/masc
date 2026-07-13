---
rfc: "eliminate-substring-destructive-classifier"
title: "Withdrawn command-policy classification experiment"
status: Withdrawn
created: 2026-06-24
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: "docs/spec/05-keeper-agent.md#inv-keeper-008-non-hierarchical-effect-gate"
related: ["0160", "0208", "0254", "0255", "0286"]
implementation_prs: []
---

# Withdrawn command-policy classification experiment

## Decision

This proposal is withdrawn and must not be used as implementation guidance.
MASC does not infer an execution hierarchy from command text, tool identity, or
a locally maintained command taxonomy.

The current contract is
[INV-KEEPER-008](../spec/05-keeper-agent.md#inv-keeper-008-non-hierarchical-effect-gate)
and
[INV-KEEPER-012](../spec/05-keeper-agent.md#inv-keeper-012-structural-execution-invariants):
enforce only objective structural boundaries such as typed input, explicit
working-directory and redirect targets, allowed-path containment, and the
selected runtime sandbox. Subjective external-effect decisions belong to exact
Always Allowed rules, the configured LLM Auto Judge, or non-blocking HITL.

## Historical note

The June 2026 draft compared two command-policy implementations after an
execution incident. That investigation helped expose duplicated authority, but
its classifiers, rollout plan, and acceptance metrics are retired.
