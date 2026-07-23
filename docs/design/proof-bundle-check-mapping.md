---
status: withdrawn
updated: 2026-07-13
scope: historical proof-bundle check mapping
---

# Proof Bundle to Check Mapping

> **Withdrawn.** The previous mapping promoted execution-mode, risk-class,
> mutation, review, and evidence fields into a deterministic verdict surface.
> It must not be used to implement Task completion, Tool authorization, Keeper
> routing, or a policy-update loop.

## Retained Boundary

A proof bundle may preserve typed facts and provenance from an OAS run. MASC may
verify objective representation facts such as schema compatibility, referenced
artifact readability, and hash equality. Missing or contradictory structural
facts are explicit errors; they are not substituted with a semantic pass or
failure.

## Replacement SSOT

- [Keeper Agent](../spec/05-keeper-agent.md) owns configured-LLM Task
  verification.
- [Command Plane](../spec/06-command-plane.md) owns request-local external-effect
  Gate flow.
- [OAS Integration](../spec/13-oas-integration.md) defines the one-way OAS to
  MASC observation boundary.

Task completion and external-effect authorization are separate decisions. No
proof field or mapped check is shared authority over both.
