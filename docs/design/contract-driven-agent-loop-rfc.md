---
status: withdrawn
updated: 2026-07-13
scope: historical Contract-Driven Agent Loop proposal
---

# Contract-Driven Agent Loop RFC

> **Withdrawn.** The former `contract -> run -> proof -> eval -> policy update`
> loop is not an active MASC/OAS architecture. It coupled OAS run metadata to a
> MASC policy hierarchy and used risk/effect taxonomies and deterministic
> evidence checks as semantic authority.

## Why This Is Not the New Gate

The replacement has two deliberately separate boundaries:

1. The configured LLM judges whether a concrete Task is complete from its
   context and evidence.
2. The product-neutral Gate decides each concrete external effect through exact
   Always Allowed, configured LLM Auto Judge, or durable nonblocking HITL.

Task completion does not authorize an effect. An effect decision does not mark
a Task complete. Neither boundary emits a policy update or global Keeper rank.

## Retained OAS Boundary

OAS owns provider/model calls, run lifecycle, and typed observations. MASC may
consume those observations without teaching OAS about Keeper, Task, Goal,
Board, Connector, product tools, or Gate policy. Structural artifact failures
remain explicit and observable.

## Replacement SSOT

- [Keeper Agent](../spec/05-keeper-agent.md)
- [Command Plane](../spec/06-command-plane.md)
- [OAS Integration](../spec/13-oas-integration.md)

The detailed former design remains available in git history for archaeology
only.
