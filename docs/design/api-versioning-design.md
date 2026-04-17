---
status: reference
last_verified: 2026-04-17
code_refs:
  - lib/
  - bin/main_eio.ml
---

# H3: API Versioning Design

> Status: Draft
> Author: inventory-gap-analysis session
> Date: 2026-03-29
> Ref: RFC #3646, Gap H3

## 1. Problem Statement

masc-mcp exposes 4 API surfaces (HTTP REST, MCP JSON-RPC, gRPC, WebSocket).
MCP and gRPC have version negotiation. HTTP REST and Tool Schemas do not.

When a breaking change ships:
- HTTP REST clients get unexpected JSON shapes with no migration path
- Tool schema changes (rename, input change, removal) cause silent failures
- No documented policy for what constitutes a "breaking change"
- No deprecation timeline or sunset communication

## 2. Current State

| Surface | Endpoints | Version Mechanism | Gap |
|---------|-----------|-------------------|-----|
| **MCP JSON-RPC** | `/mcp`, `/sse` | `protocolVersion` in initialize (4 versions: 2024-11-05 .. 2025-11-25) | None (well-versioned) |
| **gRPC** | 6 RPCs | `masc.coordination.v1` package | None (proto3 compat rules apply) |
| **HTTP REST** | 70+ under `/api/v1/` | Hardcoded path prefix | **No v2 path, no negotiation, no deprecation** |
| **WebSocket** | `/ws` | Shares MCP protocol version | None (inherits MCP) |
| **Tool Schemas** | 305+ tools | None | **No per-tool version, no deprecation metadata** |
| **OpenAPI** | `/api/v1/openapi.json` | Generated dynamically | **Not bound to a spec version** |

## 3. Design Constraints

1. **Single developer, personal project** -- no enterprise API governance overhead
2. **Primary consumers are dashboard (internal) and MCP clients (Claude Code, agents)**
3. **MCP tools are the main external contract** -- REST is mostly dashboard-internal
4. **Backward compatibility matters for keeper/agent sessions** that span hours

## 4. Non-Goals

- Full content-negotiation (Accept header routing) -- too complex for current scale
- Parallel v1/v2 route handlers -- maintenance burden too high
- GraphQL gateway -- different paradigm, not applicable here

## 5. Proposed Design

### 5.1 HTTP REST: Additive-Only + Sunset Headers

**Policy**: `/api/v1/` is the only version prefix. No `/api/v2/` planned.

Breaking changes are avoided by:
1. **Additive fields only** -- new JSON fields are added, never removed
2. **Null-safe contracts** -- clients must tolerate unknown fields and missing optional fields
3. **Sunset header** -- when an endpoint is deprecated, responses include:
   ```
   Sunset: Sat, 01 Jun 2026 00:00:00 GMT
   Deprecation: true
   Link: </api/v1/replacement>; rel="successor-version"
   ```
4. **OpenAPI `deprecated` flag** -- generated spec marks deprecated endpoints

**Implementation**:
```ocaml
(* In server route handler *)
let with_sunset ~sunset_date ~successor response =
  response
  |> add_header "Sunset" sunset_date
  |> add_header "Deprecation" "true"
  |> add_header "Link" (Printf.sprintf "<%s>; rel=\"successor-version\"" successor)
```

**Rationale**: A single-developer project with an internal dashboard doesn't need `/api/v2/`.
The dashboard is always deployed alongside the server. MCP clients don't use REST.
Additive-only evolution with sunset headers covers the actual risk.

### 5.2 Tool Schema: Version + Deprecation Metadata

Add two optional fields to `tool_schema`:

```ocaml
type tool_schema = {
  name : string;
  description : string;
  input_schema : Yojson.Safe.t;
  version : string option;        (* NEW: semver, e.g. "1.2.0" *)
  deprecated : bool;              (* NEW: soft removal signal *)
  successor : string option;      (* NEW: replacement tool name *)
}
```

**Wire format** (JSON-RPC `tools/list` response):
```json
{
  "name": "masc_room_strategy_set",
  "description": "...",
  "inputSchema": { ... },
  "annotations": {
    "version": "1.0.0",
    "deprecated": true,
    "successor": "masc_heartbeat_start"
  }
}
```

