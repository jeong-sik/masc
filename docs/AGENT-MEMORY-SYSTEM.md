# Agent Memory System

**Status**: Design Phase
**Author**: Vincent & Claude
**Date**: 2026-02-03
**Related**: `CELLULAR-AGENT.md`, `SPAWN-PERSISTENCE-DESIGN.md`, `CONTENT-DECAY-RESEARCH.md`

---

## 1. Overview

### Problem Statement

에이전트는 세션(Session)이 끝나면 학습한 내용을 잃어버린다. 매번 새 세션에서 같은 실수를 반복하고, 같은 패턴을 다시 발견해야 한다.

```
Session 1: "DRY 원칙을 적용하면 BusMap 버그가 해결되네"
Session 2: (새 에이전트) "DRY 원칙이 뭐지...?"  ← 학습 손실
```

### Design Goals

1. **Cross-session Learning Persistence**: 에이전트가 배운 것을 다음 세션에 전달
2. **Memory Lifecycle**: 오래된 기억은 자연스럽게 망각, 자주 쓰는 기억은 강화
3. **Agent Biography**: 에이전트의 성장 이력을 추적하고 분석
4. **Spawn-time Injection**: 새 에이전트 스폰 시 관련 기억을 프롬프트로 주입

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Agent Memory System                           │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐          │
│  │   Episode    │───▶│   Pattern    │───▶│    Agent     │          │
│  │   (Event)    │    │ (Knowledge)  │    │  (Learner)   │          │
│  └──────────────┘    └──────────────┘    └──────────────┘          │
│         │                   ▲                   │                    │
│         │                   │                   │                    │
│         ▼                   │                   ▼                    │
│  [:LEARNED_FROM]      [:LEARNED]         [:RECALLS]                 │
│  "where/when"         "what"             "reinforcement"            │
│                                                                      │
├─────────────────────────────────────────────────────────────────────┤
│  Storage: Neo4j (Railway) + JSONL (local backup)                    │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 2. Core Principles

### 2.1 Learning as Relationship

**핵심 인사이트**: Learning은 노드(명사)가 아니라 관계(동사)다.

기존 Neo4j에는 Vincent의 TIL을 저장하는 `Learning` 노드가 있다. 이것과 에이전트의 학습을 분리해야 한다.

| 주체 | 개념 | 저장 방식 |
|------|------|----------|
| **Vincent (사람)** | Today I Learned | `(:Learning)` 노드 (기존 유지) |
| **Agent (AI)** | 발견/깨달음 | `[:LEARNED]` 관계 |

```cypher
-- Vincent의 TIL (기존)
(:Person {name: "Vincent"})-[:WROTE]->(:Learning {title: "DRY 원칙"})

-- Agent의 학습 (신규)
(:Agent {name: "dreamer"})-[:LEARNED {confidence: 0.85}]->(:Pattern {name: "DRY 원칙"})
```

### 2.2 What vs Where

에이전트가 배운 것을 두 가지 관점에서 추적한다:

| 관계 | 의미 | 예시 |
|------|------|------|
| `[:LEARNED]` | **무엇**을 배웠는가 | Pattern, Concept, Tool, Technique |
| `[:LEARNED_FROM]` | **어디서/누구에게** 배웠는가 | Episode, Person, Document |

```
(Agent:dreamer)-[:LEARNED]->(Pattern:DRY원칙)
                   │
                   └─[:LEARNED_FROM]->(Episode:session-001)
                   └─[:LEARNED_FROM]->(Person:Vincent)
```

### 2.3 Learnable Node Types

에이전트가 `[:LEARNED]` 관계로 연결할 수 있는 대상:

| Node Type | Description | Example |
|-----------|-------------|---------|
| `Pattern` | 반복 가능한 해결 패턴 | DRY, SOLID, Error Handling |
| `Concept` | 추상적 개념/원리 | Dependency Injection |
| `Tool` | 도구/라이브러리 | ripgrep, Eio |
| `Technique` | 구체적 기법 | Power Law Decay |
| `Insight` | 일회성 깨달음 | "이 버그의 근본 원인" |

---

## 3. Neo4j Schema

### 3.1 Relationship: `[:LEARNED]`

에이전트가 무엇을 배웠는지 기록.

