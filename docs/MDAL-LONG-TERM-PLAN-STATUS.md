# MDAL 및 장기계획 상태 및 자율 판단 경계

| 항목 | 값 |
|------|-----|
| Status | Active |
| Team | Foundation |
| 관련 문서 | [MDAL.md](./MDAL.md), [COMMAND-PLANE-RUNBOOK.md](./COMMAND-PLANE-RUNBOOK.md), [spec/06-command-plane.md](./spec/06-command-plane.md) |
| 작성일 | 2026-03-30 |

---

## 1. 개요

이 문서는 MASC-MCP에서 MDAL(Metric-Driven Agent Loop)과 장기계획(Command Plane V2) 기능이 어떻게 시작되고 멈추는지, 그리고 어떤 자율 판단 경계를 가지는지를 명확히 정의한다.

**핵심 질문에 대한 답변**:
1. **현재 왜 멈춰있는가?** → 명시적 시작 없이는 실행되지 않음 (기본값: 비활성)
2. **어떤 자율 판단하에 시작되는가?** → 명시적 MCP 툴 호출 또는 HTTP API 요청 필요
3. **자율 판단 경계는?** → Profile/Policy Envelope로 정의된 제약 조건 내에서만 자율 실행

---

## 2. MDAL (Metric-Driven Agent Loop)

### 2.1. 현재 상태: 왜 멈춰있는가?

**MDAL은 기본적으로 실행되지 않는다.** 다음 조건이 모두 충족되어야 시작된다:

1. **명시적 시작 요청**: `masc_mdal_start` MCP 툴 호출 또는 `POST /api/v1/mdal/loops/start` HTTP 요청
2. **유효한 Profile**: 측정 가능한 `metric_fn`, 달성 가능한 `goal`, 실행 가능한 `agent` 지정
3. **Runtime 가용성**: Team Session 또는 Worker Spawn 엔진이 사용 가능한 상태

**멈춰있는 이유**:
- **설계 원칙**: MDAL은 자동 시작되지 않는다 (opt-in 철학)
- **안전성**: 무한 루프 방지, 리소스 소비 제어
- **명시성**: 측정 가능한 목표가 있을 때만 사용해야 함

### 2.2. 시작 조건 및 자율 판단 경계

#### 시작 경로

**A. MCP 툴 경로** (주요 경로)
```ocaml
masc_mdal_start {
  profile: "custom",
  metric_fn: "python3 scripts/score.py",
  goal: "metric >= 0.90",
  target: "Evaluator score >= 0.90",
  agent: "claude:opus",
  max_iterations: 8,
  stagnation_threshold: 0.01,
  stagnation_count: 3,
  tools_allow: ["masc_spawn", "masc_code_*", "masc_worktree_*"]
}
```

**B. HTTP API 경로**
```http
POST /api/v1/mdal/loops/start
Content-Type: application/json

{
  "profile": "coverage",
  "metric_fn": "./scripts/coverage_percent.sh",
  "target": "Test coverage >= 80%",
  "max_iterations": 10
}
```

**C. Dashboard UI 경로**
- Dashboard → MDAL 섹션 → "Start New Loop" 버튼
- 내부적으로 HTTP API 호출

#### 자율 판단 경계 (Profile 제약)

MDAL Loop가 시작되면 다음 제약 조건 내에서 **자율적으로 반복**한다:

| 제약 조건 | 설명 | 예시 |
|----------|------|------|
| **goal** | 목표 메트릭 도달 시 자동 종료 | `metric >= 0.95` |
| **max_iterations** | 최대 반복 횟수 | `10` |
| **max_time_seconds** | 최대 실행 시간 (초) | `3600` (1시간) |
| **stagnation_threshold** | 진전으로 인정되는 최소 delta | `0.01` |
| **stagnation_count** | 연속 정체 허용 횟수 | `3` |
| **tools_allow** | 허용된 툴 목록 (엄격히 적용) | `["masc_spawn", "masc_code_*"]` |
| **tools_deny** | 금지된 툴 목록 | `["masc_destructive_*"]` |

