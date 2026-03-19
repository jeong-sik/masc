# Execution Scope and Worker Autonomy Analysis

**Date**: 2026-03-17  
**Context**: READ-ONLY exploration of MASC MCP codebase (`lib/` modules)  
**Scope**: Worker completion handling, execution scope patterns, spawned agent capabilities, tool allowlisting

---

## Executive Summary

The MASC MCP codebase defines a **type-level execution control system** via the `execution_scope` variant type in `team_session_types.ml`. Currently implemented:
- `Observe_only`: Workers can read state but not execute code changes
- `Limited_code_change`: Workers can execute code with constraints

The architecture **separates concerns** into:
1. **Type-level declarations** (`execution_scope` in `planned_worker` specs)
2. **Tool allowlisting** (`spawned_agent_public_tool_names` in `agent_tool_surfaces.ml`)
3. **Worker completion tracking** (session state delta in `team_session_types.ml`)
4. **LLM cascade orchestration** (`lodge_cascade.ml` for model fallbacks)

**Key finding**: Tool availability is currently **hardcoded via allowlist**, not dynamically enforced based on `execution_scope` values. This creates a **gap**: declaring `Observe_only` in specs does not prevent tool invocation at runtime.

---

## Part 1: Execution Scope Type System

### Current Definition (team_session_types.ml, lines 13-15)

```ocaml
type execution_scope =
  | Observe_only
  | Limited_code_change
```

**Purpose**: Declaratively annotate the **intended authority level** for a spawned worker in a team session.

**Where declared**:
- In `planned_worker` record (line 125):
  ```ocaml
  type planned_worker = {
    (* ... other fields ... *)
    execution_scope: execution_scope option;  (* Line 125 *)
    (* ... *)
  }
  ```

**Where serialized**:
- `execution_scope_to_yojson` (team_session_types.ml): Maps variant to JSON
- `execution_scope_of_yojson` (team_session_types.ml): Parses JSON back to variant
- Used in `planned_worker_to_yojson` / `of_yojson` for persistence

### Current Variants Explained

| Variant | Semantics | Intended Use |
|---------|-----------|--------------|
| `Observe_only` | Worker observes state, cannot modify code/filesystem | MDAL auditable mode, coordinator review passes |
| `Limited_code_change` | Worker can execute code changes within boundaries | Standard team session execution |

### Semantics Gap

**Current behavior**: `execution_scope` is stored in session metadata but **not enforced** at tool invocation time.

**Evidence**:
- Tool allowlist (`agent_tool_surfaces.ml`) is static and identical for all workers
- `handle_step` (tool_team_session_step.ml) appends spawn events but does not gate tools based on scope
- No runtime checks in MCP tool dispatch (would be in masc_mcp.ml tool handlers)

---

## Part 2: Tool Allowlisting Architecture

### Primary Allowlist: spawned_agent_public_tool_names

**Location**: `lib/agent_tool_surfaces.ml`, lines 35-101

**Structure**: Hardcoded list of 60+ tool names available to spawned agents.

**Key features**:
- Uses `Unique_preserve_order` for deduplication while preserving order
- Includes both **read** tools (inspect, status) and **write** tools (post, step, operator_judge)
- No parameterization by `execution_scope`

### Restricted Allowlists

1. **llama_worker_tool_names** (lines 106-112): Minimal set for local llama workers
   - Purpose: Reduce latency for heartbeat workers, prevent tool misuse

2. **mdal_auditable_tool_names**: Code operation tools for MDAL auditable execution

3. **lodge_worker_base_tool_names**: Board/profile tools with configurable `allow_post` flag

### Gap: No Scope-Based Tool Gating

**Problem**: All spawned agents receive the same tool allowlist, regardless of `execution_scope` value.

---

## Part 3: Worker Completion Handling

### Session State Tracking

**Location**: `team_session_types.ml`

**Relevant fields**:
```ocaml
type session_state = {
  (* ... *)
  done_counts: (string * int) list;          (* Baseline *)
  final_done_delta_total: int option;         (* Cumulative delta *)
  final_done_delta_by_agent: (string * int) list option;  (* Per-agent *)
  (* ... *)
}
```

**Completion Detection Pattern**:
- Session appends step events with worker run ID
- Baseline done counts compared to final state to compute delta
- No explicit "worker_done" callback visible; likely in masc_mcp.ml tool handlers

### Gap: No LLM-Based Completion Decision

**Current mechanism**: Completion appears to be **event-based** (worker reports done, or session ends by time/turn limit)

---

## Part 4: LLM Cascade and Model Orchestration

### Cascade Architecture

**Location**: `lib/lodge_cascade.ml`

**Type signature**:
```ocaml
let call ~cascade_name ~prompt
    ?(config_path = "") ?(temperature = 0.3) ?(timeout_sec = 30)
    ?(max_tokens = 500) ?(accept = fun _ -> true) ?system () :
    (cascade_result, string) result
```

**Pattern**: `llama_glm` (local llama first, GLM fallback)

### Use Case in Team Sessions

- Used by **lodge subsystems** (lodge_direct, lodge_context_rewrite, lodge_comment, lodge_agent_match)
- Used by **judicial subsystems** (governance_judge, operator_judge)
- Enables **fallback resilience**: if local llama unavailable, cascade to cloud GLM