```cypher
CREATE (a:Agent {name: "dreamer"})
CREATE (p:Pattern {name: "DRY원칙", description: "Don't Repeat Yourself"})
CREATE (a)-[l:LEARNED {
  timestamp: timestamp(),              -- 학습 시점 (epoch ms)
  confidence: 0.85,                    -- 확신도 (0.0-1.0)
  context: "BusMap 버그 해결 중 발견",  -- 학습 맥락
  decay_factor: 1.0,                   -- 현재 감쇠 계수
  recall_count: 0                      -- 회상 횟수
}]->(p)
```

**Properties**:

| Property | Type | Description |
|----------|------|-------------|
| `timestamp` | int | 학습 시점 (epoch ms) |
| `confidence` | float | 학습 확신도 (0.0-1.0) |
| `context` | string | 학습 당시 맥락 |
| `decay_factor` | float | 감쇠 계수 (1.0에서 시작, 시간에 따라 감소) |
| `recall_count` | int | 회상 횟수 (강화 추적) |

### 3.2 Relationship: `[:LEARNED_FROM]`

학습의 출처를 추적.

```cypher
CREATE (a)-[lf:LEARNED_FROM {
  contribution: 0.7,                   -- 이 출처의 기여도
  timestamp: timestamp()
}]->(e:Episode {id: "session-001"})
```

### 3.3 Relationship: `[:RECALLS]`

에이전트가 기억을 회상할 때 기록. 강화 학습의 기반.

```cypher
CREATE (a)-[:RECALLS {
  timestamp: timestamp(),
  context: "similar bug encountered",
  successful: true                     -- 회상이 유용했는지
}]->(p:Pattern {name: "DRY원칙"})
```

### 3.4 Relationship: `[:REINFORCED]`

회상 후 강화된 관계 업데이트.

```cypher
-- recall 후 LEARNED 관계 업데이트
MATCH (a:Agent {name: "dreamer"})-[l:LEARNED]->(p:Pattern {name: "DRY원칙"})
SET l.recall_count = l.recall_count + 1,
    l.decay_factor = l.decay_factor * 1.3  -- 30% 강화
```

### 3.5 OCaml Type Definitions

```ocaml
(** lib/agent_memory.ml *)

(** Learning relationship properties *)
type learned_props = {
  timestamp: float;
  confidence: float;
  context: string;
  decay_factor: float;
  recall_count: int;
}

(** Learnable target types *)
type learnable =
  | Pattern of { name: string; description: string }
  | Concept of { name: string; domain: string }
  | Tool of { name: string; category: string }
  | Technique of { name: string; application: string }
  | Insight of { id: string; summary: string }

(** Learning source *)
type learning_source =
  | FromEpisode of { episode_id: string; contribution: float }
  | FromPerson of { person_name: string; contribution: float }
  | FromDocument of { doc_path: string; contribution: float }

(** Agent memory record *)
type agent_memory = {
  agent_name: string;
  learned: (learnable * learned_props) list;
  learned_from: learning_source list;
}
```

---

## 4. Memory Lifecycle

### 4.1 State Machine

```
                    ┌──────────────────────────────────────┐
                    │                                      │
                    ▼                                      │
  ┌─────────┐    ┌─────────┐    ┌─────────┐    ┌─────────┐
  │  Fresh  │───▶│  Active │───▶│  Stale  │───▶│ Dormant │
  │ (new)   │    │ (used)  │    │ (aged)  │    │ (cold)  │
  └─────────┘    └─────────┘    └─────────┘    └─────────┘
       │              │              │              │
       │              │              │              │
       │         [:RECALLS]     [:RECALLS]         │
       │              │              │              │
       └──────────────┴──────────────┴─────────────▼
                                              ┌─────────┐
                                              │Archived │
                                              │ (cold)  │
                                              └─────────┘
```

### 4.2 State Definitions

| State | Condition | Description |
|-------|-----------|-------------|
| **Fresh** | age < 24h | 방금 학습함, 최고 우선순위 |
| **Active** | recall_count > 0 AND age < 7d | 활발히 사용 중 |
| **Stale** | age > 7d AND no recall | 오래됨, decay 적용 시작 |
| **Dormant** | decay_factor < 0.3 | 거의 망각, 낮은 우선순위 |
| **Archived** | decay_factor < 0.1 AND age > 30d | 아카이브 대상 |

### 4.3 State Transition Triggers

