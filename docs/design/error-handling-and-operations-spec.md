---
status: withdrawn
updated: 2026-07-13
scope: historical CDAL operations proposal
---

# CDAL Error Handling and Operations Spec

> **Withdrawn.** This document operationalized the retired deterministic CDAL
> verdict service. Its verdict taxonomy, rollout gates, and evaluator SLOs are
> not an active Keeper constraint.

The general failure rule remains: schema, storage, provider, timeout,
cancellation, projection, and delivery failures are explicit typed errors and
observable events. They must not silently become `allow`, `done`, a healthy
empty result, or a global Keeper pause.

Error reporting does not decide semantic truth. The configured LLM owns Task
verification, and each external effect uses the product-neutral Gate. Failure
of one request leaves unrelated Keeper lanes and activities available.

See [Keeper Agent](../spec/05-keeper-agent.md),
[Command Plane](../spec/06-command-plane.md), and
[OAS Integration](../spec/13-oas-integration.md).
