# RFC-0064: Two-Surface Tool Alias — Replace 3-Tier Classification

| Field        | Value                                        |
|-------------|----------------------------------------------|
| Status      | Draft                                        |
| Author      | jeong-sik                                    |
| Date        | 2026-05-11                                   |
| Supersedes  | None                                         |
| Conflicts   | RFC-0062 (Phase 4 handler migration)         |
| Affects     | `lib/keeper/keeper_tool_alias.*`, `lib/keeper/keeper_run_tools.ml`, `lib/keeper/keeper_tool_disclosure.ml`, `lib/keeper/keeper_tools_oas.ml`, `lib/keeper/keeper_agent_run.ml`, `lib/keeper_tool_call_log.ml` |

## 1. Problem

`Keeper_tool_alias` implements a 3-tier classification of tool names:

1. **`aliases`** (8 entries): Public→internal mapping (`"Bash"→"keeper_bash"`, etc.)
2. **`oas_dual_register`** (7 entries): `aliases` minus `"Shell"` — an N-of-M patch
3. **`hallucinated_builtins`** (4 hardcoded strings): `"Agent"`, `"Skill"`, `"TodoWrite"`, `"NotebookEdit"`

This classification violates two of the **Workaround Rejection Bar** criteria from `software-development.md`:

- **#2 String/substring classifier**: `hallucinated_builtins` is a hardcoded string list that the compiler cannot enforce. Adding a new hallucinated tool requires editing the list, with no exhaustiveness check.
- **#3 N-of-M patch**: `oas_dual_register` is `aliases` minus one entry (`"Shell"`). The compiler cannot verify that removing `"Shell"` is the only intentional exclusion.

Additionally, the current architecture forces LLMs to call `keeper_bash` instead of `Bash`. The user insight (2026-05-11): *"우리가 제공한 도구가 있고 걔네 도구가 있고 알아서 선택하게 하면 됨. 사용만 하도록 어거지로 번역하지 마."* — Two surfaces exist naturally: LLM native tools and MCP tools. Internal `keeper_*` names should be implementation details only.

### Symptom Evidence

- `oas_dual_register_aliases` has drifted from `aliases` by subtraction. Future changes to one must be manually reflected in the other.
- `hallucinated_builtins` encodes a policy decision ("flag with teaching message rather than nuking") as a string list — this should be a routing outcome, not an upfront classification.
- `canonicalize_observed` and `expand_universe` exist solely to bridge the classification gap. They add complexity without structural benefit.

## 2. Proposed Change

Replace the 3-tier classification with a **two-surface model**:

| Surface          | Examples                                          | Routing                                |
|------------------|---------------------------------------------------|----------------------------------------|
| LLM native tools | `Bash`, `Read`, `Edit`, `Write`, `Grep`, `WebSearch`, `WebFetch` | `translate_input` maps field names → handler |
| MCP tools        | `masc_board_post`, `masc_task_add`, ...           | Direct dispatch, no aliasing needed    |

Internal `keeper_*` names become **implementation details** of the routing layer, not a public surface.

### 2.1 What Stays

| Function                | Reason                                                                 |
|------------------------|------------------------------------------------------------------------|
| `translate_input`      | Legitimate field mapping (`command`→`cmd`, `file_path`→`path`). This is the only function that reshapes data, not classifies names. |
| `public_input_schema`  | LLM-facing JSON schemas for the 7 native tools. The LLM expects Anthropic Code field names, not our internal names. |
| Routing table         | The mapping from public name to internal handler is a simple lookup — no classification tier. |

### 2.2 What Is Removed

| Function                        | Replacement                                                                 |
|---------------------------------|-----------------------------------------------------------------------------|
| `aliases` (8-entry list)        | Single flat routing table: `public_name → (internal_name, translate_fn, schema)` |
| `oas_dual_register_aliases`     | **Removed**. All entries in the routing table are 1st-class OAS names.       |
| `hallucinated_builtins`         | **Removed**. A tool call for a tool we don't handle is a routing miss — captured by result-based telemetry. |
| `is_hallucinated_builtin`       | **Removed**. Same — routing miss, not a classification category.             |
| `canonicalize_observed`         | **Removed**. Disclosure checks use the routing table directly.              |
| `canonicalize_observed_with_telemetry` | **Replaced** by result-based telemetry: `masc_keeper_tool_call_total{tool="Bash", routed_to="keeper_bash", result="ok\|miss"}` |
| `expand_universe`               | **Removed**. Public names are added to the universe directly, not via expansion. |
| `to_internal`                   | **Replaced** by routing table lookup. Caller sites use `route(public_name)` which returns handler info. |
| `to_public`                     | **Removed**. Internal names are not surfaced publicly. The LLM sees its own tool names. |

### 2.3 New Structure

