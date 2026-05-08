---
status: reference
last_verified: 2026-04-17
code_refs:
  - lib/keeper/keeper_decision_audit.ml
  - lib/server/
  - dashboard/src/
---

# Dashboard FSM Visibility Redesign

**Status**: Design (기획 단계)
**Date**: 2026-04-14
**Scope**: `masc-mcp` 대시보드의 FSM/TLA 정보 아키텍처 재구성 + 데이터 파이프라인 dynamic화
**One sentence**: Keeper detail 한 페이지에 갇혀 있고 Cascade/Decision 그래프가 하드코딩된 현 대시보드를, RFC-0003 composite observer를 소스로 삼는 4-페이지 체계로 재구성한다.

## Related Documents

- `docs/rfc/RFC-0003-keeper-composite-lifecycle.md` — 본 plan의 데이터 계약(composite observer + payload shape)
- `docs/rfc/RFC-0002-keeper-state-machine.md` — 11-state parent phase FSM
- `specs/keeper-state-machine/KeeperCompositeLifecycle.tla` — 5 joint invariants + 3 bug models
- `docs/tla-audit/state-fsm-gap-2026-04-13.md` — Bug #1, P1~P5 제안

## 1. 현 상태 분석

### 가시성

| 페이지 | FSM 위젯 | 출처 |
|--------|----------|------|
| `dashboard/src/components/keeper-detail.ts:509` | parent phase diagram + Decision FSM + Cascade FSM | `keeper-state-diagram.ts` |
| `dashboard/src/components/agent-detail.ts` | **없음** | — |
| Overview / home | **없음** | — |
| 통합 감사 뷰 | **없음** (존재하지 않음) | — |

### Cascade 하드코딩

`lib/keeper/keeper_decision_audit.ml:256-315` `cascade_fsm_to_mermaid`는 state name, edge label, fallback 조건을 문자열 리터럴로 고정 출력한다. 결과적으로:

- `local_recovery` 와 `keeper_unified` profile이 **같은 그림**으로 표시된다.
- provider health (healthy/unhealthy/slot_full)는 렌더에 반영되지 않는다.
- `last_provider_result`가 success든 timeout이든 edge 색이 동일하다.

동시에 model 목록은 `lib/server/server_routes_http_routes_dashboard.ml:618-633`에서 `Oas_worker_named.default_model_strings`로부터 동적으로 읽는다. 즉 **데이터는 흐르는데 렌더가 그것을 쓰지 않는다.**

### Decision FSM 부분 동적

`keeper_decision_audit.mli:55-73` `decision_pipeline_to_mermaid`는 `phase`, `thompson_alpha`, `thompson_beta`만 bind한다. `KeeperDecisionPipeline.tla` state variable 중 `tool_count`, `guard_penalties_this_cycle`, `turn_outcome`은 surfaces에 없다.

### Memory/Compaction 부재

`keeper_memory_policy.ml:447-451` `kind_caps`(`constraints:2, decision:2, next:2, goal:2, progress:2, open_question:2, long_term:4`)와 `keeper_memory_bank.ml`의 compaction snapshot, `tool_compact.ml:24-26` strategy enum은 **어떤 대시보드 페이지에도 표시되지 않는다.**

## 2. 정보 아키텍처 (후속 구현의 기준)

| 페이지 | FSM surface | 근거 | 신규 여부 |
|--------|------------|------|-----------|
| `/overview` (기존) | fleet-wide phase histogram + compaction/handoff 카운터 + composite invariants 전체 통과율 | 매크로 상태 한눈 | 확장 |
| `/keepers/:name` (기존) | parent phase diagram + Decision FSM + Cascade FSM + Memory tier panel + Compaction sub-FSM | 운영자 콘솔 심화 | 확장 |
| `/agents/:id` (기존) | **mini phase-strip**만 (해당 agent에 연결된 keeper로 링크) | MASC agent ≠ OAS keeper 경계 존중 | 최소 추가 |
| `/fsm` (신규) | Keeper picker + composite Cytoscape compound graph + 5 invariants panel + event log (composite.tick SSE 구독) | 아키텍처 감사/엔지니어링용 | **신규** |

