# Team Session

| 항목 | 값 |
|------|-----|
| Status | Draft |
| Team | Chain |
| Maps to | `lib/team_session/*.ml`, `lib/team_context.ml`, `lib/tool_team_session*.ml` |
| Dependencies | 03-room-coordination, 06-command-plane, 13-oas-integration |
| LOC | ~10.8K (core ~6.3K + tool surface ~4.5K) |
| MCP Tools | `masc_team_session_start`, `masc_team_session_step`, `masc_team_session_finalize`, +α |

---

## 1. Purpose

Team Session은 다수의 AI 에이전트가 시간 제한 하에 공동 목표를 수행하는 감독형(supervised) 협업 세션이다. 세션은 checkpoint, report, proof artifact를 자동 생성하여 작업의 진행과 완결을 증명한다.

핵심 역할:

- **시간 제한 오케스트레이션**: 60s ~ 28800s (8시간) 범위의 세션 생명주기 관리
- **다중 실행 모드**: Manual(수동), Assist(보조), Auto(자율, OAS Swarm 경유)
- **Worker 계획/실행**: planned_worker 기반 agent 배치, routing decision, swarm 연동
- **Checkpoint/Report/Proof**: 주기적 상태 기록, 최종 보고서와 증거 아티팩트 생성
- **OAS Bridge**: MASC session -> OAS Swarm 변환, callback 기반 감독

---

## 2. Architecture

```
Team Session Engine (Eio)
  |
  +--> Team Session Store (persistence)
  |      - session.json, events.jsonl, checkpoints/, worker-runs/
  |
  +--> Team Session OAS Bridge
  |      - MASC session -> OAS swarm_config 변환
  |      - planned_worker -> agent_entry 변환
  |
  +--> Team Session Swarm Runner
  |      - OAS Runner.run 경유 실행 (Auto mode)
  |
  +--> Team Session Swarm Callbacks
  |      - on_iteration_start -> checkpoint write
  |      - on_agent_done -> event journal + SSE broadcast
  |      - on_converged -> session finalization
  |      - on_error -> policy violation recording
  |
  +--> Team Session Report / Proof
  |      - Markdown + JSON report 생성
  |      - Proof artifact (강한 증거 모드)
  |
   +--> Team Context
          - worker 간 공유 컨텍스트 (~500 토큰)
          - OAS Swarm bridge metadata / prompt projection
```

---

## 3. Session Type

`Team_session_types.session`은 47개 필드의 레코드로, 세션의 전체 상태를 표현한다.

### 3.1. Core Identity (7 fields)

| Field | Type | 설명 |
|-------|------|------|
| `session_id` | string | 고유 식별자 |
| `goal` | string | 세션 목표 |
| `created_by` | string | 생성자 agent |
| `origin_kind` | session_origin_kind | Origin_human / Origin_system |
| `room_id` | string | 소속 Room |
| `operation_id` | string option | CPv2 Operation 연결 |
| `status` | session_status | Running/Paused/Completed/Interrupted/Failed/Cancelled |

`origin_kind`는 `orchestration_mode = Auto`이면 Origin_system, Manual/Assist에서는 `created_by`의 prefix 패턴(keeper, dashboard, operator 등)으로 자동 추론한다.

### 3.2. Configuration (14 fields)

| Field | Type | 기본값 |
|-------|------|--------|
| `duration_seconds` | int | 3600 (1h), clamp [60, 28800] |
| `execution_scope` | execution_scope | Limited_code_change |
| `checkpoint_interval_sec` | int | 60, clamp [10, 600] |
| `min_agents` | int | 1, clamp [1, 64] |
| `scale_profile` | scale_profile | Scale_standard |
| `control_profile` | control_profile | Control_flat |
| `orchestration_mode` | orchestration_mode | Assist |
| `communication_mode` | communication_mode | Comm_broadcast |
| `model_cascade` | string list | [] (Cascade module이 결정) |
| `fallback_policy` | fallback_policy | Fallback_cascade_then_task |
| `instruction_profile` | instruction_profile | Profile_standard |
| `alert_channel` | alert_channel | Alert_both |
| `auto_resume` | bool | false |
| `report_formats` | report_format list | [Markdown; Json] |

### 3.3. Runtime State (12 fields)

