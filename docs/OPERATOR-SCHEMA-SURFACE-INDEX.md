# Operator Schema Surface Index

This is the operator-facing map for MASC runtime output, dashboard response,
SSE, JSONL, and OAS bridge surfaces. It answers where the schema or type truth
lives, who produces it, who consumes it, and which test should catch obvious
path drift.

Machine-readable catalog: `docs/schema-surfaces/operator-output-surfaces.v1.json`.

## Current Surfaces

| Surface | Output | Schema/type truth | Validation |
| --- | --- | --- | --- |
| `masc.keeper_composite.http.v1` | `/api/v1/keepers/:name/composite` | `lib/keeper/keeper_composite_observer.mli`, `dashboard/src/api/schemas/keeper-composite.ts` | Dashboard schema and composite observer tests |
| `masc.dashboard_sse.v1` | Dashboard SSE event envelope | `dashboard/src/schemas/sse.ts`, `dashboard/src/types/sse.ts`, event inventory doc | SSE parser tests |
| `masc.keeper_runtime_manifest.jsonl.v1` | Per-turn runtime manifest JSONL | `lib/keeper/keeper_runtime_manifest.mli` | Manifest JSON roundtrip tests |
| `masc.keeper_execution_receipt.jsonl.v1` | Terminal keeper execution receipt JSONL | `lib/keeper/keeper_execution_receipt.mli` | Receipt invariant tests |
| `masc.keeper_tool_call_log.jsonl.v1` | Keeper tool-call I/O JSONL | `lib/keeper_tool_call_log.mli` | Tool-call log tests |
| `masc.runtime_contract_projection.v1` | Runtime contract JSON projection | `lib/keeper/keeper_runtime_contract.mli` | Tool-call/runtime contract tests |
| `masc.mcp_openapi_tool_schema.v1` | MCP tool schemas and generated OpenAPI | `lib/keeper/keeper_schema.mli`, `lib/tool_schema_dsl.mli` | Tool matrix and OpenAPI smoke tests |
| `masc.oas_bridge_events.v1` | OAS custom events bridged into MASC | `lib/cascade/cascade_event_bridge.mli`, event inventory doc | OAS integration tests |

## Boundary Rules

- Dashboard HTTP response shapes must be parsed through `dashboard/src/api/schemas/`.
- SSE is a freshness transport. Authoritative read models live behind HTTP or durable JSONL artifacts.
- MASC does not duplicate OAS runtime schemas. OAS-owned surfaces are linked by catalog id in `external_refs`.
- If a schema source or test file moves, update the machine-readable catalog in the same change.