```ocaml
(* keeper_tool_alias.ml — simplified *)

type route = {
  internal_name : string;        (* e.g. "keeper_bash" — implementation detail *)
  translate : Yojson.Safe.t -> Yojson.Safe.t;  (* field mapping, identity if none *)
  public_schema : Yojson.Safe.t option;         (* LLM-facing schema, None if passthrough *)
}

val route : string -> route option
(* Returns routing info for a known public tool name.
   None = routing miss (tool not in our surface). *)

val translate_input : public:string -> Yojson.Safe.t -> Yojson.Safe.t
(* Keep existing signature for backward compat during migration. *)
```

### 2.4 Telemetry Change

Before (classification-based):
```
masc_keeper_tool_alias_canonicalizations_total{alias="Bash",internal="keeper_bash"}
```

After (result-based):
```
masc_keeper_tool_call_total{tool="Bash",routed_to="keeper_bash",result="ok"}
masc_keeper_tool_call_total{tool="Agent",routed_to="none",result="miss"}
```

A routing miss increments the counter with `routed_to="none"`. No upfront classification — the outcome determines the label.

### 2.5 Caller Site Migration

| File | Current Usage | Migration |
|------|---------------|-----------|
| `keeper_run_tools.ml:66,449,794` | `expand_universe` | Add public alias names directly to the allowlist at construction time |
| `keeper_tool_disclosure.ml:80,198` | `canonicalize_observed` | Use `route(name) <> None` to check if a name is known; no canonicalization needed |
| `keeper_tools_oas.ml:1049,1076,1088` | `public_input_schema`, `translate_input`, `oas_dual_register_aliases` | `route(public)` replaces the dual-register iteration; `translate_input` and `public_input_schema` come from the route record |
| `keeper_agent_run.ml:682` | `canonicalize_observed_with_telemetry` | Direct routing miss detection + result-based telemetry counter |
| `keeper_tool_call_log.ml:85` | `to_internal` | `route(name)` returns the internal name for logging |

## 3. Scope

### In Scope (this RFC)

1. Simplify `keeper_tool_alias.ml` to the flat routing table model
2. Remove `oas_dual_register_aliases`, `hallucinated_builtins`, `is_hallucinated_builtin`, `canonicalize_observed`, `canonicalize_observed_with_telemetry`, `expand_universe`, `to_public`
3. Replace `to_internal` with `route` returning a structured record
4. Migrate 6 production caller sites and 3 test files
5. Add result-based telemetry counter for routing outcomes

### Out of Scope

- Changing the `keeper_tools_oas.ml` dual-registration mechanism itself (separate concern)
- Renaming `keeper_*` internal names (they remain as implementation details)
- Dashboard/CLI changes (they already use internal names)

## 4. Implementation Plan

### Phase 1: Routing Table (breaking change, single PR)

1. Create `route` type and flat routing table in `keeper_tool_alias.ml`
2. Implement `route : string -> route option` from the existing `aliases` data
3. Migrate all 6 production caller sites
4. Update `.mli` to expose only `route`, `translate_input`, `public_input_schema`
5. Update 3 test files to test `route` instead of removed functions
6. Add `masc_keeper_tool_call_total` Prometheus counter
7. Remove all removed functions and their tests

### Phase 2: OAS Dual Registration Cleanup (follow-up, post Phase 1)

1. Simplify `keeper_tools_oas.ml` — iterate routing table entries instead of `oas_dual_register_aliases`
2. Remove the `?translate_input` parameter from the OAS handler — use `route.translate` directly

## 5. Risks

| Risk | Mitigation |
|------|------------|
| Routing table missing an entry that `aliases` had | The routing table is mechanically derived from the current `aliases` list — zero migration risk for known entries |
| `hallucinated_builtins` removal changes behavior for `Agent`, `Skill`, `TodoWrite`, `NotebookEdit` | These were only used for a "teaching message" — the routing miss counter provides equivalent observability |
| `expand_universe` removal changes allowlist construction | Callers add public names directly — simpler and more transparent |
| `to_public` removal means internal names never surface to LLM | Correct — internal names are implementation details. The LLM sees its own tool names on both surfaces |

## 6. Success Criteria

- [ ] `oas_dual_register_aliases` function removed
- [ ] `hallucinated_builtins` list removed
- [ ] `canonicalize_observed` / `canonicalize_observed_with_telemetry` removed
- [ ] `expand_universe` removed
- [ ] `to_public` removed
- [ ] `to_internal` replaced by `route`
- [ ] `translate_input` preserved with identical behavior
- [ ] All 3 test files updated and passing
- [ ] Result-based telemetry counter added (`masc_keeper_tool_call_total`)
- [ ] No `hallucinated_builtins` or `oas_dual_register` string literals remain in codebase

## 7. References

- Workaround Rejection Bar (CLAUDE.md §software-development.md): criteria #2 (string classifier) and #3 (N-of-M patch)
- User insight (2026-05-11): *"우리가 제공한 도구가 있고 걔네 도구가 있고 알아서 선택하게 하면 됨. 사용만 하도록 어거지로 번역하지 마."*
- RFC-0062: Phase 4 handler migration (concurrent, orthogonal)