| Field | Type | 설명 |
|-------|------|------|
| `turn_count` | int | 누적 session orchestration turn 수 (`team_turn` + swarm iteration) |
| `agent_names` | string list | 참여 agent 목록 |
| `planned_workers` | planned_worker list | 계획된 worker 사양 |
| `broadcast_count` | int | broadcast 횟수 |
| `portal_count` | int | portal 교환 횟수 |
| `cascade_attempted` | int | LLM cascade 시도 횟수 |
| `cascade_success` | int | cascade 성공 |
| `cascade_failed` | int | cascade 실패 |
| `fallback_task_created` | int | fallback task 생성 횟수 |
| `min_agents_violation_streak` | int | 최소 agent 미달 연속 횟수 |
| `policy_violations` | string list | 정책 위반 기록 |
| `baseline_done_counts` | (string * int) list | 세션 시작 시 agent별 완료 task 수 |

### 3.4. Timestamps and Termination (8 fields)

| Field | Type |
|-------|------|
| `started_at` | float |
| `planned_end_at` | float |
| `stopped_at` | float option |
| `last_checkpoint_at` | float option |
| `last_event_at` | float option |
| `last_turn_at` | float option |
| `stop_reason` | string option |
| `generated_report` | bool |

### 3.5. Proof and Artifacts (4 fields)

| Field | Type |
|-------|------|
| `final_done_delta_total` | int option |
| `final_done_delta_by_agent` | (string * int) list option |
| `artifacts_dir` | string |
| `created_at_iso` / `updated_at_iso` | string |

---

## 4. Enum Types

`Team_session_types_enums`에 정의된 30+ variant type.

### 4.1. Session Status

```
Running | Paused | Completed | Interrupted | Failed | Cancelled
```

### 4.2. Orchestration Mode

| Mode | 설명 |
|------|------|
| `Manual` | 모든 step을 agent가 명시적으로 호출 |
| `Assist` | agent가 step을 호출하되, 시스템이 checkpoint/alert 보조 |
| `Auto` | OAS Swarm Runner 경유 자율 실행 |

### 4.3. Worker Types

`planned_worker` 레코드 (24개 필드):

| Field | Type | 설명 |
|-------|------|------|
| `spawn_agent` | string | Agent 이름 |
| `runtime_actor` | string option | Runtime에서의 actor 식별자 |
| `spawn_role` | string option | Worker 역할 |
| `spawn_model` | string option | 명시 모델 |
| `execution_scope` | execution_scope option | Observe_only/Limited_code_change/Autonomous |
| `thinking_enabled` | bool option | Thinking mode 활성화 |
| `thinking_budget` | int option | Thinking 토큰 예산 |
| `max_turns` | int option | 최대 turn 수 |
| `timeout_seconds` | int option | Worker timeout |
| `worker_class` | worker_class option | Manager/Executor/Scout/Librarian/Metacog |
| `capsule_mode` | capsule_mode option | Fresh/Inherit/Capsule |
| `controller_level` | controller_level option | Root/Lane/Submanager/Worker |
| `control_domain` | control_domain option | Execution/Quality/Knowledge/Runtime/Meta |
| `model_tier` | model_tier option | Tier_35b/Tier_27b/Tier_9b |
| `task_profile` | task_profile option | Extract/Normalize/Summarize/Verify/Decide/Synthesize |
| `risk_level` | risk_level option | Low/Medium/High |
| `routing_confidence` | float option | Routing 결정 신뢰도 |
| `routing_reason` | string option | Routing 결정 사유 |
| `routing_escalated` | bool | Escalation 발생 여부 |

Dedup은 `planned_worker_key` 함수로 `runtime_actor` 우선, fallback으로 전체 필드 조합 키를 사용한다.

---

## 5. Persistence (`team_session_store.ml`)

### 5.1. Directory Structure

```
.masc/team-sessions/
  {session_id}/
    session.json           -- session record
    events.jsonl           -- append-only event log
    checkpoints/           -- periodic checkpoint JSON
    worker-runs/
      {worker_run_id}/
        run.json           -- worker run record
        checkpoint.json    -- worker run checkpoint
        meta.json          -- worker run metadata
    workers/
      {worker_name}/
        meta.json          -- worker container metadata
        checkpoint.json    -- worker checkpoint
        turns.jsonl        -- worker turn log
    report.md              -- final report (Markdown)
    report.json            -- final report (JSON)
    proof.md               -- proof artifact (Markdown)
    proof.json             -- proof artifact (JSON)
```

### 5.2. Event Entry

```ocaml
type event_entry = {
  ts : float;
  ts_iso : string;
  event_type : string;
  detail : Yojson.Safe.t;
}
```

### 5.3. Checkpoint

```ocaml
type checkpoint = {
  ts : float;
  ts_iso : string;
  status : session_status;
  elapsed_sec : int;
  remaining_sec : int;
  progress_pct : float;
  done_delta_total : int;
  done_delta_by_agent : (string * int) list;
  active_agents : string list;
}
```

