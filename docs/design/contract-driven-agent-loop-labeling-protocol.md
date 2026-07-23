---
status: withdrawn
updated: 2026-07-13
scope: historical CDAL labeling protocol
---

# Contract-Driven Agent Loop Labeling Protocol

> **Withdrawn.** The former frozen labels and weighted metrics were designed to
> calibrate the retired CDAL policy loop. They are not an active completion,
> authorization, Keeper-routing, or reputation contract.

Existing labeled fixtures may remain as historical benchmark data when their
provenance and protocol version are explicit. A benchmark label does not become
runtime truth and must not pause, rank, route, reward, or ban a Keeper.

For active behavior:

- the configured LLM judges a concrete Task from its context and evidence;
- the product-neutral Gate decides each concrete external effect separately;
- raw model/judge outputs and failures are recorded without converting dataset
  labels into deterministic policy.

See [Testing](../spec/15-testing.md), [Keeper Agent](../spec/05-keeper-agent.md),
and [Command Plane](../spec/06-command-plane.md).
