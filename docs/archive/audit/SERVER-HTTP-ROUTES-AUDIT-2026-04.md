# Server HTTP Routes Surface Audit — Phase 1

**Date**: 2026-04-30
**Scope**: HTTP route registration + handlers in `lib/server/`
**Pattern**: 4-phase audit (`docs/process/AUDIT-CHAIN-4-PHASE-PATTERN.md`, PR #12193)
**Position**: Third application of the codified pattern (after Dashboard observability PR #12202/12208 and Auth/credential PR #12209).

## 1. Surface

`lib/server/`: 59 ml files + 59 mli files. 42 files match HTTP route patterns (`Http_server`, `register_route`, `dispatch`, `add_routes`, route closures).

### 1.1 Domain route modules (16)

`server_routes_http_routes_<domain>.ml` for: `activity`, `artifacts`, `attribution`, `autonomous`, `cascade`, `channel_gate`, `dashboard`, `frontend`, `git_graph`, `legendary_bash`, `multimodal`, `provider_runs`, `resilience`, `room`, `sidecar`, `verification`.

### 1.2 Infrastructure (~10)

- `server_routes_http.ml` — composer (calls `add_routes` on the 16 domain modules)
- `server_routes_http_common.ml` — shared helpers (auth, query parsing, CORS)
- `server_routes_http_pages.ml` — HTML rendering for frontend
- `server_routes_http_runtime.ml` — runtime context injection
- `server_routes_http_keeper_stream.ml` — streaming protocol helpers
- `server_dashboard_http*.ml` (8) — dashboard HTTP layer
- `server_bootstrap_http.ml` — startup HTTP server initialization
- `server_mcp_transport_http*.ml` — MCP protocol HTTP mapping

## 2. Gap taxonomy (Phase 1 candidates — conservative bias)

| Class | Description | Estimated count | Severity |
|---|---|---|---|
| C1 | Routes without request size-limit guard (body / upload) | 8–12 | Medium |
| C2 | Routes without per-request telemetry (request_total, latency, errors) | 14–16 | **High** |
| C3 | Error response format inconsistency (3+ shapes coexist) | 10–14 | Medium |
| C4 | Routes without auth boundary check | 3–5 | Low (intentional public routes likely) |
| C5 | Anchors: auth + telemetry + guard already present | 4–6 | Low (reference) |

### 2.1 Severity rationale

- **C2 = High** — only `/metrics` endpoint (in `frontend.ml`) currently exports Prometheus counters; individual route handlers lack `request_total` / `request_duration_seconds` / `request_errors_total`. Without per-route telemetry, the dashboard observability work (PR #12202/12208) cannot land its Tier P1 instrumentation cleanly.
- **C3 = Medium** — mixed error patterns observed: `Error (sprintf "...")` vs `Yojson error objects` vs `Types.masc_error_to_string`. No unified error envelope across modules. Phase 2 will determine if this is semantic inconsistency or cosmetic variance.
- **C1 = Medium** — `legendary_bash`, `multimodal`, `artifacts` routes accept potentially large bodies. Phase 2 must check whether limits are enforced upstream (HTTP server layer) or per-route.
- **C4 = Low** — most routes already wrap in `with_tool_auth`; ~33 grep hits. Some routes intentionally public (frontend assets, /metrics, health checks). Phase 2 will whitelist intentional exemptions.

### 2.2 Conservative-bias notes

The 4-phase pattern doc (PR #12193) predicts Phase 1 will over-classify, Phase 2 will narrow. Concrete predictions to revisit in Phase 2:

- C2 estimate (14–16) may shrink if a shared middleware in `server_routes_http_common.ml` already emits telemetry for all routes (Phase 2 must trace `Http.Router.get/post` call chains).
- C3 estimate (10–14) may shrink if "inconsistency" is purely syntactic (field order) and the schema is consistent.
- C1 estimate (8–12) may collapse to 0 if `Http_server_eio` enforces body limits globally.

## 3. Recommended ratchets (Phase 4 deferred)

Three families, descriptive only at Phase 1:

```
http_routes_with_telemetry           (INC, floor TBD)
  Purpose: drive per-route Prometheus counter coverage from current
  baseline (estimated 4–6) toward 16 (one per domain module).

http_routes_error_envelope_shapes    (DEC, floor TBD)
  Purpose: collapse the heterogeneous error format set toward
  a single canonical envelope. Phase 2 enumerates actual shapes.

http_routes_size_limit_coverage      (INC, floor TBD)
  Purpose: ensure upload-heavy routes (legendary_bash, multimodal,
  artifacts) declare explicit body-size caps.
```

Floor values intentionally TBD until Phase 2 measurement (per audit pattern §3).

## 4. Phase 2 plan (next PR)

1. **Telemetry trace**: script that walks each `Http.Router.get/post/put/delete` call site and checks for `Prometheus.observe_*` or `inc_counter` emission inside the handler closure (or via shared middleware).
2. **Error envelope sample**: pick 3–5 routes from different domains; extract actual error JSON via integration test logs. Classify as truly heterogeneous vs cosmetic variance.
3. **Auth whitelist**: enumerate routes that intentionally lack `with_tool_auth` (frontend assets, /metrics, health). Update C4 verdict — likely shrinks to 0–1 after whitelist.
4. **Size limit inheritance**: confirm whether `Http_server_eio` enforces a global body size cap. If yes, C1 collapses to "satisfied-by-platform" and the C1 ratchet drops out.

## 5. Out-of-scope for Phase 1

- WebSocket / streaming routes (`server_routes_http_keeper_stream.ml`) — separate scoping needed; Phase 2 may split.
- MCP protocol HTTP mapping (`server_mcp_transport_http*.ml`) — different invariants than user-facing routes.
- Rate limiting per IP / per token — orthogonal to per-route guard; separate audit chain.

## 6. Audit chain context

This is the **fifth audit chain** to apply the 4-phase pattern, and the **third** to invoke the codified pattern doc (PR #12193) as starting point:

| # | Chain | Codified pattern invocation |
|---|---|---|
| 1 | OAS↔MASC boundary (Q-P0-3) | pattern source |
| 2 | TLA+ specs gap (Q-P0-2) | second instance |
| 3 | TLA+ PPX adoption (runtime) | third instance |
| 4 | Dashboard observability (#12202) | first to invoke codified pattern |
| 5 | Auth/credential (#12209) | second to invoke codified pattern |
| 6 | **Server HTTP routes (this doc)** | third to invoke codified pattern |

Continued reuse confirms portability across heterogeneous domains (boundary, spec, observability, security, transport).

## 7. References

- PR #12193 — 4-phase audit pattern (codification)
- PR #12202 / #12208 — Dashboard observability Phase 1+2 (sibling chain)
- PR #12209 — Auth/credential audit Phase 1 (sibling chain)
- `lib/server/server_routes_http*.ml` — primary surface
- `MEMORY.md`: `feedback_module_alias_grep_required_for_test_consumers` (cascade-include surface analysis precedent)

## 8. Summary table

| Metric | Value |
|---|---|
| Total ml files in `lib/server/` | 59 |
| Total mli files in `lib/server/` | 59 |
| Files matching HTTP route patterns | 42 |
| Domain route modules | 16 |
| Estimated C5 anchors | 4–6 |
| Estimated C2 (no telemetry) | 14–16 |
| Recommended ratchets | 3 |