`done_delta_total`은 세션 시작 후 완료된 task 수로, `baseline_done_counts`와 현재 backlog의 차이로 계산된다.

---

## 6. Engine Architecture (`team_session_engine_eio.ml`)

### 6.1. Session 생성

`start_session`은 Eio Switch/Clock context에서 실행된다.

주요 validation:
- duration/checkpoint_interval/min_agents clamp
- `operation_id` 제공 시 CPv2 Operation 존재 + 연결 검증
- agent_names가 비어 있으면 room의 active agent를 자동 선택

생성 후: session.json 저장, 초기 event 기록, checkpoint 초기화.

### 6.2. Orchestration Mode별 실행 경로

| Mode | 실행 경로 |
|------|----------|
| Manual | Agent가 `masc_team_session_step`으로 turn 기록. Engine은 checkpoint만 수행 |
| Assist | Manual과 동일하나 시스템이 alert, suggestion 제공 |
| Auto | `Team_session_swarm_runner.run_swarm` 경유 OAS Swarm 실행 |

Auto mode 이전의 legacy polling engine (15초 주기)은 Phase C-2d에서 제거되었다.

---

## 7. OAS Bridge (`team_session_oas_bridge.ml`)

Phase C-1 migration 산출물. MASC Team Session을 OAS Swarm으로 변환한다.

### 7.1. 변환 매핑

| MASC | OAS |
|------|-----|
| `session` | `Swarm_types.swarm_config` |
| `planned_worker` | `Swarm_types.agent_entry` |
| `orchestration_mode` | `Swarm_types.orchestration_mode` |
| `worker_class` | `Swarm_types.agent_role` |
| `model_cascade` -> `planned_worker` | cascade_name string |

### 7.2. Tool Dispatch Bridge

`supported_local_worker_tools`는 사용 가능한 MCP tool 목록을 반환한다. `dispatch_supported_tool`은 Eio context에서 MCP tool을 호출하여 `(handled: bool, result: string)`을 반환한다.

### 7.3. Result Application

`apply_swarm_result`는 OAS `swarm_result`의 통계(agent count, turn count, errors)를 MASC session 레코드에 반영한다.

---

## 8. Swarm Runner (`team_session_swarm_runner.ml`)

Auto mode에서 세션을 OAS Swarm Runner로 실행한다.

동작 순서:
1. `Team_session_store.load_session`으로 session 로드
2. `Team_session_oas_bridge.session_to_swarm_config`로 swarm_config 변환
3. `Team_session_swarm_callbacks.make_callbacks`로 MASC 감독 콜백 생성
4. `Agent_sdk_swarm.Runner.run`으로 swarm 실행
5. `apply_swarm_result`로 결과 반영 + session 저장

---

## 9. Swarm Callbacks (`team_session_swarm_callbacks.ml`)

OAS Swarm lifecycle을 MASC 감독 로직에 연결하는 4개 callback:

| Callback | MASC 동작 |
|----------|----------|
| `on_iteration_start` | Checkpoint write (session dir) |
| `on_agent_done` | Event journal 기록 + SSE broadcast |
| `on_converged` | Session finalization (report 생성, status -> Completed) |
| `on_error` | Policy violation 기록 + 선택적 alert |

---

## 10. Team Context (`team_context.ml`)

Worker 간 공유 컨텍스트를 ~500 토큰으로 압축하여 worker prompt에 주입한다.

```ocaml
type team_context = {
  team_goal : string;
  prior_decisions : string list;
  shared_findings : string list;
  active_workers : string list;
  task_tree : task_summary list;
}
```

`add_finding`: 완료된 worker가 1-2문장의 key finding을 기록.
`load_findings`: 이전 worker들의 finding을 `"[worker_name] finding"` 형식으로 로드.
`to_prompt_section`: team_context를 prompt 삽입용 문자열로 렌더링.

### 10.1. Current OAS Swarm Bridge Truth

현재 bridge의 핵심은 `Collaboration.t` 투영이 아니라 `session -> swarm_config`, `planned_worker -> agent_entry` 변환이다.

- `team_session_oas_bridge.ml`은 OAS Swarm 실행에 필요한 typed 필드와 `worker_specs` metadata JSON을 구성한다.
- `collaboration_context`는 현재 `None`으로 고정되어 있으며, `test_team_session_oas_bridge.ml`도 이 truth를 검증한다.
- session semantics는 prompt, worker metadata, `resource_check`, telemetry/proof surface를 통해 유지되지만 fidelity gap은 아직 남아 있다.

