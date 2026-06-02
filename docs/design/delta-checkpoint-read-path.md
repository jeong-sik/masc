---
status: reference
last_verified: 2026-04-17
code_refs:
  - lib/keeper/keeper_checkpoint_store.ml
  - lib/keeper/keeper_fs.ml
  - lib/keeper/
---

# Delta Checkpoint Read Path (Stage 3)

Design decisions for the delta checkpoint restore path.
Stage 3 implementation is deferred to a future PR, after shadow validation
(Stage 1-2) confirms a stable match rate.

## Decisions

| Item | Decision | Rationale |
|------|----------|-----------|
| Sidecar file name | `{session_id}.delta.json` | Co-located with full checkpoint `{session_id}.json` |
| Retention policy | Same as full checkpoint (co-located) | Sidecar follows full checkpoint lifecycle; pruning deletes both |
| Base selection | Immediately preceding full checkpoint | Avoids ambiguity; delta always references the last full save |
| Load-switch | Check for `.delta.json` alongside `.json` | `load_oas` tries delta path first, falls back to full restore |
| Delta chain depth | Max 10 deltas before full checkpoint re-baseline | Bounds cumulative drift risk and restore latency |
| Concurrent read/write | Atomic write (tmp + rename), same as full checkpoint | `Keeper_fs.save_atomic` already provides POSIX atomicity guarantees |

## Load Path (future)

```
load_oas(session_dir, session_id)
  1. path_full  = session_dir / session_id ^ ".json"
  2. path_delta = session_dir / session_id ^ ".delta.json"
  3. if path_delta exists AND path_full exists:
       base  = Checkpoint.of_string(read path_full)
       delta = Checkpoint.delta_of_json(read path_delta)
       result = Checkpoint.restore_with_delta_fallback ~base ~delta ~full_checkpoint:base ()
       return result.checkpoint
  4. else:
       return full restore from path_full
```

## Constraints

- Delta sidecar is only written when `OAS_DELTA_CHECKPOINT=shadow_write`.
- Stage 3 read path will be gated behind `OAS_DELTA_CHECKPOINT=restore`.
- Full checkpoint is always written alongside any delta sidecar, so
  fallback to full restore is always available.
- The 10-delta chain depth limit is enforced by the caller: after 10
  consecutive delta writes without a full re-baseline, force a full
  checkpoint save and reset the chain counter.

## Status

Stage 3 implementation: future PR, after shadow validation.
