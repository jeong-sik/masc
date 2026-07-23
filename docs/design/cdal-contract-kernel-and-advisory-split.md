---
status: withdrawn
updated: 2026-07-13
scope: historical CDAL deterministic-kernel proposal
---

# CDAL Contract Kernel and Advisory Split

> **Withdrawn.** The proposed deterministic kernel treated locally defined
> execution modes, risk/effect classes, mutation rules, evidence counts, and
> review requirements as semantic truth. Moving those labels into typed data
> did not make them objective.

## Retained Boundary

Deterministic code may verify objective properties of its own representation:
schema decoding, identity equality, hashes, BasePath containment, sandbox
confinement, and durable-write results. These checks return facts or explicit
errors only.

Semantic judgments do not belong to a replacement deterministic kernel:

- Task completion is judged by the configured LLM from the concrete Task,
  context, and evidence.
- Each external effect independently uses exact Always Allowed, configured LLM
  Auto Judge, or durable nonblocking HITL.
- OAS emits provider/run observations and remains unaware of MASC policy.

## Replacement SSOT

- [Keeper Agent](../spec/05-keeper-agent.md)
- [Command Plane](../spec/06-command-plane.md)
- [OAS Integration](../spec/13-oas-integration.md)

No CDAL verdict may pause unrelated Keeper work, authorize an effect, or become
a shared completion hierarchy.
