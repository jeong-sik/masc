---
rfc: "0328"
title: "Retire the combined governance and perseveration incident plan"
status: Withdrawn
created: 2026-07-08
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: null
related: ["0318", "0319"]
implementation_prs: []
---

# RFC-0328: Retire the combined governance and perseveration incident plan

## Decision

This omnibus incident RFC is withdrawn. It combined three independent causes:

1. an obsolete static execution block;
2. a provider endpoint returning unusable completions;
3. repeated promotion of an ungrounded causal explanation into Keeper memory.

The first cause is removed by the non-hierarchical Keeper Gate and must not be
recreated. Provider health/failover and memory grounding remain valid product
problems, but they must be implemented at their own Runtime and Memory
boundaries instead of being coupled to a governance hierarchy.

## Historical evidence retained

The incident showed a Keeper repeating the same unsupported explanation for
many turns while making no tool-side progress. The active provider also
returned empty or unusable responses, and a manual runtime reassignment fixed a
different Keeper but missed the affected lane. Repeated memory consolidation
then amplified the unsupported explanation.

These observations justify:

- provenance-aware memory promotion and correction;
- explicit provider-health observations and per-Keeper fallback;
- semantic-stagnation signals that wake or reroute one Keeper lane;
- recording tool calls and actual outcomes before claiming an action occurred.

They do not justify a static tool deny list, a risk ladder, or a global pause.

## Follow-up boundary

Any follow-up must be split by owner:

- **Memory** decides how claims are grounded, corrected, retained, and
  forgotten.
- **Runtime** observes provider health and performs configured per-Keeper
  fallback.
- **Keeper Gate** handles explicit request-local HITL, Auto Judge, and Always
  allowed decisions.

No subsystem should infer the others' product semantics from error strings.
