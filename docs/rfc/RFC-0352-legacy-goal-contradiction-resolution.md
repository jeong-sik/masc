# RFC-0352 — Legacy Goal: RFC-0000 §3.2 ↔ §3.15 자기모순 해소 (결정 요청)

- Status: **Accepted — Path B (오너 결정 2026-07-21)**
- Decision: §4의 1문항에 오너가 **(a) Goal은 1급 엔티티** 로 답함 → Path B 채택. RFC-0000 §3.2 카드 재작성·§11 D10 DECIDED 처리는 본 RFC와 같은 PR에서 집행됨.
- Date: 2026-07-21
- Evidence: 2026-07-21 dead-surface 적대적 감사 (`~/me/reports/masc-oas-dead-surface-adversarial-audit-2026-07-21.md`, 판정 4건: `retired/legacy-goal-*` 전부 **ALIVE**, `spec-map/goal-loop-spec-self-conflict` **ALIVE**)
- Blocks: goal 일가족 정리 (감사 Tier B 최대 항목, 합계 ~13k LoC 규모)
- Non-blocking: goal_loop 스크립트 10개+Python 테스트 8개(4,844 LoC)는 **어느 결정과도 양립하는 삭제**라 본 RFC와 무관하게 진행 가능 (RFC-0000:781 KILL 행, 자동 호출자 0 확인)

## 1. 모순 (사실 관계, 전부 fresh-read 검증됨)

RFC-0000이 같은 문서 안에서 Goal에 대해 상반된 두 지시를 내린다.

**§3.2 (line 232-237) — "Legacy Goal — RETIRED / HARD DELETE":**
> 삭제 범위: `lib/goal` runtime, workspace/keeper legacy goal field와 decode path, goal-loop dashboard/scripts/tests, migration/backfill/compatibility row.
> acceptance: production·fixture·dashboard에서 Legacy Goal dependency 0. 옛 persisted goal row를 읽기 위한 migration 없음.

**§3.15 (line 403) — active_goal_ids 축 표:**
> Goal **엔티티**는 `goal_store.ml` SSOT — **YES(TOML)** 판정, 위험 "낮음"

즉 §3.2는 `lib/goal`을 죽이라 하고, §3.15는 `goal_store.ml`을 살아있는 SSOT로 선언한다.

**라이브 상태 (감사 verify 에이전트가 반증 시도 후 확정):**

| 표면 | 상태 |
|---|---|
| `lib/goal` (goal_store/goal_phase FSM, 1,044 LoC) | production dune 6곳 링크 (lib/dune:271, tool_schemas, operator, server, dashboard, task) |
| MCP tools `masc_goal_list/upsert/transition` | 라이브 디스패치 (`tool_workspace.ml:677-679`, `mcp_server_eio_execute.ml:313` 경유; keeper in-process 경로 `keeper_tag_dispatch.ml:121-122`) |
| legacy-status 호환 decode | `goal_store.ml:2-3,136-165,499` — **§3.2 acceptance가 명시적으로 금지하는 바로 그것** |
| dashboard/서버 goal-loop 표면 (~7,400 LoC) | `server_runtime_bootstrap.ml:1374`가 refresh loop를 production boot에서 시작; `/api/v1/dashboard/goal-loop/status` + `/goals` 라우트 라이브 |
| keeper meta `active_goal_ids` | `keeper_meta_contract.ml:373` typed 필드, ~60 lib 파일 157건 참조 |
| 전제 RFC | RFC-0111(goal-mint-atomicity)·RFC-0067(goal-scope-observation)·RFC-0267(task-goal-linkage)이 goal 런타임 존재를 전제 |
| 제품 스펙 | "Goal/Task — 약한 결합" 기능이 현행 스펙에 존재 |

