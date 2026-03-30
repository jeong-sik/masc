# Delta-Based Context Optimization

## Overview

This document describes the delta-based context optimization system for MASC Keeper, Harness, and Auto-Research components. The goal is to reduce I/O overhead and improve efficiency by storing and loading only incremental changes (deltas) instead of full context for each checkpoint.

## Problem Statement

**Original Korean:**
> Keeper 또는 masc 안의 목표나 작업, 하네스 진행이나 오토리서치가 늘 full context 를 머금고 진행하기보단 delta 를 가지고 진행할 수 있도록 개선하는 방향을 찾아보자

**English:**
> Find a way to improve Keeper or MASC goals, tasks, harness progress, or auto-research to proceed with deltas rather than always carrying full context.

## Current State Analysis

### Full Context Accumulation Pattern

Currently, the system operates with full context accumulation:

1. **Checkpoint Storage** (`keeper_checkpoint_store.ml`):
   - Stores complete `working_context` with all messages
   - Each checkpoint file contains the entire conversation history
   - Checkpoint format: `ckpt-{timestamp}.json`
   - Retains only 3 most recent checkpoints per session

2. **Context Restoration** (`keeper_agent_run.ml`):
   - Loads latest checkpoint with full message history
   - Appends new user message to complete history
   - Passes entire history to OAS `Agent.run` as `initial_messages`
   - After turn, saves new checkpoint with all messages

3. **Token Tracking** (`keeper_working_context.ml`):
   ```ocaml
   type working_context = {
     system_prompt : string;
     messages : Agent_sdk.Types.message list;  (* Full history *)
     token_count : int;
     max_tokens : int;
     importance_scores : (int * float) list;
     oas_context : Agent_sdk.Context.t;
   }
   ```

### Context Compaction Mechanisms

The system has optional compression at 88% context threshold:

1. **Importance Scoring** (`context_compact_oas.ml`):
   - Quadratic recency decay (40%)
   - Role weighting (25%)
   - Content length heuristic (20%)
   - Tool interaction boost (15%)

2. **Compaction Strategies**:
   - `PruneToolOutputs`: Trim tool results to 500 chars
   - `MergeContiguous`: Combine adjacent messages
   - `DropLowImportance`: Remove messages with score < 0.3
   - `SummarizeOld`: Extractive summarization (no LLM call)

### Mitosis DNA System

The existing mitosis system has two-phase delta mechanics:

1. **Phase 1 (50% context)**: Extract DNA, store as `prepared_dna`
2. **Phase 2 (80% context)**: Extract delta since Phase 1, merge with DNA
3. **DNA Compression**: Head-tail preservation (60% head + 40% tail)
4. **Handoff Budget**: 20,000 tokens (~80KB max context)

## Delta-Based Solution

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Delta Checkpoint System                   │
└─────────────────────────────────────────────────────────────┘
                            │
            ┌───────────────┼───────────────┐
            │               │               │
     ┌──────▼──────┐ ┌─────▼─────┐ ┌──────▼──────┐
     │  Full Base  │ │  Delta 1  │ │  Delta 2    │
     │  Checkpoint │ │ Checkpoint│ │  Checkpoint │
     └─────────────┘ └───────────┘ └─────────────┘
     │ All messages│ │ +3 messages│ │ +2 messages│
     │ 0-10        │ │ 11-13     │ │ 14-15      │
     └─────────────┘ └───────────┘ └─────────────┘
```

### Key Components

#### 1. Delta Checkpoint Structure

```ocaml
type delta_checkpoint = {
  checkpoint_id : string;
  base_checkpoint_id : string option;  (* None = full checkpoint *)
  timestamp : float;
  generation : int;
  message_offset : int;  (* Index of first new message *)
  new_messages : Agent_sdk.Types.message list;  (* Only deltas *)
  incremental_token_count : int;
  total_message_count : int;
  total_token_count : int;
}
```

#### 2. Delta Chain Reconstruction

When loading a checkpoint:

1. Identify if it's a delta checkpoint
2. Walk backwards to find base checkpoint
3. Collect intermediate deltas
4. Reconstruct full context by applying deltas in order

```ocaml
let reconstruct_from_deltas
    ~(base : checkpoint)
    ~(deltas : delta_checkpoint list)
    : working_context option