### 왜 `/fsm`을 분리하는가

`/keepers/:name`은 특정 keeper의 **운영**을 위한 페이지다. 운영자는 pause/resume, logs, last turn을 본다. 이 페이지에 composite FSM 다이어그램을 끼워넣으면 스크롤이 길어지고 맥락이 섞인다. 반면 `/fsm`은 "이 시스템의 상태 머신들이 spec과 일치하는가"를 감사하는 페이지다. 유입 경로와 대상 사용자가 다르다.

### 왜 `/agents/:id`는 mini strip만

MASC `agent`와 OAS `keeper`는 다른 개념이다 (`docs/design/oas-masc-state-boundary.md`). agent detail에 keeper composite FSM 전체를 복제하면 layer boundary를 흐린다. 대신 "이 agent가 연결된 keeper의 현재 parent phase"만 작은 strip으로 보이고 클릭 시 `/keepers/:name`으로 이동.

## 3. Cascade 하드코딩 제거 경로

### 수정 대상

| 파일 | 라인 | 변경 |
|------|------|------|
| `lib/keeper/keeper_decision_audit.ml` | 256-315 | `cascade_fsm_to_mermaid` state set을 `CascadeLiveness.tla`의 `{idle, selecting, trying, done, exhausted}` subset으로 제한. 렌더 시점에 받은 실제 profile name, provider health list, last_provider_result로 label/색 bind |
| `lib/keeper/keeper_decision_audit.mli` | 55-73 | 시그니처 확장 (optional labelled args): `?provider_health:(string * [`Healthy|`Unhealthy|`SlotFull|`Unknown]) list`, `?slot_state:int * int`, `?effective_cascade_reason:string` |
| `lib/server/server_routes_http_routes_dashboard.ml` | 618-633 | 기존 `Oas_worker_named.default_model_strings` 호출 유지, `Keeper_cascade_routing.select_cascade` 결과와 `Keeper_exec_status_metrics.last_model_used`를 함께 넘긴다 |
| `lib/dashboard/dashboard_http_keeper.ml` | 147-148 | 이미 phase-aware cascade 리졸브 로직 보유 — `effective_cascade_reason` 노출 경로만 추가 |

### 재사용할 기존 함수 (새 추상화 금지)

- `Keeper_cascade_routing.select_cascade` — phase→cascade 매핑 (`lib/keeper/keeper_cascade_routing.mli`)
- `Cascade_runtime.models_of_cascade_name` — cascade 이름 → provider list
- `Provider_adapter.is_local_provider` — provider 분류
- `Keeper_exec_status_metrics.last_model_used` — 마지막 사용 provider
- `Local_runtime_pool` slot telemetry — slot full 판정

MASC 레벨에 새 provider/model 이름이 등장하지 않도록 주의. 값은 OAS가 내려 보낸 opaque 문자열로 대시보드에 전달한다 (`feedback_masc-model-agnostic.md`).

### 출력 불변성

`cascade_fsm_to_mermaid`가 생성하는 state id는 반드시 `CascadeLiveness.tla`의 state 집합 subset. CI에 파일 파싱 단계를 추가해 임의 문자열 유입을 차단한다. Property-based test는 Phase 2의 TLC 통과 여부와 함께 실행한다.

## 4. Decision FSM Dynamic 확장

| 현재 bind | 확장 bind | 출처 |
|-----------|----------|------|
| `phase`, `thompson_alpha`, `thompson_beta` | `+ guard_penalty_this_cycle`, `tool_policy_mode`, `turn_outcome` | `KeeperDecisionPipeline.tla` state variables |

`keeper_decision_audit.mli:58-64` 시그니처에 optional labelled args 세 개 추가 (`?guard_penalty_this_cycle:int`, `?tool_policy_mode:[\`Preset of string | \`Custom]`, `?turn_outcome:[\`Ok | \`Failed | \`Blocked]`). default는 `None`이고, None이면 "n/a"로 렌더. 이 방식은 caller가 점진 채택 가능하므로 후방 호환성을 깨지 않는다.

