# Research Gaps: Concurrency & Knowledge Propagation

**Date**: 2026-02-01  
**Status**: Research needed

---

## 핵심 질문들

### 1. 동시 수정 충돌 (Conflict Resolution)

**문제**: 두 에이전트가 동시에 같은 지식을 수정하면?

**현재**: File-based backend → 마지막 쓰기 승리 (Last Write Wins)

**연구 방향**:
- **CRDT** (Conflict-free Replicated Data Types)
- **OT** (Operational Transformation)
- **Vector Clocks** for causality tracking

**참고 논문**:
- Shapiro et al., "A comprehensive study of CRDTs" (2011)
- Kleppmann, "Designing Data-Intensive Applications" Ch.5

```ocaml
(* CRDT 예시: G-Counter *)
type g_counter = (agent_id * int) list

let increment counter agent_id =
  match List.assoc_opt agent_id counter with
  | None -> (agent_id, 1) :: counter
  | Some n -> (agent_id, n + 1) :: List.remove_assoc agent_id counter

let merge a b =
  (* 각 agent별로 max 값 선택 *)
  List.fold_left (fun acc (id, n) ->
    let existing = List.assoc_opt id acc |> Option.value ~default:0 in
    (id, max n existing) :: List.remove_assoc id acc
  ) a b
```

---

### 2. 지식의 "진화" 메커니즘

**문제**: 어떻게 더 나은 패턴이 선택되는가?

**현재**: Fitness 기반 선택 (metrics 수집)

**부족한 점**:
- 패턴 "변이" 메커니즘 없음
- 교차 (crossover) 없음
- 선택압 조절 없음

**연구 방향**:
- **Genetic Programming** for pattern evolution
- **Memetic Algorithms** (local search + evolution)
- **Cultural Evolution** models

```ocaml
(* 패턴 진화 예시 *)
type pattern = {
  id: string;
  content: string;
  fitness: float;
  generation: int;
  parent: string option;
}

let mutate pattern =
  { pattern with
    content = apply_mutation pattern.content;
    generation = pattern.generation + 1;
    parent = Some pattern.id;
  }

let crossover p1 p2 =
  { id = generate_id ();
    content = merge_patterns p1.content p2.content;
    fitness = 0.0;  (* 아직 평가 안 됨 *)
    generation = max p1.generation p2.generation + 1;
    parent = Some p1.id;  (* 첫 번째 부모만 기록 *)
  }
```

---

### 3. 직접 통신 vs 간접 통신 (Stigmergy)

**문제**: 언제 직접 통신하고, 언제 환경을 통해 소통해야 하는가?

**현재**:
- 직접: `masc_broadcast`, `masc_messages`
- 간접: `deposit_pheromone`, `follow_pheromone`

**연구 방향**:
- 작업 복잡도에 따른 통신 모드 선택
- Stigmergy의 장점: 비동기, 느슨한 결합, 확장성
- 직접 통신의 장점: 빠른 피드백, 명확한 조율

**참고**:
- Dorigo, "Stigmergy as a Universal Coordination Mechanism" (2006)
- 개미 군집 최적화 (ACO)

---

### 4. 지식 전파 속도 vs 안정성

**문제**: 새로운 지식이 빠르게 퍼져야 하지만, 잘못된 지식도 빠르게 퍼짐

**Gossip Protocol 변형**:
- **Anti-entropy**: 주기적 동기화 (느리지만 확실)
- **Rumor mongering**: 새 정보만 전파 (빠르지만 불완전)
- **Reputation-based**: 신뢰도에 따라 전파 속도 조절

```ocaml
type knowledge = {
  content: string;
  confidence: float;      (* 0.0 - 1.0 *)
  source_fitness: float;  (* 출처 에이전트의 fitness *)
  propagation_count: int; (* 몇 번 전파됐는지 *)
}

let should_propagate k =
  (* 높은 신뢰도 + 높은 출처 fitness = 빠른 전파 *)
  let urgency = k.confidence *. k.source_fitness in
  urgency > 0.7 || k.propagation_count < 3
```

---

### 5. Spawn 타이밍 최적화

**문제**: 언제 새 에이전트를 spawn해야 최적인가?

**현재**: 50% prepare, 80% handoff (하드코딩)

**연구 방향**:
- 작업 복잡도 기반 동적 threshold
- 에이전트 pool 사전 워밍 (stem cells)
- Predictive spawning (미리 예측해서 생성)

**참고**:
- Kubernetes HPA (Horizontal Pod Autoscaler)
- Serverless cold start 최적화 연구

---

## 다음 단계

1. **CRDT 프로토타입**: 지식 병합 conflict 해결
2. **Pattern Evolution**: 변이 + 선택 메커니즘
3. **Gossip with Reputation**: 신뢰 기반 전파
4. **Adaptive Thresholds**: 동적 spawn 타이밍

---

## 참고 문헌

- [CRDT] Shapiro et al., "Conflict-free Replicated Data Types" (2011)
- [Stigmergy] Dorigo et al., "Stigmergy: A fundamental paradigm for MAS" (2006)
- [Gossip] Demers et al., "Epidemic algorithms for replicated DB" (1987)
- [Evolution] Dawkins, "The Selfish Gene" - Memes concept
- [Hebbian] Hebb, "The Organization of Behavior" (1949)
