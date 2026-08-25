---
rfc: "0004"
title: "Keep OCaml and TypeScript wire contracts exact"
status: Active
created: 2026-04-26
updated: 2026-08-08
author: vincent
supersedes: []
superseded_by: null
related: []
---

# Exact OCaml and TypeScript wire contracts

MASC wire producers and dashboard decoders share one exact vocabulary for each
surface. A producer emits only fields represented by its typed contract. A
decoder rejects an unknown discriminator, missing required field, invalid
field type, or invalid closed-sum value.

## Agent event projection

`Agent_sdk.Event_bus.payload` is the source sum for Agent core events.
`Keeper_event_bridge.native_event_to_json` matches that sum exhaustively and
projects each public event to SSE JSON. Adding a payload constructor therefore
requires an explicit bridge decision before the build passes. Internal-only
payloads return `None`; public payloads have a complete event-specific shape.

## SSE payload ownership

`Sse_event` owns generated OCaml types for fixed event payloads. Product
emitters use their surface-owned typed builders and publish a complete JSON
object through `Sse`. The public `type` discriminator is a closed vocabulary at
each dashboard slice boundary; arbitrary raw values are rejected.

`Agent_sdk.Event_bus.Custom` is a typed extension constructor. MASC publishes
domain events on the MASC-owned bus from `Event_bus_slots`, and
`Keeper_event_bridge` converts its dot-separated typed topic to the public
colon-separated SSE topic.

## Verification

- `@test/runtest-test_keeper_execution_join` verifies Agent event wire joins.
- `dashboard/src/api/schemas` tests reject malformed transport and snapshot
  payloads at their owning decoder.
- `scripts/check-agent-core-boundary.sh` enforces the one-way dependency from
  MASC into `packages/agent_core`.
