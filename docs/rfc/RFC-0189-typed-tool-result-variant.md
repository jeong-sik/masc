---
rfc: "0189"
title: "Tool result disposition and payload ownership"
status: Implemented
related: ["0062"]
---

# RFC-0189 — Tool result disposition and payload ownership

## Contract

`Tool_result.result` is the internal tool-execution authority. It is the
specialization of the closed disposition type:

```ocaml
type ('completed, 'deferred, 'failed) disposition =
  | Completed of 'completed
  | Deferred of 'deferred
  | Failed of 'failed
```

Completed and deferred outcomes carry `output_payload`. Failed outcomes carry
`failure_payload`, whose `class_ : tool_failure_class` field is required.

## Invariants

1. Success and failure cannot coexist in one result.
2. A failed result always has a failure class.
3. A completed or deferred result never has a failure class.
4. Deferred work remains distinct from completed work.
5. Internal consumers match on `disposition`; they do not infer outcome state
   from JSON payloads, prose, or boolean projections.

## Payload ownership

`output_payload` owns successful or deferred data, metadata, tool name, and
duration. `failure_payload` owns the failure class, operator-facing message,
structured data, tool name, and duration.

Opaque metadata is a one-way boundary projection. It must not become a second
semantic state authority.

## Boundary projection

Protocol adapters may project `Tool_result.result` into MCP, gRPC, HTTP, or
observability envelopes. Such projections are derived views. Retry and routing
decisions continue to consume the typed disposition and the RFC-0062 failure
class.

## Verification

- Constructor and accessor tests cover all three dispositions.
- Serialization tests preserve the disposition and required failure class.
- Dispatch tests prove explicit exception classification at the producing
  boundary.
- Observer tests prove that validation failures retain their typed class.
