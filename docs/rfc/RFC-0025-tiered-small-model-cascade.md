# RFC-0025: Tiered Small-Model Cascade (4B → 9B → 70B+)

- **Status**: Draft
- **Author**: vincent (with Claude)
- **Created**: 2026-05-03
- **Related**: RFC-0024 (Ollama integration), oas_worker_named_cascade.ml, cascade_fsm.ml, config/cascade.toml

## 1. Problem

현재 cascade는 모든 요청을 동일한 고비용 클라우드 모델로 라우팅. 간단한 분류/요약/리포맷 작업도 70B+ 모델을 사용하여 비용 낭비. Ollama 로컬 모델(RFC-0024)을 활용한 티어드 라우팅이 필요.

## 2. Current Architecture

```
keeper_turn → [big_three] → codex_cli → gemini_cli → kimi_cli → glm-coding → claude_code
                                    ↓ timeout/error
                              [keeper_diverse] → claude_code → gemini_cli → codex_cli
```

모든 요청이 동일 프로파일을 순차 순회. 태스크 복잡도에 따른 라우팅 없음.

## 3. Proposed Architecture

### 3.1 Task Complexity Detection

```ocaml
type task_complexity = Simple | Moderate | Complex

let detect_complexity ~messages ~tools ~max_tokens =
  let ctx_len = List.fold_left (fun acc m -> acc + String.length m.content) 0 messages in
  match ctx_len, tools, max_tokens with
  | len, [], mt when len < 2000 && mt <= 1000 -> Simple
  | len, [], mt when len < 8000 && mt <= 4000 -> Moderate
  | _ -> Complex
```

### 3.2 Tier Cascade Profiles

```toml
[routes]
simple_task = "tier_small"
moderate_task = "tier_medium"
complex_task = "big_three"

[tier_small]
comment = "4B-class local models for simple tasks. Cost ≈ $0."
models = [
  "ollama:llama3.2:3b",
  "ollama:phi-3-mini",
]
temperature = 0.3
max_tokens = 1000
fallback_cascade = "tier_medium"

[tier_medium]
comment = "9B-class models. Cost optimized."
models = [
  "ollama:llama3.2:8b",
  "codex_cli:gpt-5.3-codex-spark",
]
temperature = 0.2
max_tokens = 4096
fallback_cascade = "big_three"

# big_three stays as-is for complex tasks
```

### 3.3 Injection Point

`lib/oas_worker_named_cascade.ml`의 `resolve_cascade_providers` 이전에 complexity detection 삽입:

```
request → detect_complexity → select tier profile → resolve_cascade_providers → FSM execution
```

## 4. Design Principles

| # | Principle | Rationale |
|---|-----------|-----------|
| P1 | **Heuristic first, ML later.** | Context length + tool presence + max_tokens로 초기 분류. 정확도 측정 후 ML 분류기 도입 검토. |
| P2 | **Always fallback up.** | tier_small 실패 → tier_medium → big_three. 하위 티어 실패 시 상위로. |
| P3 | **Operator override.** | keeper가 명시적으로 `complex_task` 라우트를 요청하면 감지 스킵. |
| P4 | **Metrics per tier.** | 각 티어의 성공률, 지연시간, 비용을 개별 추적. |

## 5. Files to Modify

| File | Change | Priority |
|------|--------|----------|
| `lib/oas_worker_named_cascade.ml` | Complexity detection + tier routing | High |
| `config/cascade.toml` | `[tier_small]`, `[tier_medium]` 프로파일 | High |
| `lib/cascade/cascade_config.ml` | Tier 설정 스키마 | Medium |
| `lib/oas_worker_named.ml` | Tier metadata 전달 | Medium |
| `lib/cascade/cascade_inventory.ml` | Tier-aware scoring | Low |

## 6. Validation

1. Unit: `detect_complexity` 분류 정확도 (hand-labeled test set)
2. Integration: tier 라우팅 end-to-end
3. Benchmark: 100개 요청에 대해 tier 분포 + 비용 절감 측정
4. Fallback: small 실패 시 medium → large 자동 escalation

## 7. Scope Exclusions

- ML 기반 task classifier (P4 — 후속 작업)
- 자동 model download/pull (운영 자동화)
- Cross-tier context caching (cache tier 분리)