**MCP SDK compliance**: The `annotations` field is supported since MCP protocol version
`2025-03-26`. For older clients, annotations are silently omitted.

**Versioning rules**:
- PATCH: description change, optional field added to input
- MINOR: new required field with default, output shape extended
- MAJOR: required field without default, field renamed/removed, semantic change

### 5.3 gRPC: Proto3 Compatibility Rules (Already Sufficient)

gRPC under `masc.coordination.v1` follows standard proto3 rules:
- Fields can be added (new field number)
- Fields can be deprecated (reserved keyword)
- Fields must never be removed or renumbered
- New services/methods are additive

**No additional mechanism needed.** Document the rules in `proto/README.md`.

### 5.4 Breaking Change Policy

| Change Type | Classification | Required Action |
|-------------|---------------|-----------------|
| Add JSON field to response | **Compatible** | None |
| Add optional tool input param | **Compatible** | Bump tool version PATCH |
| Add required tool input param with default | **Minor** | Bump tool version MINOR |
| Add required tool input param without default | **Breaking** | Bump MAJOR, deprecate old tool, keep both for 2 minor releases |
| Remove/rename JSON field | **Breaking** | Sunset header, 30-day grace |
| Remove tool entirely | **Breaking** | Mark deprecated, keep 2 minor releases, then remove |
| Change field type | **Breaking** | New field name, deprecate old |
| Change error code semantics | **Breaking** | Version bump, document in CHANGELOG |

### 5.5 OpenAPI Spec Binding

The dynamic OpenAPI generation at `/api/v1/openapi.json` should include:
```json
{
  "openapi": "3.0.3",
  "info": {
    "title": "MASC MCP Server",
    "version": "0.2.0",
    "x-api-contract-version": "v1"
  }
}
```

The `info.version` field must match the server's SemVer release.
CI should validate that `openapi.json` output is parseable and `info.version` matches `Version.version`.

## 6. Implementation Plan

| Phase | Scope | Effort | Files |
|-------|-------|--------|-------|
| **P0: Policy** | Document breaking change policy, proto3 rules | 1 day | `docs/`, `proto/README.md` |
| **P1: Tool annotations** | Add `annotations` to tool_schema, populate for deprecated tools | 2-3 days | `types_core.ml`, `mcp_server_eio.ml`, tool schema files |
| **P2: Sunset headers** | Add sunset header helper, apply to known deprecated endpoints | 1-2 days | `server_routes_http_*.ml` |
| **P3: OpenAPI binding** | Bind `info.version` to `Version.version`, CI validation | 1 day | `transport_rest.ml`, `scripts/` |
| **P4: Feature flag integration** | Expose tool deprecation in `masc_feature_flags` | 0.5 day | `feature_flag_registry.ml`, `tool_misc.ml` |

Total: **5-7 days** (can be parallelized with other work).

## 7. Migration Path

**For existing tools being deprecated (from Wave 1)**:
Tools already removed in Wave 1 (encryption, tempo, notifications) don't need deprecation
since they had zero external callers. Future removals should follow:

1. Mark `deprecated = true` + set `successor` in tool schema
2. Keep tool functional for 2 minor releases (~2-4 weeks)
3. Move to hidden list (`include_deprecated=true` to see)
4. Remove after grace period

**For REST endpoints**:
No endpoints are currently deprecated. When needed:
1. Add Sunset header to response
2. Log deprecation warnings server-side
3. Update OpenAPI spec with `deprecated: true`
4. Remove after 30-day grace period

## 8. Trade-offs

| Decision | Alternative | Why This |
|----------|-------------|----------|
| No `/api/v2/` | Version prefix routing | Single developer, dashboard is co-deployed |
| Tool annotations over version prefix | `/tools/v2/list` | MCP spec supports annotations natively |
| 30-day sunset period | 90-day enterprise grace | Personal project, fast iteration cycle |
| Additive-only REST | Breaking changes with version bump | Simpler, fewer code paths |

## 9. Verification

- [ ] `scripts/check-openapi-version.sh`: `info.version` matches `Version.version`
- [ ] Tool schema test: every tool with `deprecated=true` has `successor` set
- [ ] No REST endpoint returns `Sunset` header without corresponding CHANGELOG entry
- [ ] Proto files pass `buf breaking` check against previous release tag