**자율 판단 시나리오**:
1. **목표 달성**: `metric >= goal` → 자동 `Completed`
2. **반복 한계**: `current_iteration >= max_iterations` → 자동 `Stopped` (stop_reason: "max_iterations_reached")
3. **시간 초과**: `elapsed_time >= max_time_seconds` → 자동 `Stopped` (stop_reason: "time_limit_exceeded")
4. **정체 판단**: `stagnation_streak >= stagnation_count` → 자동 `Stopped` (stop_reason: "stagnation_limit_reached")
5. **에러 발생**: Worker 실패, metric 측정 실패 → 자동 `Error`

**명시적 개입 필요**:
- **시작**: 절대 자동 시작되지 않음
- **중단**: `masc_mdal_stop` 또는 `POST /api/v1/mdal/loops/stop`
- **재개**: `Interrupted` 상태의 Loop는 `masc_mdal_iterate`로 재개 가능

### 2.3. Loop 생명주기 상태 전이

```
[Not Started] → (masc_mdal_start) → [Running]
                                          ↓
                                     (iterate)
                                          ↓
                    ┌─────────────────────┴─────────────────────┐
                    ↓                     ↓                     ↓
              [Completed]            [Stopped]               [Error]
              (goal met)          (limits/stagnation)     (failure)
                    ↑                     ↑                     ↑
                    └─────────────────────┴─────────────────────┘
                              (masc_mdal_stop)

[Running] → (server restart) → [Interrupted] → (masc_mdal_iterate) → [Running]
```

**Terminal 상태**: `Completed`, `Stopped`, `Error` → 재개 불가
**Recoverable 상태**: `Running`, `Interrupted` → 재개 가능

### 2.4. Strict Mode 및 Evidence 요구사항

**Strict Mode** (`strict_mode: true`):
- **Worker 필수 사용**: 각 iteration에서 worker agent가 auditable tool 사용
- **Evidence 검증**: 최소 1개 이상의 auditable tool call 필요
- **Tool Call 추적**: `tool_call_count`, `tool_names`, `session_id` 기록
- **Verification Status**: `Verified` 또는 `Legacy_unverified`

**Auditable Tools 목록**:
- `masc_spawn` - 구현 에이전트 생성
- `masc_code_*` - 코드 읽기/쓰기/검색
- `masc_worktree_*` - 워크트리 조작
- `masc_run_*` - 실행 및 테스트

**Evidence 부족 시**: Loop가 `Interrupted` + `worker_evidence_missing`로 종료

### 2.5. Persistence 및 Recovery

**저장 위치**:
- **FileSystem**: `.masc/mdal/*.json` (loop별 파일 + `latest.json`)
- **PostgreSQL**: Backend KV store
- **Memory**: 임시 (재시작 시 소멸)

**Recovery 규칙**:
1. 서버 재시작 시 `Running` loop → `Interrupted`로 자동 정규화
2. `Interrupted` loop는 `masc_mdal_iterate`로 재개 가능
3. Board/SSE는 관측용, SSOT는 backend store

---

## 3. Command Plane V2 (장기계획)

### 3.1. 현재 상태: 왜 멈춰있는가?

**Command Plane V2는 기본적으로 비활성 상태이다.** 다음이 필요하다:

1. **명시적 Unit 생성**: `masc_unit_create` 또는 자동 생성된 `company-runtime`
2. **명시적 Operation 시작**: `masc_operation_start`
3. **Dispatch 및 할당**: `masc_dispatch_assign` 또는 `masc_dispatch_plan`

**멈춰있는 이유**:
- **설계 원칙**: 조직 구조는 명시적으로 정의되어야 함
- **안전성**: 무단 리소스 할당 방지
- **거버넌스**: Policy 승인이 필요한 작업 존재

### 3.2. 조직 구조 (Unit Hierarchy)

```
Company (strategic)
  └─ Platoon (tactical)
      └─ Squad (execution)
          └─ Agent_unit (worker)
```

**자동 생성 규칙**:
- **company-runtime**: Managed unit이 없거나 root가 여러 개일 때 자동 생성
- **squad-unassigned**: 할당되지 않은 live agent를 위한 기본 Squad