git 이력: 2026-07-08 이후 `lib/goal`·goal-loop 표면의 커밋은 전부 pass-through refactor (#24332, #23902, #23845, #23710, #23716) — 의도적 재투자도, 의도적 철거도 없음. **문서만 죽었고 코드는 방치-생존 중.**

## 2. 왜 지금 결정이 필요한가

1. **감사 집행 차단**: dead-surface 감사의 최대 잔여 항목(Tier B)이 이 결정에 게이트되어 있다.
2. **재도입 사고 전례**: 문서와 코드가 어긋난 상태를 방치하면 어느 쪽이든 "고치는" 에이전트가 나타난다 (#24890→#25281 재도입 사고, `category_valid_until` 역-drift 사례). §3.2를 읽은 에이전트는 삭제 PR을, §3.15를 읽은 에이전트는 goal 기능 확장 PR을 쓴다 — **둘 다 이미 가능한 상태**다.
3. **acceptance 위반 상시화**: §3.2 acceptance("legacy decode 없음")는 현재 매일 위반되고 있다. 지켜지지 않는 acceptance는 로드맵 신뢰도를 갉아먹는다.

## 3. 선택지 (트레이드오프)

### Path A — §3.2 집행: Legacy Goal 일가족 은퇴

- **작업**: MCP tool 3종 + tool schema + dispatch 행 제거 → dashboard/서버 goal-loop 표면 제거 → `active_goal_ids` decode path 제거(~60파일) → `lib/goal` 삭제 + dune 6곳 → RFC-0111/0067/0267 Superseded 처리. 스택 PR 4~6개, 예상 순삭제 ~13k LoC.
- **장점**: 로드맵 §3.2·Non-Goals(AutoGPT식 goal-decomposition 거부)와 정합. 유지보수 표면 대폭 축소. keeper meta 계약 단순화.
- **단점/리스크**: 제품 스펙의 "Goal/Task 약한 결합"을 재해석해야 함 — Task 단독으로 충분한지 오너 판단 필요. `workspace_goal_index.ml`(RFC-0267 goal→task 투영)의 재배치 또는 동반 삭제. 퇴역 데이터(persisted goal rows)는 acceptance대로 migration 없이 버려짐.
- **전제 갱신 문서**: RFC-0000 §3.15 표에서 goal 행 제거, §3.2 acceptance를 done으로, RFC-0111/0067/0267 Superseded, sse_event goal_loop 이벤트 타입(RFC-0291 closed sum), docs/GOAL-LOOP-* 2종, DASHBOARD-INTEGRATION.md, README(+ko) 로드맵 행.

### Path B — §3.2 개정: 현 Goal을 인정하고 legacy 기계만 절제 **[채택됨]**

- **작업**: §3.2를 "Legacy goal-FSM 기계(stagnation counter, goal-loop OODA scheduler/status, legacy-status decode)만 RETIRED, Goal 엔티티+MCP tool+task 링키지는 KEEP"으로 재작성. legacy decode(`goal_store.ml:136-165`)를 typed 마이그레이션으로 정리하거나 명시 보존 결정. goal-loop dashboard 표면은 별도 keep/kill 판정.
- **경계선 (모순 재발 방지의 핵심 — §1.3 Non-Goals와의 선)**:
  - **KEEP = 엔티티와 수동 경로**: `goal_store.ml` SSOT(CRUD/persist), `goal_phase.ml` FSM 타입과 전이 검증(Keeper가 `masc_goal_transition` tool로 **수동** 전이하는 경로에서만 소비), MCP tool 3종 디스패치, `workspace_goal_index.ml`(RFC-0267 goal→task 투영), keeper meta `active_goal_ids` typed 필드, dashboard `/goals` 엔티티 조회.
  - **RETIRE = 자율 기계**: 서버 부트가 시작하는 goal-loop refresh loop(`server_runtime_bootstrap.ml`), `/api/v1/dashboard/goal-loop/status` 라우트와 broadcast 표면, stagnation counter, OODA 주기 판정 — 즉 **사람/Keeper의 tool 호출 없이 Goal 상태를 읽고 행동을 유발하는 모든 경로**. goal_loop 스크립트 계층은 이미 삭제(#25477).
  - **판별 규칙**: 새 코드가 Goal을 "tool 호출의 인자/결과"로 다루면 KEEP 측, "스케줄러/루프의 입력"으로 다루면 RETIRE 측이다. 이 규칙이 §1.3 Non-Goals(AutoGPT식 goal-decomposition 차단)의 집행 형태다.
- **절제 슬라이스 (구현 PR 순서)**: 1) legacy-status decode 정리(typed 마이그레이션 or 명시 보존 — persisted row 실측 후 결정) 2) goal-loop server refresh loop + status 라우트 + broadcast 3) dashboard goal-loop 표면(엔티티 `/goals` 조회는 잔류). 각 슬라이스는 착수 시점 fresh grep으로 라인 재검증(본 RFC의 줄 번호는 2026-07-21 기준).
- **장점**: 제품 스펙 "Goal/Task" 기능과 정합. 라이브 MCP tool 사용자(keeper) 무중단. 작업량 소(문서 개정 + decode 정리).
- **단점/리스크**: §1.3 Non-Goals("AutoGPT식 goal-decomposition 차단")와의 경계를 다시 그어야 함 — "어디까지가 legacy FSM이고 어디부터가 살아있는 Goal인가"의 선을 이 RFC에서 명문화하지 않으면 모순이 형태만 바꿔 재발. goal-loop dashboard ~7.4k LoC의 거취가 여전히 미정.
- **전제 갱신 문서**: RFC-0000 §3.2 재작성, §3.15 goal 행에 "KEEP 확정" 주석, goal-loop 표면 판정 추가.

### 판정 보류 시 (현상 유지)

모순 상시화 + 양방향 재도입/삭제 사고 리스크 지속. **권장하지 않음.**

## 4. 결정 요청 (답변됨)

오너가 다음 1문항에 답하면 나머지는 기계적으로 집행 가능하다 — **2026-07-21 (a)로 결정됨**:

> **제품 스펙의 "Goal/Task 약한 결합"에서 Goal은 (a) 독립 엔티티로 유지해야 하는 1급 개념인가, (b) Task로 흡수 가능한 잔재인가?**

- (a) → **Path B**: 본 RFC를 §3.2 개정안으로 확장하고, legacy FSM/decode/goal-loop 표면의 절제 범위를 확정한다.
- (b) → **Path A**: 스택 PR 시퀀스를 시작한다 (1: MCP tool 표면, 2: dashboard/서버 표면, 3: keeper meta decode, 4: lib/goal + RFC supersede).

## 5. 이 RFC와 무관하게 즉시 가능한 것 (이미 진행)

- goal_loop **스크립트/Python 테스트** 삭제(4,844 LoC): RFC-0000:781이 이미 KILL 명시("revival 금지"), 자동 호출자 0, 양 Path 모두에서 죽음 — 감사 PR 시리즈에서 별도 진행.
