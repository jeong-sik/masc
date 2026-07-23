---
status: withdrawn
updated: 2026-07-13
scope: historical CDAL cross-run aggregation proposal
---

# Cross-Run Loader and Window Spec

> **Withdrawn.** The previous window and friction projection was part of the
> retired CDAL policy-update loop. Cross-run counts, recency windows, and
> derived scores must not become authority over Task completion, external
> effects, or Keeper lifecycle.

Raw run artifacts may still be enumerated for observability or benchmark
analysis. A reader must preserve run identity, timestamps, provenance, and
explicit read/decode errors. If it publishes an aggregation, it must expose the
selected source set and window; an empty set is unknown rather than a passing
or failing result.

Active runtime decisions remain request-local:

- configured-LLM Task verification: [Keeper Agent](../spec/05-keeper-agent.md)
- external-effect Gate: [Command Plane](../spec/06-command-plane.md)
- OAS run observations: [OAS Integration](../spec/13-oas-integration.md)
