---
rfc: "0175"
title: "Godfile decomposition Wave D — keeper core 5-file split"
status: Draft
created: 2026-05-24
updated: 2026-05-24
author: vincent
supersedes: []
superseded_by: null
related: ["0056"]
implementation_prs: []
---

# RFC-0175 — Godfile decomposition Wave D

## §1 Context

Ratchet cap 3,350 lines. Top 5 keeper files all exceed 50% of cap:

| File | Lines | Entry function | Entry lines | % of file |
|------|-------|----------------|-------------|-----------|
| `keeper_turn_driver.ml` | 2,090 | `run_named` | 2,029 | 97% |
| `keeper_run_tools.ml` | 1,783 | `prepare_agent_setup` | 1,683 | 94% |
| `keeper_unified_turn.ml` | 1,760 | `run_keeper_cycle` | ~1,728 | 98% |
| `keeper_agent_run.ml` | 1,742 | `run_turn` | 1,658 | 95% |
| `keeper_registry.ml` | 1,589 | (multi-function) | — | — |

All four monolith files share the same anti-pattern: a single entry-point
function containing all logic as nested functions. This is a natural
consequence of OCaml closure semantics — nested functions capture the
enclosing scope — but it leads to:

1. **AI token waste**: any edit to any sub-concern loads the entire function.
2. **Merge conflict amplification**: parallel edits to different concerns
   still touch the same file/region.
3. **Testing difficulty**: nested functions cannot be unit-tested in isolation.
4. **Cognitive overload**: 1,600+ line functions exceed working memory.

Wave A–C (RFC-0056 Phase 0, sub-library extraction) addressed the
cross-module dependency graph. Wave D targets the intra-file god-function
pattern.

## §2 Decomposition strategy

### §2.1 Closure-to-record pattern

Nested functions capture variables from enclosing scope. Decomposition
requires making captured state explicit:

```ocaml
(* Before: nested function captures ~20 variables *)
let run_named config tools prompt =
  let provider = ... in
  let health_tracker = ... in
  let budget = ... in
  (* 500 lines of setup *)
  let try_runtime candidates =
    (* uses provider, health_tracker, budget directly *)
    ...
  in
  try_runtime initial_candidates

(* After: explicit state record + top-level function *)
type runtime_context = {
  provider : Provider.t;
  health_tracker : Health.tracker;
  budget : Budget.t;
  (* ... other captured fields *)
}

let try_runtime (ctx : runtime_context) candidates =
  (* all state via ctx parameter *)
  ...
```

Trade-off: introduces a record type per decomposition site, but enables
independent testing and parallel editing.

### §2.2 Priority ordering (easiest → hardest)

| Priority | File | Strategy | Risk |
|----------|------|----------|------|
| **P0** | `keeper_registry.ml` | Extract Turn State Management (468 lines) → `keeper_registry_turn_state.ml` + Event Dispatch (338 lines) → `keeper_registry_events.ml` | Low — these are already top-level functions, no closure capture |
| **P1** | `keeper_run_tools.ml` | Extract Hook Configuration (490 lines) → `keeper_hooks_builder.ml` + Tool Surface Computation (419 lines) → `keeper_tool_surface_compute.ml` | Medium — nested functions capture setup state |
| **P2** | `keeper_unified_turn.ml` | Extract Execution & Retry Loop (701 lines) → `keeper_turn_retry.ml` | Medium-High — retry_loop captures turn state |
| **P3** | `keeper_agent_run.ml` | Extract sub-functions from `run_turn` by domain | High — 95% single function |
| **P4** | `keeper_turn_driver.ml` | Extract `try_runtime` (873 lines) → `keeper_runtime_try.ml` + `cycle_loop` → `keeper_runtime_cycle.ml` | Highest — deepest nesting, most captured state |

## §3 P0: keeper_registry decomposition

`keeper_registry.ml` (1,589 lines) is the only file with multiple top-level
functions (88 bindings). Two clear extraction targets:

### §3.1 keeper_registry_turn_state.ml (~468 lines)

