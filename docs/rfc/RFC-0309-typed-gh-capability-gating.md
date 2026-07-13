---
rfc: "0309"
title: "Withdrawn product-specific capability hierarchy"
status: Withdrawn
created: 2026-07-06
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: "docs/spec/05-keeper-agent.md#inv-keeper-008-non-hierarchical-effect-gate"
related: ["0131", "0254", "0255", "0304"]
implementation_prs: []
---

# Withdrawn product-specific capability hierarchy

## Decision

This RFC is withdrawn. The generic execution and Gate layers must not know a
particular connector, hosting service, CLI, credential scheme, verb family, or
product workflow. They receive typed structural input and an opaque operation
identity; product semantics stay in the product or connector boundary.

External-effect disposition follows the
[non-hierarchical Keeper Gate](../spec/05-keeper-agent.md#inv-keeper-008-non-hierarchical-effect-gate):
exact Always Allowed, configured LLM Auto Judge, or non-blocking HITL. There is
no product-specific capability hierarchy, implicit global refusal, or
Keeper-blocking approval wait in the generic layer.

## Historical note

The July 2026 draft used one repository-hosting workflow to motivate a typed
capability plane. That example exposed a real coupling problem, but placing its
product vocabulary and policy in generic MASC layers was the wrong boundary.