**생성 방법**:
```json
{
  "tool": "masc_unit_create",
  "arguments": {
    "kind": "squad",
    "label": "backend-team",
    "parent_unit_id": "platoon-engineering-001",
    "leader_id": "agent-123",
    "roster": ["agent-123", "agent-456"],
    "capability_profile": ["runtime:ocaml", "tool:code_write"]
  }
}
```

### 3.3. Operation 생명주기 및 자율 판단 경계

#### Operation 상태 전이

```
[Not Created] → (masc_operation_start) → [Planned] → (dispatch_assign) → [Active]
                                                                              ↓
                                          (masc_operation_pause) ← ─ ─ ─ ─ ─ ┘
                                                    ↓
                                          (masc_operation_resume) → [Active]
                                                    ↓
                    ┌───────────────────────────────┴───────────────────────────┐
                    ↓                               ↓                           ↓
              [Completed]                      [Failed]                   [Cancelled]
          (masc_operation_finalize)     (masc_operation_finalize)    (masc_operation_stop)
```

#### 자율 판단 경계 (Policy Envelope)

각 Unit은 **Policy Envelope**로 자율성 범위를 정의한다:

```ocaml
type policy_envelope = {
  policy_class : string;           (* strategic | tactical | execution | worker *)
  approval_class : string;         (* strict | guarded *)
  tool_allowlist : string list;    (* 허용된 툴 목록 *)
  model_allowlist : string list;   (* 허용된 모델 목록 *)
  requires_human_for : string list;(* 승인 필요한 작업 *)
  autonomy_level : string;         (* L2_Suggestive ~ L5_Independent *)
  escalation_timeout_sec : int;    (* 승인 대기 timeout *)
  kill_switch : bool;              (* true = 완전 비활성화 *)
  frozen : bool;                   (* true = 신규 dispatch 거부 *)
}
```

**Unit Kind별 기본 Policy**:

| Unit Kind | Policy Class | Approval Class | requires_human_for | Escalation Timeout |
|-----------|-------------|----------------|-------------------|-------------------|
| Company | strategic | strict | `cross_platoon_rebalance`, `budget_class_change`, `kill_switch` | 1800s (30분) |
| Platoon | tactical | strict | `cross_squad_rebalance`, `budget_burst` | 1200s (20분) |
| Squad | execution | guarded | `destructive_tool`, `cross_squad_escalation` | 900s (15분) |
| Agent_unit | worker | guarded | `destructive_tool` | 600s (10분) |

#### 승인 필요한 작업 (Policy Decision)

다음 작업은 **Policy Decision Queue**를 거쳐야 한다:

1. **cross_platoon_rebalance**: Platoon 간 Operation 이동
2. **cross_squad_rebalance**: Squad 간 Operation 이동
3. **budget_burst**: 예산 한도 초과
4. **budget_class_change**: 예산 등급 변경
5. **kill_switch**: Unit 완전 비활성화
6. **policy_freeze_unit**: Unit Freeze 토글
7. **destructive_tool**: 파괴적 툴 사용

**승인 프로세스**:
```
Agent 작업 요청
  ↓
Policy Envelope 확인: requires_human_for 포함?
  ↓ (Yes)
Policy Decision 생성 (status: pending)
  ↓
Human 승인/거부 대기 (escalation_timeout_sec)
  ↓
Timeout 시 → 상위 Unit으로 자동 escalate
  ↓
Approved → 작업 실행
Denied → 작업 거부
```

**MCP 툴**:
```json
{
  "tool": "masc_policy_approve",
  "arguments": {
    "decision_id": "decision-1234",
    "reason": "Approved after review"
  }
}
```

```json
{
  "tool": "masc_policy_deny",
  "arguments": {
    "decision_id": "decision-1234",
    "reason": "Insufficient justification"
  }
}
```

### 3.4. 자율 실행 경계 (Autonomy Levels)

| Level | 이름 | 설명 | 적용 Unit |
|-------|------|------|-----------|
| L2 | Suggestive | 제안만 가능, 실행 불가 | Agent_unit (default) |
| L3 | Guided | 승인된 범위 내에서 제한적 실행 | Squad (default) |
| L4 | Autonomous | 대부분 작업 자율 실행, 위험 작업만 승인 | Platoon (default) |
| L5 | Independent | 거의 모든 작업 자율 실행, kill_switch만 승인 | Company (default) |

