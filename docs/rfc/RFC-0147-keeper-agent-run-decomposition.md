---
rfc: "0147"
title: "Keeper Agent Run — Stage Decomposition of run_turn Step 8"
status: Draft
created: 2026-05-19
updated: 2026-05-20
author: vincent
supersedes: []
superseded_by: null
related: ["0051", "0056", "0085", "0136"]
implementation_prs: []
renumbered_from: "0144 → 0145 → 0147"
---

# RFC-0147 — Keeper Agent Run Decomposition

> **Renumbered 2026-05-20 (2nd runtime)**: 본 RFC 는 원래 RFC-0144 (PR
> #16773, merged `bf142ff67f`) 로 작성되었으나, 동시 작성된 PR #16769
> (`RFC-0144 — Workaround Sunset Tracking for Keeper Dedup Carryovers`,
> merged `99b14ac45f`) 와 번호 충돌 → PR #16779 가 본 RFC 를 RFC-0145 로
> renumber. 그러나 같은 시각 (15초 간격) PR #16780 (`RFC-0145 —
> Permissive-Silent-Fallback Elimination`) 가 머지되어 두 번째 0145
> 충돌 발생. parse_outcome 모듈 및 tool_keeper 사이트가 이미 RFC-0145
> 를 인용 (6 코드 참조) 하므로 본 RFC 를 RFC-0147 로 재-renumber
> (RFC-0146 은 PR #16833 in-flight 사용 중). 메모리
> `feedback_rfc_number_reservation_needed.md` recovery 패턴 적용.

본 RFC는 `lib/keeper/keeper_agent_run.ml` (2103 LOC) 의 단일 함수 `run_turn` 내부 *Step 8 "Run Agent" body* (L424-L2103, ~1679 LOC) 를 *stage-typed sub-module* 들로 분해하는 설계 문서다.

RFC-0136 (`keeper_unified_turn` decomposition) 의 자매 RFC — 동일 *single mega-function* 패턴 + *Parse, don't validate* + *typed wrapper* 접근.

---

## 1. 배경

### 1.1 현재 상태

`lib/keeper/keeper_agent_run.ml` = 2103 LOC, godfile rank 1 (post-RFC-0136). top-level let 정의 13개:

| Lines | 함수 | 종류 |
|-------|------|------|
| L17-22 | 6 re-exports from `Turn_helpers` | sibling re-export |
| L24 | 1 re-export from `Contract_helpers` | sibling re-export |
| L25-78 | 5 small helpers (`progress_keeper_tool_names_for_contract`, `completion_contract_result_for_progress_evidence` 등) | inline helper |
| **L80** | **`run_turn`** | **main mega-function L80-L2103 = 2023 LoC (전체 96%)** |

interface (`.mli`, 346 LOC) 의 surface 는 `run_turn` + 7 re-exports.

### 1.2 기존 부분 추출

`run_turn` 의 *상위 prepare section* 은 이미 sibling 모듈로 추출됨:

| Step | Lines | Sibling module |
|------|-------|----------------|
| Steps 0-4 (params, session dir, checkpoint, base prompt, working context, hygiene) | L153-L260 | `Keeper_run_context.prepare_run_context` |
| Steps 5-6 (turn prompt, memory/temporal context, prompt metrics, history, token estimation) | L262-L308 | `Keeper_run_prompt.build_turn_context` |
| Step 7 (agent setup — tools, hooks, reducer, memory, acc) | L309-L420 | `Keeper_run_tools.prepare_agent_setup` |

또한 sibling helpers:

| Module | LoC | 용도 |
|--------|-----|------|
| `keeper_agent_run_turn_helpers` | 229+83 | 6 re-exported helpers |
| `keeper_agent_run_contract_helpers` | 50+17 | contract tool helpers |

### 1.3 남은 작업 — Step 8 "Run Agent" body

L424-L2103 = **1679 LOC** 가 *single Step 8 closure*. 내부에 다음 *inline sub-section* 명시 주석:

| 주석 | Line | 의미 |
|------|------|------|
| `(* 8. Run Agent *)` | L424 | mega-section 시작 |
| Phase 0: wake-time payload telemetry | L565 | Option C baseline |
| Contract violation retry (max 1) | L719-L773 | 1-shot retry + User feedback |
| Thinking blocks extract & persist | L791 | trajectory JSONL |
| Partial tolerance (mixed valid/invalid tool calls) | L918 | issue #8471 |
| Classify (most-specific actionable signal) | L1022 | structured signal classifier |
| Required-tool turn filter | L1078 | provider allowlist |
| Checkpoint save (after runtime result) | L1346 | deferred persist |
| Memory write (deterministic) | L1518 | post-turn |
| Episodic memory (episode from typed turn evidence) | L1569 | post-turn |
| Memory bank compaction (dedup + consolidate) | L1582 | post-turn |
| Quality metrics (goal alignment + memory recall) | L1617 | post-turn |
| Canonical success emit (RFC-0047 PR-4) | L1800 | wire format |
| Phase 5: wire goal/task/board with keeper tool results | L2000 | post-turn |
| Receipt append failure escalation (Tier A2 / Cycle 5) | L1942 | integrity |

### 1.4 선례: RFC-0136

[RFC-0136](RFC-0136-keeper-unified-turn-decomposition.md) (Active) 은 동일 패턴의 `keeper_unified_turn.ml` (1943 LOC) `run_keeper_cycle` 함수 분해. 6 sub-PR 머지 후 -302 LoC (-15.5%). PR-4-d/e 보류 (retry_loop body internal cohesion 으로 추출 어려움).

RFC-0147 는 RFC-0136 의 *측정 + boundary 식별 + typed wrapper* 패턴 그대로 차용. 단 *Step 8 body 가 retry_loop body (610 LoC) 보다 2.75× 큰 (1679 LoC)* 만큼 sub-PR 수 더 많음.

---

## 2. Motivation

### 2.1 정량 측정

- `lib/keeper/keeper_agent_run.ml` = 2103 LOC. **현재 godfile rank 1** (RFC-0136 결과 `keeper_unified_turn` 4위로 내려간 후).
- `scripts/lint/godfile-size-regression.sh` cap = 3350 LOC. 위반은 없지만 *fundamental_roadmap.md Phase 5* 의 godfile target 6개 중 하나.
- `run_turn` 의 1679 LoC Step 8 body 가 *모든 keeper turn 의 main path* — 잠재 충돌 face. stage decomposition 후 *PR 단위 충돌 면* 분산.

### 2.2 구조적 결함

Step 8 body 는 *9+ implicit sub-section 을 직렬 let-chain + inline 주석* 으로 표현 (1.3 표 참조). 각 sub-section 의 *boundary 는 명시적으로 typed 되지 않음* — *Alexis King "Parse, don't validate"* 위반.

post-turn 시리즈 (memory write / episodic / compaction / quality metrics) 가 *모두 inline* 으로 묶여 있어 *post-turn 행동 변경 시 mega-section 전체 컨텍스트 필요*.

### 2.3 작성자 의도

inline 주석 (`(* 8. Run Agent *)`, `(* Phase 0 *)`, `(* Phase 5 *)`) 는 *작성자가 stage 경계를 의식*하면서도 *typed 분리는 미적용*. 본 RFC 는 그 *주석 의도* 를 *file structure 에 reify* 한다.

---

## 3. Scope

### 3.1 In scope

- Step 8 body (L424-L2103, ~1679 LOC) 의 *typed-wrapper-extractable sub-section* 추출.
- 각 sub-section 은 *RFC-0136 PR-4-c 패턴* (small typed boundary, generic where possible).
- mli surface 변경 최소화 (run_turn 단일 entry 보존).

### 3.2 Out of scope

- `run_turn` 함수 자체의 인자 (~30 labeled args) 재구성 — 별도 RFC.
- `Keeper_run_context` / `Keeper_run_prompt` / `Keeper_run_tools` 기존 sibling 의 추가 분할 — 본 RFC 외 영역.
- Step 8 body 의 *internal recursion* 또는 *큰 context record* 도입 (RFC-0136 PR-4-d/e 보류 결정 참고).

### 3.3 RFC-0136 학습 적용

| 학습 | RFC-0147 적용 |
|------|---------------|
| typed boundary < 16 deps | **small typed wrapper 우선** — 각 sub-section 의 *낮은 deps 영역*만 추출 |
| record destructuring 16-deps limit | **20+ deps 추출 거부** — boundary 재측정 후 분할 또는 보류 |
| retry_loop internal cohesion 추출 어려움 | **post-turn 시리즈는 단순 직렬 — extractable 가능성 높음** |
| dispatch_with_watchdog 88 LoC subset 추출 가능 | **유사 subset 식별 우선** |

---

## 4. PR Plan (잠정, audit 진행 후 조정 예정)

후보 sub-PR (PR-4-c 패턴 적용 가능 sub-section 우선):

| PR | Sub-section | Line range | 추정 LoC | 위험도 |
|----|------------|-----------|---------|--------|
| PR-1 | Phase 0 wake-time payload telemetry | L565-? | -50~-100 | LOW |
| PR-2 | Contract violation retry (max 1) | L719-L773 | -50~-80 | LOW (bounded) |
| PR-3 | Thinking blocks extract & persist | L791-? | -50~-100 | LOW |
| PR-4 | Post-turn memory write series (deterministic + episodic + compaction + quality) | L1518-L1617 | -150~-250 | MEDIUM |
| PR-5 | Canonical success emit (RFC-0047 PR-4) | L1800-? | -100~-200 | MEDIUM |
| PR-6 | Receipt append failure escalation | L1942-? | -50~-100 | LOW |
| PR-7 | Required-tool turn filter | L1078-? | -100~-200 | MEDIUM |
| PR-8 | Classify (structured signal) | L1022-? | -50~-100 | MEDIUM |
| PR-9 | Phase 5 goal/task/board wire | L2000-? | -50~-150 | LOW |

**누적 추정 (낙관)**: -650 ~ -1280 LoC. RFC-0136 실측 *원안 대비 22%* 패턴 따르면 *현실 누적 -150~-300 LoC* 가 보수적 예상.

PR 순서: *bounded LOW risk* (PR-1/2/3/6) 부터 → *MEDIUM* (PR-4/5/7/8) → *complex* (PR-9). 본 plan 은 *audit-driven*, PR-1 머지 후 *각 PR 영역 실측 후 boundary 조정*.

---

## 5. Risks & Mitigations

### 5.1 Step 8 의 nested closure 의존성

Step 8 안 nested fun() callback 다수 — extractable sub-section 의 *outer scope 의존* 정량 미측정. 각 sub-PR impl 시점 *실측 후 boundary 결정*.

**Mitigation**: PR-4-c 처럼 *typed callback + caller scope helper* 패턴 차용. 큰 deps record 대신 *small typed wrapper + closure callback*.

### 5.2 Post-turn 시리즈 순서 의존성

L1518 (deterministic) → L1569 (episodic) → L1582 (compaction) → L1617 (quality) 의 *직렬 순서* 가 *post-turn 일관성 invariant*. mega-section 분할 시 순서 보존 필수.

**Mitigation**: PR-4 (post-turn 시리즈) 가 *order-preserving sibling 모듈* 하나로 묶음 (4 sub-step 을 모듈 내 함수로). 또는 PR-4 보류 후 PR-4-1/2/3/4 로 fine split.

### 5.3 Sub-PR 개수 (9+)

RFC-0136 의 6 sub-PR + 2 docs PR = 8 PR. 본 RFC 는 9+ 추정 — 더 많은 cohort. 사용자 검토 부담 증가.

**Mitigation**: PR-1/2/3 머지 후 *진척 보고* + *남은 PR 우선순위 재정렬*. RFC-0136 Phase 4 sub-doc 같은 *중간 계획 sub-doc* 분리 가능.

---

## 6. Done Criteria

### 6.1 PR-1 done criteria

- [ ] `keeper_agent_run_phase_0_telemetry.{ml,mli}` 또는 적절한 명명 생성.
- [ ] Phase 0 wake-time payload telemetry 가 typed wrapper 로 추출.
- [ ] `dune build @check` 통과.
- [ ] `wc -l lib/keeper/keeper_agent_run.ml` 감소 ≥ 30 LOC.
- [ ] `gh pr ready` 전 *Best Programmer self-review* 수행.

### 6.2 Phase 완료 정의

- *Active*: PR-1 머지 후 status 갱신.
- *Partially Implemented*: PR-1~PR-3 머지 + Step 8 body 감소 ≥ 200 LOC.
- *Implemented*: PR-1~PR-9 머지 (또는 동등 효과) + Step 8 body LOC < 600 (orchestrator only).

본 RFC 의 `implementation_prs` frontmatter 에 머지 PR 번호 append.

---

## 7. References

- [RFC-0136](RFC-0136-keeper-unified-turn-decomposition.md) — `keeper_unified_turn` decomposition (자매 RFC, Active).
- [RFC-0136 Phase 4 sub-doc](RFC-0136-phase-4-retry-loop.md) — retry_loop body 측정 + PR-4-d/e 보류 결정 (학습).
- [RFC-0051](RFC-0051-run-named-closure-decomposition.md) — `run_named` closure decomposition (parallel, draft).
- [RFC-0056](RFC-0056-incremental-sub-library-extraction.md) — Sub-library extraction patterns.
- `lib/keeper/keeper_agent_run.ml` — 2103 LOC, `run_turn` mega-function.
- `lib/keeper/keeper_agent_run.mli` — 346 LOC.
- `scripts/lint/godfile-size-regression.sh` — cap 3350 LOC.
- `~/me/planning/claude-plans/joyful-tumbling-dragon.md` — Phase 5 godfile target.
