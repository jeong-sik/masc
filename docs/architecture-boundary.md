---
status: reference
last_verified: 2026-04-17
code_refs:
  - lib/oas.ml
  - lib/oas_worker.ml
  - lib/verifier_oas.ml
---

# MASC-OAS Architecture Boundary

This document defines the boundary between MASC (coordination layer) and OAS (agent execution layer).

## Principle

MASC does not know about models, vendors, or token counts.
OAS does not know about rooms, tasks, or broadcast coordination.

## Module Classification

### MASC Core (Agent_sdk import forbidden)

Modules that handle coordination, task management, broadcasting, and configuration.
These must never import `Agent_sdk` directly.

| Area | Modules |
|---|---|
| Coordination | `room_state`, `room_lifecycle`, `room_init`, `room_gc`, `room_query` |
| Tasks | `room_task`, `room_task_schedule` |
| Communication | `room_portal`, `mention`, `room_vote` |
| Board | `board_dispatch`, `board` |
| Configuration | `room_utils_backend_setup`, `room_utils_paths_backend` |
| Tool catalog | `tool_catalog`, `tool_catalog_surfaces`, `tool_catalog_tiers` (deprecated) |
| Verification (core) | `verifier_core` |
| Team context (core) | `team_context` (after OAS bridge extraction) |

### OAS-Native Subsystem (Agent_sdk allowed)

Modules where Agent_sdk usage is the core purpose. These are not MASC violations.

| Area | Modules |
|---|---|
| Keeper | `keeper_agent_run`, `keeper_exec_context`, `keeper_exec_persona`, all `keeper_*.ml` |
| Runtime | `worker_oas`, `oas_worker`, `oas_worker_exec`, `worker_run_once` |
| Evaluation | `eval_calibration`, `eval_oas_probe` |
| Memory | `memory_oas_bridge` |

### Bridge Files (connection points)

Files that explicitly bridge MASC and OAS. Named with `_oas` or `_oas_adapter` suffix.

| File | Purpose |
|---|---|
| `verifier_oas.ml` | Verification verdict to OAS Hooks/Guardrails |
| `context_compact_oas.ml` | Context compaction via OAS Context_reducer |
| `keeper_hooks_oas.ml` | Keeper lifecycle hooks to OAS hooks |

## Rules

1. **New Agent_sdk imports in MASC core files require a bridge file.**
   Do not add `Agent_sdk.X` to a core module. Create or extend a `*_oas_adapter.ml` file instead.

2. **MASC core must not reference model names, vendor names, temperature, or token counts.**
   These are OAS concerns. If MASC needs a capacity signal, use abstract ratios (e.g., context_ratio: float) not raw token counts.

3. **OAS-native modules may use Agent_sdk freely.**
   Keeper, runtime, eval modules are inherently OAS consumers. No renaming or adapter needed.

4. **Bridge files must be narrowly scoped.**
   Each bridge file handles one specific translation. Do not combine multiple bridge concerns in one file.

## Verification

Check boundary compliance:
```
# Should return only *_oas*.ml and keeper/runtime/eval files
grep -rn "Agent_sdk" lib/ --include="*.ml" | grep -v "_oas\|keeper_\|worker_\|oas_worker\|eval_\|memory_oas"
```

Any match in the output is a potential boundary violation to investigate.
