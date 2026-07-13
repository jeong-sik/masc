---
status: withdrawn
updated: 2026-07-13
scope: historical accountability and reputation roadmap
---

# Accountability and Reputation V2 Roadmap

> **Withdrawn.** The previous roadmap proposed turning derived reputation and
> accountability measures into routing, economy, review, appeal, and punishment
> policy. That direction creates an ungrounded hierarchy around Keeper activity.
> The original proposal remains in git history; it is not an implementation
> plan.

## Why It Was Withdrawn

The proposed scores, weights, bands, decay buckets, task-difficulty estimates,
peer signals, promotion gates, and routing phases were locally chosen
heuristics. Calibration would not make them objective truths. Connecting those
values to claim eligibility, Keeper routing, rewards, pauses, or bans would let
one aggregate suppress unrelated work in an otherwise independent Keeper lane.

An appeal hierarchy would add more machinery around the same invented
classification rather than repair that boundary error.

## Retained Scope: Observation Only

MASC may retain immutable, attributable facts needed for observation:

- the claim or commitment as made
- the Task, turn, Channel, or Tool provenance attached at creation
- timestamps and stable identifiers
- evidence references supplied by the actor or a configured judge
- an explicit resolution event and the identity/version of its source
- parse, storage, projection, and delivery errors

Aggregations may help an operator inspect those facts, but they are telemetry.
Every aggregation must expose its source window and numerator/denominator where
applicable. An empty denominator is unknown, not a synthetic passing score.

## Forbidden Coupling Removed by This Withdrawal

Observation and reputation data must not:

- authorize or reject a Tool request
- choose a Keeper or route work between Keepers
- pause, stop, throttle, or ban a Keeper
- determine Task completion or claim eligibility
- scale rewards or impose penalties
- become a public or private universal quality rank
- make peer activity a permission signal

Task completion remains a request-specific judgment by the configured LLM
boundary. External effects use the ordinary product-neutral Gate flow. Neither
decision is inferred from an accountability aggregate.

## Replacement Direction

Keep the ledger and observability projection small. When semantic judgment is
needed, present the relevant raw facts to the configured model for that concrete
decision and record its provenance. If human input is required, use durable,
nonblocking HITL for that request. Do not create reputation levels, routing
tiers, automatic punishments, or a separate governance hierarchy.