```cypher
-- Fresh → Active (on recall)
MATCH (a:Agent)-[l:LEARNED]->(p)
WHERE l.timestamp > timestamp() - 86400000  -- 24h in ms
  AND l.recall_count > 0
RETURN a, l, p AS active_memories

-- Active → Stale (time-based)
MATCH (a:Agent)-[l:LEARNED]->(p)
WHERE l.timestamp < timestamp() - 604800000  -- 7d in ms
  AND NOT EXISTS((a)-[:RECALLS]->(p))
RETURN a, l, p AS stale_memories

-- Stale → Active (on reinforcement)
-- Handled by decay/reinforce model
```

---

## 5. Decay & Reinforcement Model

### 5.1 Base Decay Formula

`CONTENT-DECAY-RESEARCH.md`에 정리된 Power Law 후보 공식을 설계 참고값으로 사용:

```
decay(t) = (1 + t/h)^(-b)
```

| Parameter | Value | Source |
|-----------|-------|--------|
| `h` (half-life) | 12.5 hours | Signals Agency 2024 |
| `b` (decay exponent) | 1.0 | Default (calibration 필요) |

### 5.2 Reinforcement Boost

회상 시 감쇠를 상쇄:

```
reinforced_decay = decay(t) × (1 + log(1 + recall_count) × r)
```

| Parameter | Value | Description |
|-----------|-------|-------------|
| `r` | 0.3 | Reinforcement coefficient |

### 5.3 OCaml Implementation

```ocaml
(** lib/memory_decay.ml *)

let half_life = 12.5 *. 3600.0        (* 12.5 hours in seconds *)
let decay_exponent = 1.0
let reinforce_coef = 0.3

(** Calculate decay factor *)
let decay ~timestamp =
  let now = Unix.gettimeofday () in
  let age_seconds = now -. timestamp in
  let age_hours = age_seconds /. 3600.0 in
  (1.0 +. age_hours /. (half_life /. 3600.0)) ** (-. decay_exponent)

(** Calculate reinforced score *)
let reinforced_score ~timestamp ~recall_count =
  let base_decay = decay ~timestamp in
  let boost = 1.0 +. log (1.0 +. float recall_count) *. reinforce_coef in
  base_decay *. boost

(** Effective memory score for retrieval *)
let memory_score ~learned_props ~relevance =
  let { timestamp; confidence; recall_count; _ } = learned_props in
  let freshness = reinforced_score ~timestamp ~recall_count in
  (* Stanford Generative Agents 공식: α·recency + β·importance + γ·relevance *)
  1.0 *. freshness +. 1.0 *. confidence +. 1.0 *. relevance
```

### 5.4 Decay Visualization

```
1.0 ┤███
    │ ██▌
0.8 ┤  █▌
    │   █
0.6 ┤   █▌   recall here → boost
    │    █      ↗███
0.4 ┤    █▌   ████  ██
    │     █  ██       ██▌
0.2 ┤     ██▌           ████▌
    │       ████            █████████
0.0 ┼─────────────────────────────────────────▶ time
    0h    12.5h   24h    48h     72h    96h
              (half-life)
```

---

## 6. Agent Biography

### 6.1 Episode Chain

에이전트의 성장 이력을 Episode 체인으로 추적:

```cypher
(e1:Episode {id: "session-001", date: "2026-01-15"})
  -[:NEXT_SESSION {gap_hours: 24}]->
(e2:Episode {id: "session-002", date: "2026-01-16"})
  -[:NEXT_SESSION {gap_hours: 48}]->
(e3:Episode {id: "session-003", date: "2026-01-18"})
```

### 6.2 Transformation Points

에이전트가 크게 변화한 지점을 표시:

```cypher
CREATE (a:Agent {name: "dreamer"})
CREATE (t:Transformation {
  id: "transform-001",
  timestamp: timestamp(),
  type: "paradigm_shift",
  description: "Imperative → Functional 패러다임 전환",
  trigger_episode: "session-042"
})
CREATE (a)-[:TRANSFORMED_BY]->(t)
```

### 6.3 Growth Metrics

| Metric | Query | Description |
|--------|-------|-------------|
| Total Learnings | `COUNT((a)-[:LEARNED]->())` | 총 학습 수 |
| Active Knowledge | `COUNT(WHERE decay_factor > 0.5)` | 활성 지식 |
| Retention Rate | `active / total` | 기억 유지율 |
| Recall Frequency | `AVG(recall_count)` | 평균 회상 빈도 |
| Transformation Count | `COUNT((a)-[:TRANSFORMED_BY]->())` | 변화 횟수 |