---

## 11. Report and Proof System

### 11.1. Report

`team_session_report.ml` + `team_session_report_core.ml`에서 Markdown/JSON 보고서를 생성한다. 세션 종료 시 자동 생성.

포함 내용: 세션 메타데이터, goal, 참여 agent, turn 통계, cascade 통계, checkpoint 이력, done delta.

### 11.2. Proof

`team_session_report_proof.ml` + `team_session_report_proof_helpers.ml`에서 증거 아티팩트를 생성한다.

Proof level:
- `Proof_standard`: 기본 진행 증거
- `Proof_strong`: checkpoint 해시, event log 무결성 등 추가 검증

---

## 12. MCP Tool Surface

Tool layer는 `tool_team_session.ml` facade를 통해 접근한다. 내부는 5개 모듈로 분할되어 있다.

| Module | LOC | 역할 |
|--------|-----|------|
| `tool_team_session_schemas.ml` | 687 | MCP JSON schema 정의 |
| `tool_team_session_handlers.ml` | 574 | dispatch entry + handler 구현 |
| `tool_team_session_support.ml` | 506 | 공통 유틸리티, context type |
| `tool_team_session_routing.ml` | 729 | routing decision, spawn spec 파싱 |
| `tool_team_session_routing_workers.ml` | 501 | worker 관리, spawn 실행 |
| `tool_team_session_step.ml` | 534 | step 실행 + turn 기록 |
| `tool_team_session_step_exec.ml` | 449 | step 내부 실행 로직 |
| `tool_team_session_step_spawn.ml` | 395 | worker spawn 실행 |
| `tool_team_session_step_types.ml` | 147 | step 관련 type 정의 |

### 12.1. 주요 Tool

| Tool | 동작 |
|------|------|
| `masc_team_session_start` | 세션 생성 (goal, duration, mode, agents 지정) |
| `masc_team_session_step` | Turn 기록 (note/broadcast/portal/task/checkpoint) + worker spawn |
| `masc_team_session_finalize` | 세션 종료 + report/proof 생성 |
| `masc_team_session_status` | 세션 상태 조회 |
| `masc_team_session_pause` / `resume` | 일시 정지/재개 |

### 12.2. Step with Worker Spawn

`masc_team_session_step`의 spawn 기능은 legacy `spawn_agent`/`spawn_model`/`model_tier` 필드를 거부하고, `spawn_prompt`, `spawn_role`, `worker_class`, `worker_size` 기반 사양을 요구한다. Routing decision은 `routing_decision` 타입으로 model_tier, task_profile, risk_level, confidence를 결정한다.

### 12.3. Routing Decision

```ocaml
type routing_decision = {
  model_tier : model_tier;     (* Tier_35b | Tier_27b | Tier_9b *)
  task_profile : task_profile; (* Extract | Normalize | Summarize | Verify | Decide | Synthesize *)
  risk_level : risk_level;     (* Low | Medium | High *)
  confidence : float option;
  reason : string;
  judge_used : bool;
  escalate_if : string list;
  escalated : bool;
}
```

---

## 13. Known Issues and Planned Changes

| Issue | 설명 | Status |
|-------|------|--------|
| tool_team_session 분할 | 원래 4412줄 god file. 현재 9개 모듈로 분할 완료 | Resolved |
| Legacy spawn field 거부 | `spawn_agent`, `spawn_model`, `model_tier` 직접 사용 불가. migration 에러 반환 | By design |
| Manual/Assist + Auto 이원 경로 | Auto는 OAS Swarm, Manual/Assist는 기존 engine. 통합 미완 | In progress |
| session record 47 fields | `swarm_config` / `worker_specs` bridge에 일부 fidelity gap이 남아 있음 (`collaboration_context=None`) | Architectural |
| Checkpoint proof hash | `Proof_strong` 모드의 hash chain 구현 범위가 event log 무결성에 한정 | Enhancement candidate |

---

## 14. Integration Points

| System | 연결 방식 |
|--------|----------|
| CPv2 Operation | `operation_id`로 연결. session이 operation의 `detachment_session_id`를 업데이트 |
| Room Backlog | `done_counts_from_backlog`로 task 완료 추적 |
| SSE | Checkpoint, agent done 등 이벤트를 SSE로 broadcast |
| OAS Swarm | Auto mode에서 `Runner.run` 경유 실행 |
| Orchestra | `command_plane_orchestra.ml`에서 session_node로 시각화 |
| Cascade | `model_cascade` 필드로 LLM 호출 순서 지정 |
