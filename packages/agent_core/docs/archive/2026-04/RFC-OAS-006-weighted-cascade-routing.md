# RFC-OAS-006: Weighted Cascade Routing

> **ARCHIVED 2026-05-04.** This RFC was written when `cascade_config.ml` and
> `cascade_executor.ml` were OAS-owned modules. Both modules were deleted in OAS
> 0.144.0 as part of the MASC migration (cascade FSM and group orchestration are
> now MASC-owned). The multi-provider failover loop described here is now driven
> by downstream consumers (MASC's `try_cascade`); OAS only provides
> `Complete.complete_with_retry` for single-provider calls. This document is
> kept verbatim for historical context; do not implement it in OAS.

**Status**: Draft — Archived (superseded by MASC migration)
**Author**: jeong-sik
**Date**: 2026-04-15
**Scope**: `lib/llm_provider/cascade_config.ml`, `cascade_executor.ml` — both deleted in 0.144.0

## Problem

OAS cascade executes providers in fixed sequential order. The first provider
always receives 100% of initial traffic. This causes:

1. **Single-point bottleneck**: GLM rate limits → all traffic hits one provider
   until it fails, then cascades. No distribution.
2. **No cost/latency optimization**: Cannot prefer cheaper or faster providers
   by ratio.
3. **No health-aware routing**: A provider with 50% error rate still receives
   100% of first attempts until it fails each time.

## Industry Survey

| Solution | Selection | Health | Fallback |
|----------|-----------|--------|----------|
| LiteLLM | weighted random (`simple-shuffle`) | proactive + cooldown | 3-type (general/context/policy) |
| OpenRouter | price x uptime weighting | reactive (rolling 5-min window) | sequential per-model |
| Portkey | explicit weights (decimal) | reactive (status codes) | nestable (LB inside fallback) |
| Martian | ML per-request prediction | proactive benchmarking | automatic |

**Common pattern**: weighted selection + reactive cooldown + sequential fallback.

## Design

### 3-Layer Separation

```
Layer 1: Provider Inventory    — what exists (API keys, endpoints)
Layer 2: Availability          — what works now (health, cooldown)  
Layer 3: Selection Policy      — how to choose (weights, strategy)
```

### Phase 1: Weighted Selection (this RFC)

Extend cascade config to support weights. Weighted random selects the
first-attempt provider; remaining providers form the fallback chain.

#### Config Format (backward compatible)

```json
{
  "keeper_unified_models": [
    { "model": "glm-coding:glm-5.1", "weight": 50 },
    { "model": "claude:claude-haiku-4-5-20251001", "weight": 30 },
    { "model": "ollama:qwen3.5:35b-a3b-nvfp4", "weight": 20 }
  ]
}
```

Plain strings remain valid (weight defaults to equal):
```json
{
  "keeper_unified_models": ["glm-coding:glm-5.1", "ollama:qwen3.5:35b-a3b-nvfp4"]
}
```

#### Selection Algorithm

1. Parse weights from config (default: equal weight for all)
2. Normalize to probabilities: `w_i / sum(w)`
3. Weighted random pick for first-attempt provider
4. Remaining providers ordered by descending weight as fallback chain
5. Pass ordered list to `cascade_executor` (executor unchanged)

```
weights: [glm:50, haiku:30, ollama:20]
→ 50% chance: [glm, haiku, ollama]
→ 30% chance: [haiku, glm, ollama]  
→ 20% chance: [ollama, glm, haiku]
```

#### Type Changes

```ocaml
(* New: weighted model entry *)
type weighted_model = {
  model: string;
  weight: int;  (* relative weight, default 1 *)
}

(* parse_model_strings extended *)
val parse_weighted_model_strings :
  ?temperature:float -> ?max_tokens:int -> ... ->
  weighted_model list -> Provider_config.t list
(* Returns providers ordered by weighted random selection *)
```

### Phase 2: Reactive Health (future RFC)

Track per-provider success rate in a rolling window. Adjust effective
weights: `effective_weight = config_weight * success_rate`.

```ocaml
module Cascade_health : sig
  type t
  val create : unit -> t
  val record_success : t -> provider_key:string -> unit
  val record_failure : t -> provider_key:string -> unit
  val success_rate : t -> provider_key:string -> float
  (* Rolling 5-minute window, exponential decay *)
end
```

### Phase 3: Cooldown (future RFC)

After N consecutive failures, put provider in cooldown for M seconds.
During cooldown, provider is skipped (not attempted). LiteLLM pattern.

## Changes

### Files Modified

| File | Change |
|------|--------|
| `cascade_config.ml` | Parse `{model, weight}` JSON objects; weighted shuffle |
| `cascade_config.mli` | Export `weighted_model` type and parse function |
| `cascade_executor.ml` | No change (receives pre-ordered list) |
| `test/test_cascade_config.ml` | Weight parsing + shuffle distribution tests |

### Files Created

None in Phase 1.

## Backward Compatibility

- Plain string arrays work unchanged (each gets weight=1)
- `cascade_executor.ml` interface unchanged
- Existing consumers need no code changes; only `cascade.json` is updated

## Trade-offs

| Decision | Alternative | Why this way |
|----------|-------------|--------------|
| Weight in config JSON | ML-based routing (Martian) | Deterministic, debuggable, no training data needed |
| Weighted random + fallback | Pure round-robin | Respects provider priority while distributing load |
| Phase 1 without health | All-at-once | Ship value incrementally; health adds complexity |
| int weights (50/30/20) | float probabilities (0.5/0.3/0.2) | Ints are easier to reason about in config |

## Risks

- Weighted random adds non-determinism to provider selection — harder to
  reproduce exact cascade paths in debugging. Mitigated by logging the
  shuffled order at each call.
- Config format change requires cascade.json schema documentation update.

## References

- LiteLLM Router: `litellm/router.py`, `simple_shuffle.py`
- OpenRouter: `provider.sort`, uptime weighting
- Portkey: `strategy.mode: "loadbalance"`, `targets[].weight`