**자율 판단 시나리오**:
1. **Tool Allowlist 체크**: `tool in tool_allowlist` → 자동 허용
2. **Budget 체크**: `cost <= max_cost_usd` → 자동 허용
3. **Headcount 체크**: `roster.length <= headcount_cap` → 자동 허용
4. **requires_human_for 체크**: 작업 종류가 목록에 있으면 → Policy Decision 생성

**자율 중단 조건**:
1. **Budget 소진**: `accumulated_cost >= max_cost_usd` → Operation 자동 Pause
2. **Token 한도**: `accumulated_tokens >= max_tokens` → Operation 자동 Pause
3. **Operation Cap**: `active_operations >= active_operation_cap` → 신규 Operation 거부
4. **Frozen Unit**: `unit.policy.frozen = true` → 신규 Dispatch 거부
5. **Kill Switch**: `unit.policy.kill_switch = true` → Unit 완전 비활성화

### 3.5. Budget Envelope (리소스 한도)

```ocaml
type budget_envelope = {
  headcount_cap : int;             (* 최대 에이전트 수 *)
  active_operation_cap : int;      (* 최대 동시 작전 수 *)
  max_cost_usd : float;            (* 최대 비용 (USD) *)
  max_tokens : int;                (* 최대 토큰 사용량 *)
}
```

**Unit Kind별 기본 Budget**:

| Unit Kind | Headcount Cap | Active Op Cap | Max Cost (USD) | Max Tokens |
|-----------|--------------|---------------|----------------|------------|
| Company | 128 | 24 | $50 | 5,000,000 |
| Platoon | 32 | 8 | $15 | 1,500,000 |
| Squad | 8 | 3 | $5 | 500,000 |
| Agent_unit | 1 | 1 | $1 | 100,000 |

**Budget 초과 시 자율 행동**:
- **자동 Pause**: 현재 실행 중인 Operation 일시 중지
- **거부**: 신규 Operation 할당 거부
- **SSE Event**: `command_plane/budget_exceeded` 이벤트 발생

### 3.6. Intent (장기 목표) 및 Operation 연결

**Intent**는 여러 Operation을 묶는 상위 레벨 목표다:

```ocaml
type intent_state =
  | Adopted          (* 초기 상태 *)
  | Active_intent    (* 진행 중 *)
  | Blocked_intent   (* 블로킹됨 *)
  | Suspended_intent (* 일시 중지 *)
  | Handoff_ready    (* 전환 준비 *)
  | Completed_intent (* 완료 *)
  | Dropped_intent   (* 취소 *)
```

**Intent 생성 및 연결**:
```json
{
  "tool": "masc_intent_create",
  "arguments": {
    "title": "Improve test coverage to 80%",
    "workload_profile": "coding_task",
    "success_metric": "coverage >= 0.80",
    "invariants": ["No breaking changes", "All tests pass"],
    "artifact_priors": ["existing test suite", "coverage report"]
  }
}
```

```json
{
  "tool": "masc_intent_link_operation",
  "arguments": {
    "intent_id": "intent-123",
    "operation_id": "operation-456"
  }
}
```

**자동 상태 동기화**:
- Operation 상태 변화 → 연결된 Intent 상태 자동 갱신
- 모든 연결된 Operation이 Completed → Intent를 Completed_intent로 자동 전환

### 3.7. Workload Profile 및 Stage Graph

**Workload Profile 종류**:
1. **coding_task**: 코드 작성 작업
2. **research_pipeline**: 리서치 작업

**coding_task Stage Graph**:
```
decompose → inspect → implement → verify → review
                                     ↑        ↑
                                     └────────┘
                                  (dependency)
```

**Stage 진행 규칙**:
- **dependency 체크**: `verify` stage는 `implement` 완료 필요
- **순차 진행**: 이전 stage 완료 없이 다음 stage 진입 불가
- **자동 전환**: Stage 완료 시 다음 stage로 자동 전환 (policy 허용 시)

