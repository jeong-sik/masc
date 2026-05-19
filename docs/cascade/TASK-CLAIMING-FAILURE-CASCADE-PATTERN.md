# Task-346: Task Claiming Failure Cascade Pattern

## Summary

When a keeper claims a task and the assigned cascade has no callable providers (all slots full, all candidates filtered, or tier-group misconfigured), the keeper enters a **failure cascade loop**: each turn fails with `cascade_exhausted`, the supervisor restarts the fiber, and the same broken cascade is tried again. Without intervention, this burns turns silently until the auto-pause threshold is reached.

## Affected Code Paths

### 1. Error Classification
**File:** `lib/cascade/cascade_error_classify.ml`

```ocaml
type masc_internal_error =
  | Cascade_exhausted of {
      cascade_name : cascade_name;
      reason : Keeper_types.cascade_exhaustion_reason;
    }
  | No_tool_capable_provider of {
      cascade_name : cascade_name;
      configured_labels : string list;
      required_tool_names : string list;
      provider_rejections : provider_rejection list;
    }
```

The `Cascade_exhausted` variant carries:
- `cascade_name`: runtime cascade identifier (e.g. `strict_tool_candidates`, `tier.ollama_cloud_stable`)
- `reason`: exhaustion reason tag (`candidates_filtered_after_cycles`, `slot_full`, or `other_detail`)

### 2. Turn Failure Handling
**File:** `lib/keeper/keeper_unified_turn.ml` (~lines 2180–2280)

On each turn failure:
1. **Record stress** — `record_turn_failure_stress` logs consecutive failure count vs threshold
2. **Stamp failure reason** — If `is_cascade_exhausted_error` and `count > 0`, sets `last_failure_reason` to `Turn_consecutive_failures count` so operators can distinguish "stuck=cascade_exhausted" from "stuck=genuinely idle"
3. **Auto-pause guard** — When `count >= turn_fail_streak_threshold` and not already paused, triggers `cascade_auto_paused` via `sync_keeper_paused_state`
4. **Task release** — If `tool_contract_auto_paused`, releases the current task so another keeper (with a working cascade) can claim it

### 3. Recovery Path
- Any successful turn clears `last_failure_reason` via `reset_turn_failures`
- Operator must fix the cascade (add providers, free slots, or reconfigure tier-group) before resuming

## Observed Failure Signatures (Production)

| Cascade Name | Reason | Count (episodic) |
|---|---|---|
| `strict_tool_candidates` | `slot full, cascading to next provider` | 2 |
| `tier.ollama_cloud_stable` | `candidates_filtered_after_cycles` | 2 |
| `glm-coding-with-spark` | `slot full, cascading to next provider` | 1 |
| `tier-group.strict_tool_candidates` | `slot full, cascading to next provider` | 1 |

## Root Cause Categories

1. **Slot exhaustion** — All providers in the cascade are at capacity (`slot full`)
2. **Tier-group config drift** — Name says "16k" but actual `context_window` is 8192, causing candidate filtering
3. **Tool contract mismatch** — Required tools not available in any provider of the cascade
4. **Provider health degradation** — All candidates filtered after health cycles

## Mitigation Already in Code

- **Auto-pause at threshold** prevents infinite restart loops (task-074, 2026-04-26)
- **Failure reason stamping** gives operators attribution instead of generic "idle 328s"
- **Task release on tool-contract pause** allows task migration to healthy keepers

## Recommended Operator Actions

1. Check `keeper_status` dashboard for `cascade_auto_paused` keepers
2. Inspect cascade config: `cascade_name` → provider labels → actual provider capacity
3. For `slot full`: scale providers or reduce concurrency
4. For `candidates_filtered_after_cycles`: verify tier-group `context_window` matches name
5. Resume keeper after fix; successful turn resets failure count

## References

- `lib/cascade/cascade_error_classify.ml` — error type definition
- `lib/keeper/keeper_unified_turn.ml` — turn failure handling and auto-pause logic
- `lib/keeper/keeper_behavioral_regime.ml` — `turn_fail_streak_threshold` constant
- Board posts: `p-4305d235e74f483d6ee6eef148501aa8`, `p-ced5be1fce9ed76b0674d138e5f51e77`