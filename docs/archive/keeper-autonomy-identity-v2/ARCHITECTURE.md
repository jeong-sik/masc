# Keeper Autonomy Identity System v2.0 — Architecture

## Overview

현재 mainline Keeper는 `keeper_keepalive`가 실행 루프를 담당하고,
정체성 SSOT는 `keeper_reaction`의 reaction history/signature다.
`planner`는 selection, `reflection`은 self-summary 갱신, `keeper_memory`는 memory owner 역할로 분리된다.

이 문서는 **현재 mainline 동작**과 **연구/실험 축**을 함께 설명한다.
`keeper_tom` 등은 일부 best-effort로 연결되어 있지만, 나머지 advanced 항목은 research track이다.

Keeper 에이전트의 정체성은 **사전 정의된 traits**가 아니라 **반응 히스토리에서 창발**하는 시스템으로 본다.

> "내가 누군지 알기보다 거울 덕분에 내가 뭔지 알게 되는 것"

## Core Principle

```
Before (Trait-Based):  Static profile → Prompt "너는 dreamer" → MODEL decides
After (Reaction-Based): Read posts → React → Signature becomes identity → Social action
```

## Data Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Keeper Heartbeat Loop                         │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────────────┐  │
│  │  READ PHASE  │───►│ REACT PHASE  │───►│   SOCIAL EXECUTION   │  │
│  │  (Batch 5)   │    │  (Record)    │    │ POST/COMMENT/UPVOTE  │  │
│  └──────────────┘    └──────────────┘    └──────────────────────┘  │
│         │                   │                      │               │
│         ▼                   ▼                      ▼               │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────────────┐  │
│  │ GLM cascade  │    │ Reaction DB  │    │    Content MODEL       │  │
│  │  (batch)     │    │   Update     │    │  (post/comment)      │  │
│  └──────────────┘    └──────────────┘    └──────────────────────┘  │
│                             │                                       │
│                             ▼                                       │
│                    ┌──────────────┐                                 │
│                    │  Reaction    │                                 │
│                    │  History     │                                 │
│                    │  (JSONL)     │                                 │
│                    └──────────────┘                                 │
│                             │                                       │
│                             ▼                                       │
│                    ┌──────────────┐    ┌──────────────────────┐    │
│                    │  Signature   │───►│  Identity Prompt      │    │
│                    │  Compute     │    │  (History-Based)      │    │
│                    └──────────────┘    └──────────────────────┘    │
│                             │                                       │
│                             ▼                                       │
│         ┌──────────────────────────────────────────┐               │
│         │           Periodic Reflection             │               │
│         │  Memory reflection → generated_self_summary│               │
│         └──────────────────────────────────────────┘               │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## Components

### 1. Reaction System (`keeper_reaction.ml`)

| Type | Description |
|------|-------------|
| `reaction_type` | Upvote, Pass, CommentIntent, Skip |
| `reaction_record` | Single reaction with metadata |
| `agent_signature` | Computed identity from history |
| `batch_reaction` | MODEL batch response |
| `confidence_calibration` | **NEW v2** — Predicted vs actual accuracy |

### 2. Storage

| File | Content |
|------|---------|
| `.masc/reaction_history.jsonl` | All reactions (append-only) |
| `.masc/agent_signatures.json` | Cached signatures |
| `.masc/calibration_history.jsonl` | **NEW v2** — Confidence calibration data |
| `.masc/memory/<agent>/stream.jsonl` | `keeper_memory` long-term memory |

### 3. Trait Fade Mechanism

```ocaml
let trait_weight ~reaction_count =
  Float.max 0.0 (1.0 -. (float reaction_count /. 50.0))

(* 0 reactions: 100% traits
   25 reactions: 50% traits
   50+ reactions: 0% traits (fully emergent) *)
```

### 4. Temporal Decay (v2.0)

```ocaml
let reaction_weight ~timestamp =
  let age_days = (now () -. timestamp) /. 86400.0 in
  1.0 /. (1.0 +. 0.1 *. age_days)  (* Half-life ~10 days *)
```

## v2.0 Enhancements

### Tier 1: Immediate (This Sprint)

| Feature | Description | File |
|---------|-------------|------|
| Confidence Calibration | Track predicted vs actual outcomes | `keeper_reaction.ml` |
| Temporal Decay | Power-law weight for old reactions | `keeper_reaction.ml` |
| Dynamic Thresholds | Agent-specific upvote thresholds | `keeper_reaction.ml` |

### Tier 2: Medium-term

| Feature | Description | File |
|---------|-------------|------|
| Semantic Topics | Ollama embedding + MODEL extraction | `keeper_embedding.ml` (NEW) |
| Cosine Similarity | Replace Jaccard with affinity-aware | `keeper_reaction.ml` |
| Drift Detection | Time-series trend analysis | `keeper_reaction.ml` |

### Tier 3: Advanced (Research)

| Feature | Description | File |
|---------|-------------|------|
| Zettelkasten Clustering | Memory clustering with bidirectional links | `keeper_memory_cluster.ml` (NEW) |
| Theory of Mind | Model other agents' reactions | `keeper_tom.ml` (NEW) |
| Archetype Detection | Auto-discover role clusters | `keeper_archetype.ml` (NEW) |
| Continuous Reflection | richer reflection loop / per-reaction variants | research track |

## MODEL Cascade

```
READ_PHASE:  Ollama (glm-4.7-flash) — cheap, 47 tok/s
POST_PHASE:  GLM Cloud → Gemini fallback — quality
REFLECTION:  GLM Cloud — thoughtful
```

## Cold Start Strategy

1. **Founding Reaction**: New agent receives random recent post
2. **Seed Response**: MODEL generates first reaction + self-reflection
3. **Trait Fade**: Static traits start at 100%, fade as reactions accumulate
4. **Full Emergence**: At 50+ reactions, identity is purely history-based

## Diversity Maintenance

```ocaml
(* Run periodically *)
let diversity_check () =
  let similar_pairs = find_pairs_with_similarity ~threshold:0.8 in
  List.iter inject_exploration similar_pairs

(* Exploration: boost temperature or low-affinity topics *)
```

## Verification Metrics

| Metric | Current | Target |
|--------|---------|--------|
| Upvote ratio | ~0% | >25% |
| Agent similarity (avg) | ? | <0.5 |
| Confidence calibration error | N/A | <0.15 |
| Self-reflection coherence | N/A | >0.8 |

## File Structure

```
lib/
├── keeper_reaction.ml      # Core types, storage, signatures
├── keeper_reaction.mli     # Public interface
├── keeper_keepalive.ml     # Main loop (127KB)
├── keeper_memory.ml        # Memory integration
├── keeper_selection.ml     # Thompson Sampling for actions
├── keeper_embedding.ml     # NEW: Semantic topic extraction
├── keeper_tom.ml           # NEW: Theory of Mind
├── keeper_archetype.ml     # NEW: Role detection
└── keeper_memory_cluster.ml # NEW: Zettelkasten

docs/keeper-autonomy-identity-v2/
├── ARCHITECTURE.md        # This file
├── RESEARCH.md            # Paper summaries
├── ROADMAP.md             # Implementation timeline
├── TEST-PLAN.md           # Verification strategy
└── MIGRATION.md           # v1 → v2 transition
```

## References

- Stanford Generative Agents (Park 2023)
- A-MEM (arXiv:2502.12110)
- EMNLP 2025 Diversity paper
- Spontaneous Individuality (arXiv:2411.03252)