```

#### 3. Delta Creation Logic

Decide whether to create delta or full checkpoint:

```ocaml
let should_use_delta
    ~(prev_ckpt : checkpoint option)
    ~(current_messages : message list)
    ~(delta_chain_length : int) : bool =
  match prev_ckpt with
  | None -> false  (* First checkpoint must be full *)
  | Some prev ->
    prev.message_count >= min_messages_for_delta &&
    List.length current_messages > prev.message_count &&
    delta_chain_length < max_delta_chain_length
```

### Configuration

Feature flags in `feature_flag_registry.ml`:

```ocaml
{ env_name = "MASC_KEEPER_DELTA_CHECKPOINT_ENABLED";
  description = "Enable delta-based checkpoint storage to reduce I/O overhead";
  default = false; category = "keeper";
  lifecycle = Experimental; since = "2.170.0" }

{ env_name = "MASC_KEEPER_LAZY_MESSAGE_LOADING";
  description = "Load checkpoint messages lazily instead of all at once";
  default = false; category = "keeper";
  lifecycle = Experimental; since = "2.170.0" }
```

Environment variables in `env_config_keeper.ml`:

- `MASC_KEEPER_DELTA_CHECKPOINT_ENABLED` (default: false)
- `MASC_KEEPER_LAZY_MESSAGE_LOADING` (default: false)
- `MASC_KEEPER_DELTA_MAX_CHAIN_LENGTH` (default: 5, range: [2, 20])
- `MASC_KEEPER_DELTA_MIN_MESSAGES` (default: 3, range: [1, 20])

### Implementation Files

1. **`lib/keeper/keeper_checkpoint_delta.ml`** (new):
   - Delta checkpoint types and operations
   - Delta chain reconstruction
   - Delta file I/O
   - Efficiency metrics

2. **`lib/keeper/keeper_checkpoint_delta.mli`** (new):
   - Public interface for delta checkpointing

3. **`lib/config/feature_flag_registry.ml`** (modified):
   - Added delta checkpoint feature flags

4. **`lib/config/env_config_keeper.ml`** (modified):
   - Added `DeltaCheckpoint` configuration module

## Benefits

### I/O Reduction

**Before (Full Checkpoint):**
- Checkpoint with 100 messages, each ~200 tokens
- Total: ~20,000 tokens × 4 chars/token = ~80KB per checkpoint
- 10 checkpoints = 800KB written

**After (Delta Checkpoint):**
- Base checkpoint: 80KB (first checkpoint)
- Delta 1: +3 messages = ~2.4KB
- Delta 2: +2 messages = ~1.6KB
- Delta 3: +4 messages = ~3.2KB
- Delta 4: +3 messages = ~2.4KB
- Total: 80KB + 9.6KB = 89.6KB written
- Savings: ~88.8% I/O reduction for deltas

### Load Time Reduction

**Before:**
- Load and parse 80KB JSON
- Deserialize all 100 messages

**After (with lazy loading):**
- Load base checkpoint: 80KB (cached)
- Load delta: 2.4KB
- Deserialize only new messages
- ~97% faster for incremental loads

### Storage Efficiency

With 3 retained checkpoints:

**Before:**
- 3 × 80KB = 240KB per session

**After:**
- 1 base (80KB) + 2 deltas (4KB each) = 88KB per session
- 63% storage reduction

## Delta Chain Management

### Chain Length Limits

To prevent unbounded delta chains:

1. **Max Chain Length**: 5 deltas (configurable)
2. **Forced Full Checkpoint**: After max chain length reached
3. **Periodic Consolidation**: On mitosis or handoff events

### Chain Integrity

Delta chain validation:

```ocaml
(* Verify message offset matches current message count *)
if List.length ctx.messages <> delta.message_offset then
  failwith "Delta offset mismatch"