**MCP 툴**:
```json
{
  "tool": "masc_operation_update",
  "arguments": {
    "operation_id": "operation-456",
    "stage": "implement"
  }
}
```

---

## 4. 제어 메커니즘 비교

| 측면 | MDAL | Command Plane V2 |
|------|------|------------------|
| **목적** | 측정 가능한 메트릭 개선 루프 | 조직 구조 및 작전 관리 |
| **시작 조건** | `masc_mdal_start` 명시적 호출 | `masc_operation_start` 명시적 호출 |
| **자율 판단 범위** | Profile 제약 (goal, max_iterations, stagnation) | Policy Envelope (tool_allowlist, requires_human_for) |
| **승인 게이트** | 없음 (자율 실행) | 있음 (Policy Decision Queue) |
| **자동 중단** | goal/limits/stagnation | Budget 초과, frozen/kill_switch |
| **상태 복구** | Interrupted → 재개 가능 | Operation Pause → Resume 가능 |
| **Persistence** | `.masc/mdal/` | `.masc/control-plane/` |
| **가시성** | Board + SSE (관측용) | Dashboard + SSE (관측용) |

---

## 5. 실전 시나리오 및 결정 트리

### 시나리오 1: "테스트 커버리지를 80%까지 올려줘"

**결정 프로세스**:
1. **측정 가능한 메트릭?** Yes (coverage percentage)
2. **단일 수치 목표?** Yes (80%)
3. **반복 측정 가능?** Yes (coverage script 실행)

**→ MDAL 사용**

**실행 단계**:
```json
{
  "tool": "masc_mdal_start",
  "arguments": {
    "profile": "coverage",
    "metric_fn": "./scripts/coverage_percent.sh",
    "goal": "metric >= 0.80",
    "target": "Test coverage >= 80%",
    "agent": "claude:opus",
    "max_iterations": 10,
    "stagnation_threshold": 0.01,
    "stagnation_count": 3,
    "tools_allow": ["masc_spawn", "masc_code_write", "masc_run_test"]
  }
}
```

**자율 판단 경계**:
- 각 iteration에서 worker가 테스트 추가
- coverage 측정 후 delta 계산
- 80% 도달 또는 10회 반복 시 자동 중단
- 3회 연속 진전 없으면 stagnation 판단 후 중단

### 시나리오 2: "백엔드 팀이 인증 기능을 구현하도록 해줘"

**결정 프로세스**:
1. **조직 구조 필요?** Yes (backend team)
2. **장기 작전?** Yes (복잡한 기능)
3. **여러 단계?** Yes (decompose → implement → verify → review)

**→ Command Plane V2 사용**

**실행 단계**:
```json
// 1. Squad 생성 (이미 있으면 생략)
{
  "tool": "masc_unit_create",
  "arguments": {
    "kind": "squad",
    "label": "backend-team",
    "parent_unit_id": "platoon-engineering-001"
  }
}

// 2. Intent 생성
{
  "tool": "masc_intent_create",
  "arguments": {
    "title": "Implement authentication feature",
    "workload_profile": "coding_task",
    "success_metric": "Feature complete and tested"
  }
}

// 3. Operation 시작
{
  "tool": "masc_operation_start",
  "arguments": {
    "objective": "Implement user authentication with JWT",
    "workload_profile": "coding_task",
    "intent_id": "intent-123"
  }
}

// 4. Dispatch
{
  "tool": "masc_dispatch_assign",
  "arguments": {
    "operation_id": "operation-456",
    "target_unit_id": "squad-backend-team"
  }
}
```

**자율 판단 경계**:
- Squad의 tool_allowlist 내에서만 작업
- Budget 한도($5, 500K tokens) 내에서 자율 실행
- `destructive_tool` 사용 시 승인 필요
- Stage 진행은 dependency 체크 후 자동 전환

### 시나리오 3: "코드 품질을 개선해줘"

**결정 프로세스**:
1. **측정 가능한 메트릭?** 애매함 ("품질"은 주관적)
2. **단일 수치 목표?** No

**→ MDAL 부적합, 일반 Task 사용**

