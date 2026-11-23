---
status: reference
---

# Agent Core specifications

Specifications for the code in `packages/agent_core/`, kept beside it.

## Layout

| Path | Holds |
|---|---|
| `rfc/` | RFCs governing provider, capability, tool, and streaming behaviour |
| `design/` | design notes for boundaries that are still live |
| `provider-capabilities-spec.md` | capability axis definitions |
| `provider-catalog.md`, `capability-manifest.md`, `example-capability-manifest.json` | catalog and manifest formats + sample manifest |
| `architecture.md`, `api-stability.md` | library shape and module stability tiers |
| `custom-providers.md`, `multi-endpoint-setup.md` | integration guides |
| `resource-scoped-execution.md`, `http-request-observation.md`, `PERFORMANCE-SLO.md` | resource wave scheduling, HTTP request observation, and TTFT/prefill SLOs |
| `EVENT-CATALOG.md`, `RUNTIME-OUTPUT-SCHEMA-INDEX.md` | event and output schema indexes |
| `schema-surfaces/` | machine-readable schema surfaces |

## Status

Read an RFC's status header before citing it as current.