Mermaid `note right of Running` 블록에 세 필드를 한 줄씩 추가한다. Thompson alpha/beta와 나란히.

## 5. Memory Tier Panel + Compaction Sub-FSM

### 신규 컴포넌트

`dashboard/src/components/keeper-memory-tier-panel.ts` 신규. `kind_caps` 7종(`constraints:2, decision:2, next:2, goal:2, progress:2, open_question:2, long_term:4`)을 7개의 vertical bar로 시각화. 각 bar는 `(used/cap)`, `importance_weight`(keeper_memory_policy.ml:401-403)를 tooltip으로 보여준다.

### 백엔드 필드

`/state-diagram` 응답(`server_dashboard_http_keeper_api.ml`)에 다음 필드 추가:

```json
"memory_kind_usage": [
  { "kind": "constraints", "used": 1, "cap": 2 },
  { "kind": "decision",    "used": 2, "cap": 2 },
  { "kind": "progress",    "used": 0, "cap": 2 }
  // ...
]
```

소스: `Keeper_memory_bank` snapshot에서 kind별 count. 기존 `memory_kind_caps_for_compaction` 헬퍼 재사용.

### Compaction sub-FSM

- 렌더 조건: parent `phase=Compacting`일 때만.
- State set: `MemoryCompaction.tla`의 `{accumulating, compacting, done}`.
- Bind: `Keeper_registry.get_conditions`에서 `compaction_active`, `last_compaction_strategy` 읽기.
- Strategy 이력: `tool_compact.ml:24-26`의 `{prune_tool_outputs | merge_contiguous | drop_low_importance | summarize_old | all}` 중 최근 N개를 기존 `keeper_decision_audit` ring buffer에 **compaction record variant로 얹음** (신규 ring buffer 추가 금지, `feedback_no-derived-tag-when-existing-identifier-suffices.md`).

## 6. API / Cache / Live Updates

### 신규 SSE endpoint

`lib/server/server_routes_http_keeper_stream.ml`에 `/api/v1/keepers/:name/state-diagram/stream` 추가. 기존 SSE 인프라 재사용.

### Cache 재정의

`lib/server/server_dashboard_http_cache.ml`의 기존 캐시는 cold load용으로만 두고, **값의 권위는 SSE 스트림의 last_emitted로 옮긴다**. 단일 writer는 `Keeper_event_bus` 핸들러. 이중 source-of-truth가 생기지 않는다.

### Composite endpoint

