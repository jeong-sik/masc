---
title: Descriptor as Visibility/Metadata SSOT — Surface Projection from descriptor.policy.visibility
rfc: "0190"
status: Draft
created: 2026-05-27
updated: 2026-05-27
author: vincent
supersedes: []
superseded_by: null
related: ["0064", "0179", "0182"]
implementation_prs: []
---

# RFC-0190 — Descriptor as Visibility/Metadata SSOT

Status: Draft · Architectural framing, no code yet
Related: RFC-0064 (two-surface tool model), RFC-0179 (`keeper_*` descriptor coverage), RFC-0182 (`masc_*` descriptor projection)

## 0. Problem framing

A 2026-05-27 surface↔descriptor audit (worktree `refactor-mcp-surface-projection-20260527`, `bin/audit_descriptor_surface.exe`) measured the set-difference between `Tool_catalog_surfaces.public_mcp_surface_tools` (operator-facing MCP surface, 57 entries) and `Agent_tool_descriptor.{public,internal}_descriptors` (keeper-facing typed dispatch fact set, 7 + 128 entries).

Result:

| Direction | Count | Examples |
|---|---|---|
| surface ∖ descriptor | **9** | `masc_start`, `masc_join`, `masc_leave`, `masc_broadcast`, `masc_messages`, `masc_who`, `masc_keeper_sandbox_status`, `masc_persona_generate`, `masc_keeper_create_from_persona` |
| descriptor ∖ surface | 82 | `keeper_board_*` (managed-keeper twins), `masc_board_delete`, `masc_config`, `masc_get_metrics`, … (intentionally not operator-visible) |
| intersect | 46 | already descriptor-backed surface entries |

Two SSOTs that should be one. RFC-0179 + RFC-0182 brought descriptors to *most* of the `masc_*` operator surface, but **9 lifecycle/authoring tools never entered the descriptor system at all** because their handlers live in `lib/tool_inline_dispatch.ml` (MCP server-level inline path), not in `Tool_coord.dispatch` or the cluster `*_dispatch_ref` references the descriptor `runtime_handler` enum routes to.

The descriptor enum (`In_process | Filesystem | Shell_ir | Remote_mcp`) is closed and assumes the descriptor *owns* execution. Tools handled by inline dispatch have no slot.

## 1. Hypothesis the audit invalidated

RFC-0179 framed coverage as "every tool the LLM can call needs a descriptor." That framing assumes a single dispatch axis. The audit shows two distinct axes:

- **Visibility axis** (`policy.visibility`): who can see/call this tool — `Public_mcp | Keeper_internal | Spawned_agent | Local_worker | Admin | Keeper_denied | …`.
- **Execution axis** (`executor`): how the call is dispatched — `In_process | Filesystem | Shell_ir | Remote_mcp`.

Today `Agent_tool_descriptor.t` collapses both axes into one record, but coverage is asymmetric — the execution axis demands the descriptor own dispatch, which the inline-path tools cannot satisfy without being moved.

## 2. Goal

Make `Agent_tool_descriptor.t` the single source of truth for *visibility and metadata*, with execution-axis ownership being optional. After this RFC:

- `Tool_catalog_surfaces.public_mcp_surface_tools` is computed as
  `filter (fun d -> d.policy.visibility = Public_mcp) all_descriptors`.
- Every entry on every surface (`public_mcp_surface_tools`, `spawned_agent_surface_tools`, `local_worker_surface_tools`, `session_min_surface_tools`, `admin_surface_tools`) has a descriptor.
- Dispatch routing remains opt-in: descriptors whose execution lives in `Tool_inline_dispatch` declare `executor = External_inline` and `runtime_handler = Tool_external_inline`, and the descriptor dispatcher returns `None` for them, leaving the inline path unchanged.
- The surface↔descriptor diff becomes a compile-/test-time invariant (Phase 4).

## 3. Non-goals

- Move inline-path handlers into the descriptor in-process runtime. The inline path predates descriptors and crosses module boundaries (`Mcp_server_eio_execute`); migrating it is RFC-scope of its own.
- Change visibility semantics. The `Tool_catalog.visibility` enum stays as-is.
- Touch `Tool_catalog_surfaces.keeper_internal_tools` or any other hand-managed list beyond `public_mcp_surface_tools` in this RFC. Other surfaces are Phase 5+ follow-ups.

## 4. Model change

```ocaml
type executor =
  | Shell_ir
  | Filesystem
  | Remote_mcp
  | In_process
  | External_inline  (* NEW: descriptor is metadata-only;
                        execution owned by tool_inline_dispatch *)

type runtime_handler =
  | ... (* existing variants *)
  | Tool_external_inline  (* NEW: paired with [External_inline] *)
```

`Agent_tool_runtime.handle` gains:

```ocaml
let handle ctx ~descriptor ~args =
  match descriptor.executor with
  | Filesystem      -> handle_filesystem ctx descriptor args
  | Shell_ir        -> handle_shell_ir   ctx descriptor args
  | Remote_mcp      -> handle_remote_mcp ctx descriptor args
  | In_process      -> handle_in_process ctx descriptor args
  | External_inline -> None  (* fall through to inline_dispatch *)
```