---

## Part 5: Recommendations for "Autonomous" Variant Implementation

### Option A: Extend execution_scope (Type-Level) [RECOMMENDED]

**Change**:
```ocaml
type execution_scope =
  | Observe_only                    (* Current: read-only *)
  | Limited_code_change             (* Current: bounded writes *)
  | Autonomous                      (* New: write + decision-making *)
  | Fleet_coordinator               (* New: team orchestration authority *)
```

**Enforcement points**:
1. In `tool_team_session_step.ml` `handle_step`: Check scope before appending tool allowlist
2. In MCP tool handlers (masc_mcp.ml): Gate tools by querying session state for current worker's scope
3. In prompt composing: Annotate prompt with scope constraints

**Advantages**:
- Type-safe: scope is checked at compile time
- Explicit: clear intent in session specs
- Composable: can stack with other constraints (worker_class, risk_level)

---

## Part 6: Architecture Changes Required

### 1. Extend execution_scope Type

**File**: `lib/team_session_types.ml`

```ocaml
type execution_scope =
  | Observe_only
  | Limited_code_change
  | Autonomous
  | Fleet_coordinator
```

**Serialization**: Update `execution_scope_to_yojson` and `of_yojson` to handle new variants.

### 2. Create Scope-Based Tool Allowlists

**File**: `lib/agent_tool_surfaces.ml`

Add function:
```ocaml
let tools_for_scope (scope : execution_scope option) : string list =
  match scope with
  | None -> spawned_agent_public_tool_names  (* Default: all tools *)
  | Some Observe_only ->
      [ (* Only read tools *)
        "masc_team_session_status";
        "masc_board_inspect";
        "masc_search_*";
        (* ... *)
      ]
  | Some Limited_code_change ->
      spawned_agent_public_tool_names  (* Current behavior *)
  | Some Autonomous ->
      spawned_agent_public_tool_names  (* All tools + decision authority *)
  | Some Fleet_coordinator ->
      [ (* Operator + judgment tools *)
        "masc_operator_judge";
        "masc_operator_cascade";
        (* ... *)
      ]
```

### 3. Dynamic Tool Allowlist in Spawn Events

**File**: `lib/tool_team_session_step.ml`, `handle_step` function

Compute allowed tools based on spec.execution_scope and include in spawn event metadata.

### 4. Runtime Tool Validation

**File**: `lib/masc_mcp.ml` (implied)

In tool dispatch handlers, validate tool invocation against worker's allowed tools list.

### 5. Worker Completion on Autonomous Decision

Add logic to detect when autonomous worker reports completion via signal (e.g., `[WORKER_COMPLETE]` in response).

---

## Part 7: Testing Strategy

### Unit Tests

```ocaml
(* Test scope-based tool filtering *)
let test_observe_only_cannot_post () =
  let scope = Some Observe_only in
  let tools = Agent_tool_surfaces.tools_for_scope scope in
  assert_false (List.mem "masc_board_post" tools)

let test_autonomous_has_all_tools () =
  let scope = Some Autonomous in
  let tools = Agent_tool_surfaces.tools_for_scope scope in
  assert_true (List.mem "masc_board_post" tools)
```

---

## Part 8: Deployment Path

### Phase 1: Type Safety (No Behavior Change)
1. Add `Autonomous`, `Fleet_coordinator` variants to `execution_scope`
2. Update serialization functions
3. Deploy: No runtime change yet

### Phase 2: Tool Filtering (Enforcement)
1. Implement `tools_for_scope` in agent_tool_surfaces.ml
2. Update tool_team_session_step.ml to pass scope to spawn events
3. Add runtime validation in tool dispatch
4. Deploy: Observe_only now truly prevents writes

### Phase 3: Autonomous Completion (Decision Logic)
1. Add completion signal detection in handle_step
2. Integrate with session done_counts tracking
3. Update prompts to document completion signal
4. Deploy: Autonomous workers can self-terminate

---

## Part 9: Summary of Findings

### Current Architecture Strengths
- ✅ Type-level declaration of intent (`execution_scope`)
- ✅ Flexible tool allowlist system (reusable for different agent classes)
- ✅ Session-level tracking of done counts and deltas
- ✅ LLM cascade with fallbacks for resilience
- ✅ Extensive metadata in spawn events

### Gaps Identified
- ❌ `execution_scope` declared but not enforced at tool invocation time
- ❌ Tool allowlist is static (not filtered by scope)
- ❌ No logic for autonomous worker completion decisions
- ❌ No explicit "fleet_leader" or "coordinator" role prompt patterns

### Recommended Next Steps
1. **Extend execution_scope** with `Autonomous` and `Fleet_coordinator` variants
2. **Implement scope-based tool filtering** in agent_tool_surfaces.ml and dispatch
3. **Add completion signal detection** for autonomous workers
4. **Create coordinator prompt templates** with explicit authority annotations
5. **Add comprehensive tests** for scope enforcement and completion logic

---

**Document Version**: 1.0  
**Last Updated**: 2026-03-17  
**Status**: Analysis complete, implementation path defined