```

### Recovery Strategy

If delta chain is broken:

1. Fall back to last full checkpoint
2. Log warning about missing deltas
3. Continue with available context
4. Next save creates new full checkpoint

## Future Optimizations

### 1. Lazy Message Loading

Load messages on-demand instead of full restoration:

```ocaml
type lazy_message =
  | Loaded of Agent_sdk.Types.message
  | Deferred of { file_path : string; offset : int }
```

### 2. Incremental Context Compaction

Track which messages were pruned to avoid re-adding:

```ocaml
type compaction_history = {
  dropped_indices : int list;
  summarized_ranges : (int * int) list;
}
```

### 3. Streaming Checkpoints

Stream checkpoint deltas as turns progress:

```ocaml
let stream_delta_checkpoint
    ~(session_dir : string)
    ~(message : Agent_sdk.Types.message) : unit
```

### 4. Context Window Prediction

Pre-compute which messages will be dropped at next compaction:

```ocaml
let predict_next_compaction
    ~(ctx : working_context)
    ~(threshold : float) : int list (* indices to drop *)
```

## Integration Path

### Phase 1: Core Infrastructure (Current)

- [x] Delta checkpoint types and serialization
- [x] Delta chain reconstruction logic
- [x] Feature flags and configuration
- [ ] Integration into `keeper_exec_context`
- [ ] Unit tests for delta operations

### Phase 2: Keeper Integration

- [ ] Modify `save_session_checkpoint` to use deltas
- [ ] Modify `load_latest_checkpoint` to reconstruct from deltas
- [ ] Add delta metrics to keeper dashboard
- [ ] Monitor delta efficiency in production

### Phase 3: Extended Coverage

- [ ] Apply delta pattern to MDAL state tracking
- [ ] Apply delta pattern to Harness progress checkpoints
- [ ] Apply delta pattern to Auto-Research cycle state
- [ ] Unified delta storage API

### Phase 4: Advanced Optimizations

- [ ] Lazy message loading
- [ ] Incremental compaction with delta awareness
- [ ] Streaming checkpoints
- [ ] Context window prediction

## Monitoring

### Delta Efficiency Metrics

```ocaml
let compute_delta_efficiency (delta : delta_checkpoint) : float =
  if delta.total_message_count = 0 then 0.0
  else
    let new_msg_count = List.length delta.new_messages in
    float_of_int new_msg_count /. float_of_int delta.total_message_count
```

### Chain Statistics

```ocaml
let compute_chain_stats (chain : delta_chain) : string =
  sprintf "Delta chain: base=%s, deltas=%d, new_msgs=%d, avg_efficiency=%.2f%%"
    chain.base.checkpoint_id
    (List.length chain.deltas)
    total_new_messages
    (avg_efficiency *. 100.0)
```

## Testing Strategy

### Unit Tests

1. Delta checkpoint creation and serialization
2. Delta chain reconstruction with various chain lengths
3. Edge cases: empty deltas, missing base, broken chain
4. Efficiency metrics computation

### Integration Tests

1. Full keeper session with delta checkpoints enabled
2. Mitosis handoff with delta context transfer
3. Context compaction with delta awareness
4. Recovery from delta chain corruption

### Performance Tests

1. Benchmark I/O reduction with varying message counts
2. Benchmark load time reduction with lazy loading
3. Memory profiling with delta vs full checkpoints
4. Storage usage comparison over time

## References

- `lib/keeper/keeper_working_context.ml` - Working context types
- `lib/keeper/keeper_checkpoint_store.ml` - Checkpoint file I/O
- `lib/keeper/keeper_exec_context.ml` - Context lifecycle
- `lib/mitosis_dna.ml` - DNA compression and merge logic
- `lib/context_compact_oas.ml` - Importance scoring
- `docs/COMMON-PITFALLS.md` - Refactor traps and gotchas

## Conclusion

The delta-based context optimization provides significant I/O and storage benefits for long-running Keeper sessions while maintaining full context reconstruction capability. The phased rollout approach with feature flags ensures safe experimentation and gradual adoption across the MASC platform.
