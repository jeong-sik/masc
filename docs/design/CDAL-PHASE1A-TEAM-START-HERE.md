---
status: withdrawn
updated: 2026-07-13
scope: historical CDAL Phase-1A starter guide
---

# CDAL Phase-1A Team Start Here

> **Withdrawn.** Do not implement the former deterministic contract-judge
> program described by this guide. It depended on a risk/effect taxonomy and
> converted proof-bundle metadata into a policy verdict.

## What Remains Valid

- OAS may emit typed run artifacts and observations.
- MASC may decode them and report structural or storage failures explicitly.
- Observations may be shown to an operator or supplied to a configured model.

They do not authorize a Tool, decide Task completion, route a Keeper, or update
policy by themselves.

## Current Starting Points

1. [Keeper Agent](../spec/05-keeper-agent.md) for Keeper lanes and LLM Task
   verification.
2. [Command Plane](../spec/06-command-plane.md) for the product-neutral external
   effect Gate.
3. [OAS Integration](../spec/13-oas-integration.md) for provider/run boundaries
   and observation.

The Task verifier and external-effect Gate are distinct request-local
boundaries. Neither is a renamed CDAL deterministic kernel.