### 6.4 Biography Query

```cypher
-- Get agent biography with growth curve
MATCH (a:Agent {name: $agent_name})
OPTIONAL MATCH (a)-[l:LEARNED]->(knowledge)
OPTIONAL MATCH (a)-[:TRANSFORMED_BY]->(t:Transformation)
WITH a,
     collect(DISTINCT {
       knowledge: knowledge.name,
       learned_at: l.timestamp,
       current_decay: l.decay_factor,
       recalls: l.recall_count
     }) as learnings,
     collect(DISTINCT t) as transformations
RETURN a.name as agent,
       size(learnings) as total_learnings,
       size([x IN learnings WHERE x.current_decay > 0.5]) as active_knowledge,
       transformations
```

---

## 7. Spawn-time Memory Injection

### 7.1 4-Stage Pipeline

새 에이전트 스폰 시 관련 기억을 주입하는 파이프라인:

```
┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│   1. Query   │───▶│  2. Decay    │───▶│ 3. Format   │───▶│  4. Inject   │
│   Memories   │    │   Scoring    │    │  Few-shot   │    │   Prompt     │
└──────────────┘    └──────────────┘    └──────────────┘    └──────────────┘
     │                    │                   │                    │
     ▼                    ▼                   ▼                    ▼
 "task context"      decay(t) × boost    Markdown format     Augmented prompt
 → related memories   → ranked list       → bullet points     → spawn()
```

### 7.2 Stage 1: Query Memories

태스크 컨텍스트 기반으로 관련 기억 쿼리:

```cypher
MATCH (a:Agent {name: $agent_name})-[l:LEARNED]->(knowledge)
WHERE knowledge.name CONTAINS $keyword OR knowledge.description CONTAINS $keyword
RETURN knowledge, l
ORDER BY l.decay_factor * (1 + log(1 + l.recall_count) * 0.3) DESC
LIMIT $limit
```

### 7.3 Stage 2: Decay Scoring

```ocaml
let query_spawn_memories ~agent_name ~task_context ~limit =
  let keywords = extract_keywords task_context in
  let raw_memories = query_neo4j ~agent_name ~keywords in
  raw_memories
  |> List.map (fun m -> (m, reinforced_score ~timestamp:m.timestamp ~recall_count:m.recall_count))
  |> List.sort (fun (_, s1) (_, s2) -> compare s2 s1)
  |> List.take limit
```

### 7.4 Stage 3: Few-shot Formatting

```ocaml
let format_as_fewshot memories =
  let format_one (m, score) =
    Printf.sprintf "- **%s** (confidence: %.0f%%, freshness: %.0f%%): %s"
      m.name (m.confidence *. 100.0) (score *. 100.0) m.context
  in
  memories
  |> List.map format_one
  |> String.concat "\n"
```

**Output Example**:
```markdown
## Your Prior Knowledge (from previous sessions)

- **DRY원칙** (confidence: 85%, freshness: 72%): BusMap 버그 해결 중 발견
- **Power Law Decay** (confidence: 90%, freshness: 45%): 콘텐츠 신선도 연구에서 적용
- **Eio Switch 패턴** (confidence: 78%, freshness: 88%): 리소스 정리 best practice
```

### 7.5 Stage 4: Prompt Injection

```ocaml
(** spawn_eio.ml 확장 *)
let spawn_with_memory ~sw ~env ~agent_name ~prompt ?task_context () =
  let memories = match task_context with
    | Some ctx ->
        let scored = query_spawn_memories ~agent_name ~task_context:ctx ~limit:10 in
        format_as_fewshot scored
    | None -> ""
  in
  let augmented_prompt =
    if memories = "" then prompt
    else Printf.sprintf "%s\n\n%s\n\n%s"
      memory_injection_header memories prompt
  in
  spawn ~sw ~env ~agent_name ~prompt:augmented_prompt ()

let memory_injection_header = {|
---
## Your Prior Knowledge (from previous sessions)

The following are relevant learnings from your past sessions. Use them if applicable:
|}
```

### 7.6 Integration with spawn_eio.ml

현재 `spawn_eio.ml`의 `masc_lifecycle_suffix`와 유사한 패턴으로 메모리 주입:

```ocaml
(* 현재 구조 *)
let augmented_prompt = prompt ^ masc_lifecycle_suffix

(* 확장 후 구조 *)
let augmented_prompt =
  memory_injection (query_memories agent_name task_context) ^
  prompt ^
  masc_lifecycle_suffix
```

---

## 8. Example Cypher Queries

### 8.1 Record New Learning

```cypher
// Agent가 Pattern을 배움
MATCH (a:Agent {name: "dreamer"})
MERGE (p:Pattern {name: "DRY원칙"})
ON CREATE SET p.description = "Don't Repeat Yourself"
CREATE (a)-[:LEARNED {
  timestamp: timestamp(),
  confidence: 0.85,
  context: "BusMap 버그 해결 중 발견",
  decay_factor: 1.0,
  recall_count: 0
}]->(p)
```

### 8.2 Record Learning Source

```cypher
// Episode에서 배움
MATCH (a:Agent {name: "dreamer"})-[l:LEARNED]->(p:Pattern {name: "DRY원칙"})
MATCH (e:Episode {id: "session-001"})
CREATE (a)-[:LEARNED_FROM {contribution: 0.7, timestamp: timestamp()}]->(e)
```

### 8.3 Query Biography with Decay

```cypher
// 에이전트의 활성 지식 조회 (decay 적용)
MATCH (a:Agent {name: "dreamer"})-[l:LEARNED]->(knowledge)
WITH a, knowledge, l,
     // Power law decay 계산
     (1.0 + (timestamp() - l.timestamp) / 1000.0 / 3600.0 / 12.5) ^ -1.0 as base_decay,
     // Reinforcement boost
     1.0 + log(1.0 + l.recall_count) * 0.3 as boost
WITH a, knowledge, l, base_decay * boost as effective_score
WHERE effective_score > 0.3  // Dormant 이상만
RETURN knowledge.name as knowledge,
       l.confidence as confidence,
       effective_score as freshness,
       l.recall_count as recalls
ORDER BY effective_score DESC
LIMIT 20
```

### 8.4 Query Archive Candidates

```cypher
// 아카이브 대상 조회
MATCH (a:Agent)-[l:LEARNED]->(knowledge)
WITH a, knowledge, l,
     (1.0 + (timestamp() - l.timestamp) / 1000.0 / 3600.0 / 12.5) ^ -1.0 as decay
WHERE decay < 0.1 AND (timestamp() - l.timestamp) > 2592000000  // 30일
RETURN a.name, knowledge.name, decay, l.timestamp
```

### 8.5 Update Reinforcement

```cypher
// 회상 후 강화 업데이트
MATCH (a:Agent {name: $agent})-[l:LEARNED]->(p:Pattern {name: $pattern})
SET l.recall_count = l.recall_count + 1,
    l.decay_factor = l.decay_factor * 1.3
CREATE (a)-[:RECALLS {
  timestamp: timestamp(),
  context: $context,
  successful: $successful
}]->(p)
RETURN l.recall_count as new_count, l.decay_factor as new_decay
```

---

## 9. Implementation Phases

| Phase | Scope | Effort | Dependencies |
|-------|-------|--------|--------------|
| **1. Schema & Basic Storage** | Neo4j 스키마, `[:LEARNED]` 기록 | 2-3일 | Neo4j 접근 |
| **2. Decay Scoring** | `memory_decay.ml`, 점수 계산 | 2일 | Phase 1 |
| **3. Spawn Integration** | `spawn_eio.ml` 확장, 메모리 주입 | 2일 | Phase 2 |
| **4. Biography Tracking** | Episode chain, Transformation | 2일 | Phase 1-3 |
| **5. Auto-learning** | 세션 종료 시 자동 학습 기록 | 3일 | Phase 4 |

### Phase 1 Deliverables

- [ ] `lib/agent_memory.ml` — 타입 정의
- [ ] Neo4j 스키마 마이그레이션 스크립트
- [ ] `masc_learn` MCP 도구 (수동 학습 기록)
- [ ] 테스트 커버리지

### Phase 2 Deliverables

- [ ] `lib/memory_decay.ml` — Decay/Reinforce 계산
- [ ] `masc_recall` MCP 도구 (회상 기록)
- [ ] Decay 시각화 (optional)

### Phase 3 Deliverables