**대안**:
- 구체적 메트릭 정의 (lint error count, cyclomatic complexity)
- 메트릭 정의 후 MDAL 사용
- 또는 Code Review Operation으로 Command Plane V2 사용

---

## 6. Control API 및 Dashboard 경로

### 6.1. MDAL Control

**MCP Tools**:
- `masc_mdal_start` - Loop 시작
- `masc_mdal_iterate` - 수동 iteration (또는 worker 재개)
- `masc_mdal_status` - 상태 조회
- `masc_mdal_stop` - Loop 중단

**HTTP Routes**:
- `POST /api/v1/mdal/loops/start`
- `POST /api/v1/mdal/loops/stop`
- `GET /api/v1/mdal/loops` (목록)
- `GET /api/v1/mdal/loops/:loopId` (상세)

**Dashboard**:
- `/dashboard` → MDAL 섹션
- Loop 목록, 상태, metric 그래프
- Start/Stop 버튼

### 6.2. Command Plane V2 Control

**MCP Tools** (40개):
- **Unit**: `masc_unit_create`, `masc_unit_update`, `masc_unit_reparent`
- **Operation**: `masc_operation_start`, `masc_operation_pause`, `masc_operation_resume`, `masc_operation_stop`, `masc_operation_finalize`
- **Intent**: `masc_intent_create`, `masc_intent_update`, `masc_intent_link_operation`
- **Dispatch**: `masc_dispatch_assign`, `masc_dispatch_rebalance`, `masc_dispatch_escalate`, `masc_dispatch_recall`
- **Policy**: `masc_policy_freeze_unit`, `masc_policy_kill_switch`, `masc_policy_approve`, `masc_policy_deny`

**HTTP Routes**:
- `POST /api/v1/command-plane/operation/start`
- `POST /api/v1/command-plane/operation/pause`
- `POST /api/v1/command-plane/dispatch/assign`
- `POST /api/v1/command-plane/policy/approve`
- 기타 40개 operation/dispatch/policy endpoint

**Dashboard**:
- `/dashboard` → Command Plane 섹션
- Unit 계층 구조, Operation 목록, Policy Decision 큐
- Approve/Deny 버튼, Unit 상태 토글

---

## 7. 디버깅 및 관측

### 7.1. MDAL 상태 확인

```bash
# MCP 툴로 확인
masc_mdal_status { "loop_id": "mdal-abc123" }

# HTTP API로 확인
curl http://127.0.0.1:8935/api/v1/mdal/loops/mdal-abc123

# FileSystem 직접 확인
cat .masc/mdal/mdal-abc123.json
cat .masc/mdal/latest.json
```

**중요 필드**:
- `status`: `running`, `completed`, `stopped`, `interrupted`, `error`
- `stop_reason`: 중단 이유
- `error_message`: 에러 메시지
- `recoverable`: 재개 가능 여부
- `current_iteration`, `baseline_metric`, `history`

### 7.2. Command Plane V2 상태 확인

```bash
# MCP 툴로 확인
masc_observe_topology  # Unit 계층 구조
masc_observe_operations  # Operation 목록
masc_observe_decisions  # Policy Decision 큐

# FileSystem 직접 확인
cat .masc/control-plane/units.json
cat .masc/control-plane/operations.json
cat .masc/control-plane/decisions.json
cat .masc/control-plane/events.jsonl  # Event log
```

**중요 필드**:
- Unit: `kill_switch`, `frozen`, `budget`, `policy`
- Operation: `status`, `stage`, `assigned_unit_id`, `intent_id`
- Decision: `status`, `requested_action`, `expires_at`

### 7.3. SSE Events

**MDAL Events**:
- `mdal/loop_started`
- `mdal/iteration_complete`
- `mdal/loop_stopped`
- `mdal/loop_completed`
- `mdal/loop_error`

**Command Plane Events**:
- `command_plane/operation_started`
- `command_plane/operation_status_changed`
- `command_plane/policy_decision_created`
- `command_plane/policy_decision_approved`
- `command_plane/budget_exceeded`
- `command_plane/unit_frozen`
- `command_plane/kill_switch_activated`

---