`handle_internal` already returns `string option`; existing callers treat `None` as "descriptor system declines, let the next path handle." The inline path is *that* next path for MCP-server entry points; for keeper-facing entry it is unknown-tool (correct — these tools were never keeper-callable).

## 5. Descriptor entries to add

9 new internal descriptors, all with `visibility = Public_mcp`, `executor = External_inline`, `runtime_handler = Tool_external_inline`.

| name | cluster id | input_schema source |
|---|---|---|
| `masc_start` | `masc.coord.start` | `Tool_schemas_coord.schemas` |
| `masc_join` | `masc.coord.join` | `Tool_schemas_coord.schemas` |
| `masc_leave` | `masc.coord.leave` | `Tool_schemas_coord.schemas` |
| `masc_broadcast` | `masc.comm.broadcast` | `Tool_schemas_comm.schemas` |
| `masc_messages` | `masc.comm.messages` | `Tool_schemas_comm.schemas` |
| `masc_who` | `masc.comm.who` | `Tool_schemas_comm.schemas` |
| `masc_keeper_sandbox_status` | `masc.keeper.sandbox_status` | existing keeper schema |
| `masc_persona_generate` | `masc.persona.generate` | persona authoring schema |
| `masc_keeper_create_from_persona` | `masc.persona.create_from` | persona authoring schema |

Each entry pulls `description` and `input_schema` from the inline dispatch's existing schema registration; **no duplication is introduced** — descriptors reference the same `Masc_domain.tool_schema` records the inline path already publishes.

## 6. Implementation phases

| Phase | PR scope | Verifiable end-state |
|---|---|---|
| **P1** | `External_inline` + `Tool_external_inline` enum extension. `handle` returns `None` for `External_inline`. Zero descriptor entries added yet. | Build green. `internal_descriptors` count unchanged. Test: a synthetic `External_inline` descriptor routes through `handle` → `None`. |
| **P2** | Add 3 coord lifecycle descriptors (`masc_start/join/leave`). | `audit_descriptor_surface` shows 6 missing, not 9. `masc_start` etc. carry `Public_mcp` visibility. |
| **P3** | Add 3 comm descriptors (`masc_broadcast/messages/who`). | 3 missing. Inline path untouched. |
| **P4** | Add 3 remaining (`masc_keeper_sandbox_status`, 2 persona). | 0 missing. **Visibility projection** introduced: `public_mcp_surface_tools = filter (visibility = Public_mcp) all_descriptors |> sort_uniq`. Existing hand list deleted. Compile-time test fails if any surface drift. |
| **P5** (follow-up) | Audit other surfaces (`spawned_agent_surface_tools` etc.) → separate RFC. | Out of scope for 0190. |

P1–P4 each merges independently. P1 has the only schema change; P2–P4 are pure data additions. No phase requires an inline-path code change.

## 7. Workaround-bar check

This RFC does *not* trigger workaround signatures:

- §1 telemetry-as-fix: no. Fixes structural surface↔descriptor drift, not visibility.
- §2 string/substring classifier: no. Eliminates string list `public_mcp_surface_tools` in favor of typed `visibility` enum filter.
- §3 N-of-M: no — the phasing rule is *each phase strictly reduces missing-count*; P4 is forced by an invariant test, not "we'll get to the rest later."

## 8. Open questions

1. Should `External_inline` permit a non-empty `runtime_handler` other than `Tool_external_inline` for future inline-cluster splits? Pinning to one variant is the conservative choice; reconsider only if a real second consumer appears.
2. `masc_persona_generate` and `masc_keeper_create_from_persona` may have stricter `approval` semantics than current handler defaults — confirm against `tool_inline_dispatch` `inline_tool_requires_*` lists in P4.
3. RFC-0064 hard-cut public set (7 LLM-native names) is unchanged; the visibility projection covers MCP surface only.

## 9. Rejected alternatives

- **(A-pragmatic)** Add 9 descriptors with `In_process` executor + dispatch arms in `handle_masc_coord` / `handle_masc_persona` / `handle_masc_keeper` that call back into `Tool_inline_dispatch`. Rejected: introduces dual handlers for the same tool name (descriptor cluster *and* inline path), guaranteed drift under future changes.
- **(B-only)** Keep the hand list, add a test that asserts every surface entry exists in *some* known set (descriptor or allowlist). Rejected as the *final* state — drift cannot be eliminated, only reported. Acceptable as an *interim* gate (see RFC-0190 implementation companion: invariant test PR can land before P1 to ratchet the count down).

## 10. Acceptance criteria

- RFC merged.
- P1–P4 PRs all merged.
- `Tool_catalog_surfaces.public_mcp_surface_tools` is a function over `all_descriptors`, not a literal list.
- `audit_descriptor_surface` reports 0 missing for `Public_mcp` surface.
- `External_inline` is the *only* executor whose `handle` returns `None`.