- [ ] `spawn_eio.ml` 확장 — `spawn_with_memory`
- [ ] Few-shot formatter
- [ ] Integration tests

### Phase 4 Deliverables

- [ ] Episode chain 관리
- [ ] Transformation 기록
- [ ] `masc_biography` MCP 도구
- [ ] Growth metrics dashboard (optional)

---

## 10. Future Considerations

### 10.1 Inter-agent Knowledge Transfer

세대 간 지식 전달:

```cypher
// Successor가 predecessor의 지식을 상속
MATCH (pred:Agent {name: "dreamer-gen1"})-[l:LEARNED]->(knowledge)
MATCH (succ:Agent {name: "dreamer-gen2"})
CREATE (succ)-[:INHERITED_FROM {
  original_confidence: l.confidence,
  inherited_at: timestamp(),
  dilution: 0.8  // 상속 시 20% 희석
}]->(pred)
```

### 10.2 Collaborative Learning

여러 에이전트가 같은 것을 배우면 신뢰도 상승:

```cypher
MATCH (a1:Agent)-[l1:LEARNED]->(p:Pattern)
MATCH (a2:Agent)-[l2:LEARNED]->(p)
WHERE a1 <> a2
SET p.community_confidence = (l1.confidence + l2.confidence) / 2 * 1.1
```

### 10.3 Contradiction Handling

충돌하는 학습 감지:

```cypher
MATCH (a:Agent)-[:LEARNED {context: c1}]->(p1:Pattern)
MATCH (a)-[:LEARNED {context: c2}]->(p2:Pattern)
WHERE p1.name <> p2.name AND similarity(c1, c2) > 0.8
RETURN p1, p2, c1, c2 AS potential_contradiction
```

---

## Appendix A: Relation to Existing Modules

| Module | Relation | Integration Point |
|--------|----------|-------------------|
| `memory_stream.ml` | Observation → Learning 변환 | `Observation` 타입에서 학습 추출 |
| `spawn_eio.ml` | 메모리 주입 지점 | `spawn_with_memory` 추가 |
| `handover.ml` | DNA에 학습 포함 | `key_decisions` → 학습 후보 |
| `keeper_heartbeat.ml` | Decay 공식 공유 | `post_freshness` 와 동일 모델 |

---

## Appendix B: Anti-patterns

### B.1 Learning Everything

모든 것을 학습으로 기록하면 노이즈가 된다.

**Guideline**: confidence 0.7 이상만 기록

### B.2 Infinite Memory

메모리를 무한히 쌓으면 검색이 느려진다.

**Guideline**: Archived 상태의 메모리는 주기적으로 cold storage로 이동

### B.3 Premature Abstraction

구체적 경험 없이 추상 패턴을 학습하면 오용 위험.

**Guideline**: `[:LEARNED_FROM]` 없는 학습은 경고

---

## Changelog

### 2026-02-03

- Initial design document created
- Core principles established: Learning as Relationship
- Neo4j schema defined
- Decay model proposal linked from CONTENT-DECAY-RESEARCH.md
- 4-stage spawn injection pipeline designed
- Self-feedback loop: Added Open Questions section

---

## Appendix C: Open Questions & Known Issues

> 이 섹션은 셀프 피드백 루프를 통해 도출된 미해결 문제들입니다.
> 구현 전에 반드시 해결해야 합니다.

### C.1 "Agent가 배웠다"의 기준 부재

**문제**: `confidence 0.7 이상만 기록`이라고 했지만, 누가 confidence를 판단하는가?

에이전트가 스스로 "나는 이것을 85% 확신으로 배웠다"고 판단하는 것은 **자가 검증**이며, Library 설계에서 지적된 `verified_by: 작성자` 문제와 동일.

**해결 후보**:
1. 제3자 검증 필수 — 다른 에이전트가 `[:VERIFIED_BY]` 관계 추가
2. "실험 결과"만 저장 — 벤치마크 수치, 에러 해결 기록 등 검증 가능한 것만
3. `pending_verification` 상태 추가 — 검증 전까지 spawn injection 제외

### C.2 Decay 계산 성능

**문제**: 매 쿼리마다 복잡한 수학 연산 필요

```cypher
-- 이 계산을 1000개 학습 기록에 대해 매번 수행
(1.0 + (timestamp() - l.timestamp) / 1000.0 / 3600.0 / 12.5) ^ -1.0
```