`/api/keepers/:name/composite` 신규. payload shape는 RFC-0003 §7에 정의. OAS event_bus envelope(`{correlation_id, run_id, ts}`, OAS PR#845)를 필수 필드로 포함. SSE 토픽: `keeper.composite.tick`.

## 7. Phase 분할 (독립 PR)

| Phase | 산출물 | 의존 | 독립 PR 단위 |
|-------|--------|------|------------|
| **1a** | Cascade 하드코딩 제거 + 시그니처 확장 + `cascade_fsm_to_mermaid` state set 제한 | — | 1 PR |
| **1b** | Decision FSM dynamic 필드 확장 | — | 1 PR |
| **1c** | `/agents/:id` mini phase-strip (기존 `keeper-phase-strip.ts` 재사용) | — | 1 PR |
| **2** | Memory tier panel + Compaction sub-FSM + `memory_kind_usage` 필드 | — | 1 PR |
| **3** | `/fsm` hub 페이지 (composite Cytoscape + invariants panel + event log) | RFC-0003 OCaml observer 구현 선행 | 1 PR |
| **4** | SSE stream endpoint + EventSource client + cache 강등 | Phase 3 shape 안정화 | 1 PR |

Phase 1a/1b/1c는 서로 직교하므로 **병렬 가능**. Phase 2는 1과 독립. Phase 3은 RFC-0003 observer 모듈(Phase 3 별도 구현 PR)이 머지된 이후.

## 8. 검증 전략

### 단위

- OCaml alcotest: 각 신규/수정된 mermaid builder에 대해 golden output per phase. phase 개수 × cascade profile 개수 조합.
- Frontend: composite panel 렌더링은 Tailwind-only (`feedback_tailwind-only-dashboard.md`), snapshot test로 DOM 구조 고정.

### 속성 (Property-based)

- 생성된 mermaid state id ⊆ 해당 TLA+ spec의 state 집합. spec 파일을 파싱해 state literal 추출 후 intersection 체크.
- `memory_kind_usage` 응답의 kind 집합 ⊆ `keeper_memory_policy.ml` `kind_caps` 키 집합.

### E2E (Playwright)

- 시나리오 A — Failing 전이: `masc_keeper_reset`으로 Failing 강제 → cascade 그래프에 `local_recovery` 노출 확인, provider health bar 변경 확인.
- 시나리오 B — Compaction: context ratio로 compaction 트리거 → sub-FSM `compacting` 렌더 확인 → `done` 전이 후 parent phase `Running` 복귀 확인.
- 시나리오 C — Invariants violation: live composite contract drift. 예: `Compacting`인데 turn phase가 `compacting`이 아니거나, measurement 없이 cascade가 `trying`으로 진입한 경우를 fixture/API stub로 재현한다.

### CI gate

- Phase 2에서 TLC를 4 cfg 모두 실행: clean 통과 + buggy 3개가 각자 다른 invariant 위반 확인. 하나라도 어긋나면 merge 차단.
- Composite mermaid state-id diff 검사 (spec state 집합 ↔ 런타임 방출 집합).

## 9. Risks / Trade-offs

| Risk | 완화 |
|------|------|
| `keeper_decision_audit.mli` 시그니처 확장이 외부 소비자(테스트, 다른 모듈, 다른 서비스)에 파급 | optional labelled args + 기본값 `None` + deprecation note 주석. 한 번에 caller 전환하지 않아도 됨 |
| SSE stream + 기존 cache 이중 source-of-truth | cache를 stream의 `last_emitted` 값 저장소로 강등. 단일 writer = event_bus handler |
| `/fsm` 페이지가 "또 하나의 감사 UI"로 방치될 위험 | Phase 3 PR에 운영자 README 섹션 추가: 어떤 invariant violation이 발생하면 어떤 페이지를 본다 |
| Composite snapshot이 turn 경계에서 stale | `composite_view`를 Lazy로 두고 매 read마다 재계산. SSE `ts` 필드를 필수 |
| Tailwind-only 제약 vs Cytoscape 사용 | Cytoscape는 자체 canvas라 Tailwind class와 직접 충돌 없음. 컨테이너 레벨만 Tailwind |
| 신규 페이지 추가로 라우팅 복잡도↑ | 기존 router를 재사용(신규 라우팅 라이브러리 금지), sidebar에 `/fsm` 링크 하나만 추가 |

## 10. Non-goals

- RFC-0003의 OCaml observer 구현 (별도 PR, `feature/composite-observer`)
- P1(`TurnSucceeded` spec divergence) 수정 — `KeeperStateMachine.tla` 국소 수정이며 본 plan과 직교
- Fleet-wide composite 뷰(여러 keeper의 composite를 한 번에 비교) — Phase 4 이후로 연기
- 기존 Keeper detail의 운영자용 섹션 재배치 — 본 plan은 **FSM 가시성**만 다룬다

## 11. Open Questions

1. `/fsm` 페이지에서 Keeper picker를 **URL segment**(`/fsm/:name`)로 둘지 query param으로 둘지. URL segment가 공유/북마크에 유리하지만 라우팅 변경 필요.
2. Invariants panel에서 위반 알림을 어떤 채널로 escalate할 것인가 — 대시보드 내 배지로만 둘지, Slack webhook까지 연계할지 (RFC-0003 Open Question §3과 동일).
3. Memory tier panel에서 kind cap 초과 임박(used == cap-1)을 주황색으로 표시할지, 초과 직후(used >= cap)에만 표시할지.