Extract these functions (all top-level, no closure issues):

- `update_current_turn`, `stamp_turn_progress`, `mark_turn_started`,
  `record_turn_progress`, `mark_sdk_turn_started`, `mark_turn_measurement`,
  `set_turn_decision_stage`, `set_turn_runtime_state`,
  `mark_turn_runtime_exhausted`, `mark_turn_runtime_done`,
  `mark_turn_provider_attempt_started`, `set_turn_phase`,
  `set_turn_selected_model`, `prepare_turn_retry_after_compaction`,
  `mark_turn_gate_rejected_by_name`, `mark_turn_finished`,
  `record_skip_reasons`, `touch_last_turn_ts`, `increment_turn_failures`,
  `reset_turn_failures`, `get_turn_failures`

These functions all operate on the registry entry's turn-related fields.
The extraction is mechanical — they already take the entry as parameter
or use the global `registry` ref.

### §3.2 keeper_registry_events.ml (~338 lines)

Extract event dispatch cluster:

- `execute_entry_action_observability`, `followup_event_of_entry_action`,
  `record_followup_dispatch_rejection`, `compaction_stage_after_event`,
  `dispatch_event_with_audit`, `dispatch_event`, `dispatch_event_and_log`,
  `dispatch_event_unit`, `dispatch_event_with_audit_and_log`

These form a cohesive event dispatch pipeline.

### §3.3 Result

- `keeper_registry.ml` → ~783 lines (core operations + registration + state queries)
- `keeper_registry_turn_state.ml` → ~468 lines
- `keeper_registry_events.ml` → ~338 lines

All three under 800 lines.

## §4 P1: keeper_run_tools decomposition

`keeper_run_tools.ml` (1,783 lines) → two extraction targets:

### §4.1 keeper_hooks_builder.ml (~490 lines)

Hook configuration section (lines 1178-1667 of `prepare_agent_setup`).

Nested functions capture: `hooks_acc`, `tool_bundle`, `required_tools`,
`session_ctx`. These become fields of a `hook_builder_context` record.

### §4.2 keeper_tool_surface_compute.ml (~419 lines)

Tool surface computation section (lines 625-1043).

Nested functions capture: `tool_index`, `preset_selection`, `oas_mapping`,
`search_fn`. These become fields of a `surface_compute_context` record.

### §4.3 Result

- `keeper_run_tools.ml` → ~874 lines (setup + policy + validation + memory + context)
- `keeper_hooks_builder.ml` → ~490 lines
- `keeper_tool_surface_compute.ml` → ~419 lines

## §5 P2-P4: Harder decompositions (deferred)

P2-P4 require deeper refactoring of single-function monoliths. Each needs
careful analysis of closure capture patterns. These are **not** included in
the initial implementation PR — they're roadmap items for subsequent PRs.

Estimated scope:

| Phase | Files created | Total PRs | Estimated timeline |
|-------|--------------|-----------|-------------------|
| P0 | 2 new files | 1 PR | 1 session |
| P1 | 2 new files | 1-2 PRs | 1-2 sessions |
| P2 | 1 new file | 1 PR | 1 session |
| P3 | 2-3 new files | 2-3 PRs | 2-3 sessions |
| P4 | 2-3 new files | 2-3 PRs | 2-3 sessions |

## §6 Non-goals

- **Changing the public API** — `.mli` files remain stable; new modules are
  internal implementation details.
- **Behavioral changes** — pure refactoring, no logic changes.
- **Cross-module dependency restructuring** — that's Wave A–C territory.
- **Lint enforcement of line counts** — ratchet tracking only.

## §7 Test requirements

- Existing `dune runtest` must pass unchanged.
- New modules get their own test files if they contain non-trivial logic.
- `.mli` coverage: every new module gets an explicit `.mli` that exposes
  only what `keeper_registry.ml` (or parent) needs.

## §8 Success metric

After P0+P1:
- All keeper files under 1,000 lines
- No single function over 800 lines
- `dune runtest` green
