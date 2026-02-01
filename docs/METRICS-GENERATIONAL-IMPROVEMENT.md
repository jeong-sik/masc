# Metrics: Generational Improvement Evidence

**Date**: 2026-02-01  
**Status**: Design (not implemented)  
**Goal**: 후대 에이전트가 선대보다 "더 낫다"는 증거 수집

---

## 핵심 질문

> "이전 에이전트보다 후대 석세서의 판단이 더 우월하다"를 어떻게 증명하는가?

---

## 측정 가능한 지표

### 1. Task Completion (객관적)

```ocaml
type task_metric = {
  generation: int;
  task_id: string;
  completed: bool;
  duration_ms: int;
  error_count: int;
  retry_count: int;
}
```

**비교 방법**:
- Gen 0: 100 tasks, 70% completion, avg 5min
- Gen 1: 100 tasks, 85% completion, avg 4min
- → Gen 1이 더 나음 (completion rate ↑, duration ↓)

### 2. Error Rate (객관적)

```ocaml
type error_metric = {
  generation: int;
  error_type: string;
  recoverable: bool;
  caused_handoff: bool;  (* 에러로 인한 조기 핸드오프? *)
}
```

**비교 방법**:
- Gen 0: 15 errors / 100 tasks = 15%
- Gen 1: 8 errors / 100 tasks = 8%
- → Gen 1이 더 나음 (error rate ↓)

### 3. Knowledge Retention (핵심!)

```ocaml
type knowledge_test = {
  generation: int;
  question: string;
  expected_answer: string;
  actual_answer: string;
  correct: bool;
  confidence: float;
}

(* DNA를 통해 전달된 지식이 유지되는가? *)
let test_knowledge_retention ~gen0_context ~gen1_agent =
  let questions = extract_key_facts gen0_context in
  List.map (fun q ->
    let answer = ask_agent gen1_agent q in
    { generation = 1; question = q; ... }
  ) questions
```

**비교 방법**:
- Gen 0이 알았던 핵심 사실 10개
- Gen 1에게 같은 질문
- 정답률이 80% 이상이면 DNA 전달 성공

### 4. Decision Quality (주관적 → 평가자 필요)

```ocaml
type decision_evaluation = {
  generation: int;
  decision_id: string;
  context: string;
  decision: string;
  evaluator: string;        (* "human" | "balthasar" | "peer" *)
  score: int;               (* 1-5 *)
  reasoning: string;
}
```

**평가 방법**:
- 같은 문제를 Gen 0과 Gen 1에게 제시
- 블라인드 평가 (어떤 세대인지 모르게)
- 점수 비교

### 5. Token Efficiency (비용)

```ocaml
type token_metric = {
  generation: int;
  task_id: string;
  input_tokens: int;
  output_tokens: int;
  task_complexity: float;   (* 정규화용 *)
  tokens_per_complexity: float;
}
```

**비교 방법**:
- 같은 복잡도 작업에 사용된 토큰
- Gen 1이 적은 토큰으로 해결하면 더 효율적

---

## 실험 설계

### A/B Test: Mitosis vs Compaction

```
Control (Compaction):
  - 100 tasks
  - 컨텍스트 꽉 차면 요약
  - Metrics 수집

Treatment (Mitosis):
  - 100 tasks (같은 것)
  - 컨텍스트 50%에서 prepare, 80%에서 handoff
  - Metrics 수집

비교:
  - Task completion rate
  - Error rate
  - Token efficiency
  - Knowledge retention (특정 사실 기억 테스트)
```

### Generational Tracking

```ocaml
type generation_summary = {
  generation: int;
  total_tasks: int;
  completed_tasks: int;
  avg_duration_ms: float;
  error_rate: float;
  knowledge_retention: float;  (* DNA로부터 *)
  token_efficiency: float;
}

let compare_generations gen0 gen1 =
  {
    completion_delta = gen1.completed_tasks /. gen1.total_tasks 
                    -. gen0.completed_tasks /. gen0.total_tasks;
    error_delta = gen0.error_rate -. gen1.error_rate;  (* 낮을수록 좋음 *)
    efficiency_delta = gen0.token_efficiency -. gen1.token_efficiency;
    retention = gen1.knowledge_retention;
  }
```

---

## 구현 계획

### Phase 1: Metrics Collection (기초)

```ocaml
(* lib/generational_metrics.ml *)

let record_task_completion ~generation ~task_id ~completed ~duration_ms ~errors =
  let metric = { generation; task_id; completed; duration_ms; error_count = errors; ... } in
  append_to_metrics_store metric

let record_handoff ~from_gen ~to_gen ~dna_size ~context_ratio =
  let metric = { from_gen; to_gen; dna_size; context_ratio; timestamp = now () } in
  append_to_handoff_log metric
```

### Phase 2: Knowledge Retention Test

```ocaml
(* DNA에서 핵심 사실 추출 *)
let extract_testable_facts dna =
  (* 패턴 매칭으로 "X는 Y이다" 형태 추출 *)
  ...

(* 후대 에이전트에게 질문 *)
let test_successor ~facts ~successor_agent =
  List.map (fun fact ->
    let question = fact_to_question fact in
    let answer = query_agent successor_agent question in
    evaluate_answer ~expected:fact.value ~actual:answer
  ) facts
```

### Phase 3: Dashboard

```
┌─────────────────────────────────────────────────────┐
│ Generational Improvement Dashboard                  │
├─────────────────────────────────────────────────────┤
│ Generation │ Tasks │ Complete │ Errors │ Retention │
│     0      │  100  │   70%    │  15%   │    -      │
│     1      │  100  │   82%    │   9%   │   78%     │
│     2      │   50  │   88%    │   5%   │   85%     │
├─────────────────────────────────────────────────────┤
│ Trend: ↑ Completion, ↓ Errors, ↑ Retention         │
│ Evidence: Gen 2 > Gen 1 > Gen 0                    │
└─────────────────────────────────────────────────────┘
```

---

## 성공 기준

| 지표 | 기준 | 의미 |
|------|------|------|
| Task Completion | Gen N+1 >= Gen N | 후대가 최소한 같거나 나음 |
| Error Rate | Gen N+1 <= Gen N | 후대가 실수를 덜 함 |
| Knowledge Retention | >= 70% | DNA 전달이 효과적 |
| Token Efficiency | 같은 복잡도에 적은 토큰 | 학습된 효율성 |

**핵심 증거**:
> "Generation N+1의 metrics가 Generation N보다 통계적으로 유의미하게 좋으면, Mitosis가 가치 있다."

---

## 실패 시 대응

만약 Gen N+1 < Gen N 이면:
1. DNA 추출 품질 문제 → DNA 알고리즘 개선
2. Handoff 타이밍 문제 → Threshold 조정
3. Spawn 품질 문제 → 다른 에이전트/모델 시도
4. **근본적 실패** → Compaction이 더 나음을 인정

---

## 참고

- Mitosis ADR: `ADR-001-MITOSIS-VS-COMPACTION.md`
- BALTHASAR 리뷰: 4.5/10 → "증거 필요"
