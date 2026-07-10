# Tool surface: `keeper_*` vs `masc_*` — the two-plane boundary

- Status: reference (answers bug #57)
- Date: 2026-07-11
- Audit: 4-group backend-sharing audit (wf_87f822f9, 5 agents, opus, file:line traced)

## The question (#57)

> "Tools 에 왜 masc_*, keeper_* 가 아직도 이렇게 분리인건지. 중복 tools 는 왜 안지우는건지… 노출 tools, 내부 tools 분리가 아직 명확안함."

## Short answer

The `keeper_*` / `masc_*` split is an **intentional typed exposure boundary, not
accidental duplication**. Across the 21 name-overlapping pairs, **zero** have a
second backend implementation — every `keeper_*` tool that rhymes with a
`masc_*` tool is a thin front-door that reaches the *same* handler. There is
nothing to delete: removing either name breaks one of two distinct planes.

## Two planes, one backend

There are two orthogonal tool-exposure planes:

| Plane | Names | Who calls it | Where advertised |
|---|---|---|---|
| **External MCP** | `masc_*` / `operator_*` | MCP clients, dashboard, spawned agents | `tools/list` filtered by `tool_profile` |
| **Keeper in-process** | `keeper_*` | the keeper autonomous-agent runtime (its own turn loop) | keeper descriptor surface (`keeper_tool_descriptor.ml` `internal_descriptors`), gated per-turn by `keeper_unified_prompt` `tool_allowed` |

A keeper cannot reach the public MCP dispatch, and MCP clients cannot reach the
keeper in-process runtime. Each plane needs its own front-door onto the shared
backend. Where a name collides, the two typed entry points share one backend
with plane-appropriate wrapping (public: rate-limit / SSE / audit / mention;
keeper: caller-identity injection / typed-outcome anti-thrash).

## Backend-sharing evidence (traced)

### Board — one dispatch router
`keeper_board_*` does **not** re-implement any board logic. The keeper runtime
translates its `Tool_name.Board_name.t` variant into the `masc_board_*` string
via `Tool_name.Board_name.to_string` (`lib/tool/tool_name.ml:88-110`) and calls
the exact backend the MCP path calls:

- shared router: `Board_tool.handle_tool` = `Board_tool_dispatch.handle_tool`
  (`lib/board_tool_adapter/board_tool.ml:42`, `board_tool_dispatch.ml:17`)
- keeper entry: `lib/keeper/keeper_tool_board_runtime.ml:170-172`
- MCP entry: `lib/mcp_tool_runtime_board.ml:243-428`
- keeper-side additions are cross-cutting only: caller-identity injection
  (`meta.name` → author/voter/owner) and, for `keeper_board_post`, a
  quantitative-evidence gate + `post_kind=Automation_post`
  (`keeper_tool_board_runtime.ml:82-126,143-180`)

The in-process runtime even exposes a direct `masc_board_*` passthrough
(`handle_masc_board`, `keeper_tool_in_process_runtime.ml:282-304`), reinforcing
that both name surfaces are deliberate front-doors to one backend.

### Task lifecycle — one store, one FSM
All five `keeper_task_*` tools mutate the **same** `.backlog` store
(`write_backlog`, `lib/workspace/workspace_backlog.ml:111`, `with_file_lock` +
version+1 CAS) through the **same** FSM (`Workspace_task_lifecycle`):

- `keeper_task_done` / `keeper_tasks_list` call the *identical* functions masc
  uses (`Task.Tool.handle_transition` / `Workspace.list_tasks`)
- `keeper_task_claim` / `keeper_task_create` call sibling functions in the same
  `Workspace` module writing the same store
- `keeper_tasks_audit` has no masc counterpart

**Premise correction (from the audit):** masc task tools do *not* route through
"`mcp_server.ml task_fsm_transitions` + `task_state.ml`". `task_fsm_transitions`
(`mcp_server.ml:419`) is a **static schema descriptor** feeding `schema_json`
(`:455`) — it executes no transition — and there is no `task_state.ml` module in
the tree. (This corrected an earlier hand diagnosis; the audit trace is the SSOT.)

### Library, broadcast — shared handlers
- `keeper_library_read` / `keeper_library_search` call the same
  `Tool_library.handle_read` (`lib/tool_library.ml:247`) / `handle_search`
  (`:419`) as `masc_library_read` / `masc_library_search`.
- `keeper_broadcast` / `masc_broadcast` share `Workspace.broadcast` (public
  entry `lib/mcp_tool_runtime_comm.ml:77`, keeper entry
  `lib/keeper/keeper_tool_task_runtime.ml:435`); `capability_registry.ml:186`
  formally aliases `masc_broadcast → keeper_broadcast`.

## `tool_profile` is a *different* axis (common confusion)

`tool_profile` (`Full | Managed_agent | Operator_remote`,
`lib/mcp_server_eio_tool_profile.ml:8-12`) filters **only** the public
`masc_*`/`operator_*` surface on a given MCP endpoint:

- `Full` = `Config.visible_tool_schemas ∩ is_public_mcp`
- `Managed_agent` = SDK contract + `spawned_agent_public_tool_names` passthrough
- `Operator_remote` = 4 `masc_operator_*` control-plane tools only

Every one of those inventories is `masc_*`/operator. `keeper_*` names are
**never** advertised on any profile's `tools/list`. So `tool_profile` does not
govern the `keeper_*`/`masc_*` split — it governs which `masc_*` tools a given
external endpoint sees. The two boundaries are orthogonal.

## Keeper-only tools (no masc counterpart)

These live solely on the keeper plane — deleting them removes real capability:

- `keeper_memory_search` / `keeper_memory_write`
  (`lib/keeper/keeper_tool_memory_runtime.ml:333`)
- all six `keeper_voice_*` (single backend
  `Keeper_tool_voice_runtime.handle_voice_tool`,
  `lib/keeper/keeper_tool_voice_runtime.ml:391`)
- `keeper_ide_annotate`, `keeper_time_now`, `keeper_tasks_audit`

Note: the `masc_*memory*` / `masc_ide_*` strings that *look* like tools are
Prometheus metric names, and `masc_voice_*` strings are temp-file prefixes —
not MCP tools. (A raw `grep "masc_[a-z_]+"` returns ~659 hits, but most are
metrics/prefixes, not the tool inventory.)

## Names that merely rhyme (no shared backend, not duplicates)

- `keeper_context_status` (LLM context-window telemetry) vs `masc_status`
  (workspace status) — distinct.
- `keeper_surface_read/post` (`Keeper_surface_*` + `Keeper_chat_store`) vs
  `masc_surface_audit` (`Dashboard_surface_readiness`) — distinct.
- `keeper_person_note_set` (`Keeper_person_notes.set_note`, speaker-keyed) vs
  `masc_note_add` (`Planning_eio.add_note`, task-keyed) — distinct.
- `keeper_handoff` is not even an invokable tool.
- `keeper_tools_list` / `keeper_tool_search` vs `masc_tool_help`: justified
  separate introspection because the keeper discovers over its own
  descriptor-routed surface, which the public MCP dispatch does not expose.

## Recommendation

**No tool removal.** There are zero true-duplicate implementations to delete;
each name is load-bearing on its plane. The user's "정리" is satisfied by making
the boundary legible (this document): `masc_*` = external MCP plane (filtered by
`tool_profile`), `keeper_*` = keeper in-process plane, both fronting one backend
via `capability_registry` aliases and shared dispatch. Any future collision
should reuse the shared backend + alias, not fork a second implementation.