Neo4j는 복잡한 수학 연산에 최적화되어 있지 않음.

**해결 후보**:
1. 배치 업데이트 — cron job으로 `decay_factor` 필드를 주기적으로 갱신
2. Pre-computed bucket — "1시간 이내", "1일 이내", "1주 이내" 등 구간별 고정 점수
3. 쿼리 시 계산 대신 `updated_at` 기준 정렬만 사용

### C.3 memory_stream.ml과의 중복

**현재 상황**:

| 기존 memory_stream.ml | 새 AGENT-MEMORY-SYSTEM |
|----------------------|------------------------|
| Observation, Action, Reflection, Plan | Pattern, Concept, Tool, Insight |
| JSONL 저장 (로컬) | Neo4j 관계 (Railway) |
| Stanford scoring 공식 | 동일한 scoring 공식 |

두 시스템이 병행되면 어디에 뭘 저장하는지 혼란.

**해결 후보**:
1. memory_stream = "단기 메모리" (세션 내), AGENT-MEMORY-SYSTEM = "장기 메모리" (세션 간)
2. memory_stream에서 `Reflection` 타입 → 자동 승격 ([:LEARNED] 생성)
3. memory_stream 폐기, AGENT-MEMORY-SYSTEM으로 통합

### C.4 Spawn-time Injection 토큰 효율

**문제**: `limit:10`으로 항상 10개 기억 주입 → 무관한 기억도 포함될 수 있음

**해결 후보**:
1. Relevance threshold — 점수 0.5 이하는 제외
2. 2-stage selection — MODEL에게 "필요한 기억만 선택"하도록 추가 호출
3. Zero-injection default — 명시적 요청 시에만 주입

### C.5 RAG와의 차별점 모호

**Library 설계 비판에서 지적된 것과 동일한 문제**:

> "50+ 문서 → Neo4j/Qdrant 연동" — 그 시점에 RAG가 됨. 처음부터 RAG와 구분하려던 목적이 사라짐.

**이 설계가 RAG와 다르려면**:
1. 저장 대상 제한 — "실험 결과", "에러 해결 기록", "검증된 패턴"만
2. 관계 그래프 활용 — 단순 유사도 검색이 아닌 `[:LEARNED_FROM]` 경로 추적
3. 인과관계 저장 — "왜 이 패턴을 배웠는지" 맥락 필수

### C.6 결정 필요 사항

| 질문 | 후보 | 결정 |
|------|------|------|
| 검증 주체 | 자가검증 / 제3자 / 없음 | **하이브리드** (아래 참조) |
| Decay 계산 | 실시간 / 배치 / 구간별 | **실시간** (문제 발생 시 배치 전환) |
| memory_stream 통합 | 분리 유지 / 승격 패턴 / 폐기 | **승격 패턴** (Reflection → pending → Learned) |
| Injection 기본값 | 항상 / 요청 시 / 임계값 이상 | **항상** (limit:10, decay 기준 정렬) |
| RAG 차별화 | 저장 제한 / 그래프 활용 / 인과관계 | **그래프 활용** (검증된 경험의 관계 추적) |

### C.7 결정: 하이브리드 검증 모델 (2026-02-03)

**근거**: Stanford Generative Agents (Park et al. 2023) + Storage-Reflection-Experience 프레임워크

**승격 파이프라인**:

```
Observation (memory_stream)
    │
    │ importance ≥ 7 AND 유사 이벤트 2회 이상
    ▼
Reflection (pending_verification)
    │
    ├── 제3자 에이전트 검증 [:VERIFIED_BY] ─────┐
    │                                           │
    ├── 검증 가능한 증거 (벤치마크, 테스트 등) ──┼──▶ Learned [:LEARNED]
    │                                           │
    └── 7일 경과, 검증 없음 ──────────────────▶ ❌ 폐기
```

**검증 가능한 증거 예시**:
- 벤치마크 수치 (before: 100ms → after: 50ms)
- 에러 해결 기록 (stack trace + fix commit)
- 테스트 통과 기록 (test name + result)
- 다른 에이전트가 동일 패턴 발견

**참고 문헌**:
- [Stanford Generative Agents (Park et al. 2023)](https://arxiv.org/abs/2304.03442)
- [Memory in the Age of AI Agents Survey (2024)](https://arxiv.org/abs/2512.13564)