## 8. 체크리스트: "왜 안 돌아가?"

### MDAL이 시작되지 않을 때

- [ ] `masc_mdal_start` 호출했는가?
- [ ] `metric_fn`이 유효한 셸 명령어인가?
- [ ] `metric_fn`이 float을 출력하는가?
- [ ] `goal` 문법이 올바른가? (`metric >= 0.90`, `metric <= 5`)
- [ ] `agent` 모델이 사용 가능한가?
- [ ] `tools_allow` 목록이 비어있지 않은가?
- [ ] `strict_mode`에서 Team Session이 사용 가능한가?
- [ ] Backend (FileSystem/PostgreSQL)가 정상인가?

### MDAL Loop가 멈췄을 때

- [ ] `status`가 무엇인가? (`running`, `stopped`, `error`, `interrupted`)
- [ ] `stop_reason`이 무엇인가?
  - `max_iterations_reached` → max_iterations 증가 고려
  - `time_limit_exceeded` → max_time_seconds 증가 고려
  - `stagnation_limit_reached` → stagnation_threshold 감소 또는 stagnation_count 증가 고려
  - `goal_reached` → 정상 완료
- [ ] `error_message`가 있는가?
  - Worker 실패, metric 측정 실패, evidence 부족 등
- [ ] `recoverable: true`인가?
  - Yes → `masc_mdal_iterate`로 재개 가능
  - No → 새 Loop 시작 필요

### Command Plane Operation이 실행되지 않을 때

- [ ] `masc_operation_start` 호출했는가?
- [ ] `masc_dispatch_assign` 또는 `masc_dispatch_plan` 호출했는가?
- [ ] 할당된 Unit의 `kill_switch`가 `false`인가?
- [ ] 할당된 Unit의 `frozen`이 `false`인가?
- [ ] Unit의 Budget가 남아있는가?
  - `headcount_cap`, `active_operation_cap`, `max_cost_usd`, `max_tokens`
- [ ] Operation `status`가 `Active`인가?
- [ ] Policy Decision이 `pending` 상태로 막혀있는가?
  - `masc_observe_decisions`로 확인
  - `masc_policy_approve` 또는 `masc_policy_deny`로 처리

---

## 9. 요약: 자율 판단 경계

### MDAL

| 질문 | 답변 |
|------|------|
| 언제 시작되는가? | 명시적 `masc_mdal_start` 호출 시에만 |
| 언제 자율로 멈추는가? | goal 달성, max_iterations, stagnation, timeout |
| 언제 수동 개입이 필요한가? | 시작, 명시적 중단 (`masc_mdal_stop`) |
| 어떤 제약 조건이 있는가? | Profile (goal, limits, tools_allow) |
| 승인 게이트가 있는가? | 없음 (완전 자율) |

### Command Plane V2

| 질문 | 답변 |
|------|------|
| 언제 시작되는가? | 명시적 `masc_operation_start` + `masc_dispatch_assign` 시에만 |
| 언제 자율로 멈추는가? | Budget 초과, frozen/kill_switch, Stage 완료 |
| 언제 수동 개입이 필요한가? | Operation 시작, Policy Decision 승인, Unit Policy 변경 |
| 어떤 제약 조건이 있는가? | Policy Envelope (tool_allowlist, requires_human_for), Budget Envelope |
| 승인 게이트가 있는가? | 있음 (Policy Decision Queue) |

---

## 10. 참고 자료

- [MDAL.md](./MDAL.md) - MDAL 상세 가이드
- [COMMAND-PLANE-RUNBOOK.md](./COMMAND-PLANE-RUNBOOK.md) - Command Plane 사용법
- [spec/06-command-plane.md](./spec/06-command-plane.md) - Command Plane V2 스펙
- [BENCHMARK-RUNBOOK.md](./BENCHMARK-RUNBOOK.md) - 벤치마크 실행 가이드
- [SUPERVISOR-MODE.md](./SUPERVISOR-MODE.md) - Supervisor 모드 가이드

---

## 11. 변경 이력

| 날짜 | 변경 사항 | 작성자 |
|------|----------|--------|
| 2026-03-30 | 초안 작성 | System |
