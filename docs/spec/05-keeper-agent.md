---
status: reference
last_verified: 2026-04-17
code_refs:
  - lib/keeper/
---

# Keeper Agent System

| 항목 | 값 |
|------|-----|
| Status | Draft |
| Team | Keeper |
| Maps to | `lib/keeper/` |
| Dependencies | 02-types-and-invariants, 13-oas-integration |
| Modules | `lib/keeper/` source tree is the inventory SSOT |
| LOC | Derived from the source tree, not duplicated here |
| MCP Tools | `tool_keeper` |
| External Deps | `Agent_sdk` (OAS), `Llm_provider`, `Workspace`, `Runtime_inference` |

---

## 1. Purpose

Keeper는 MASC의 자율 에이전트 하네스(harness)다. OAS `Agent.run` 위에서 동작하며, 장기 실행 루프, 컨텍스트 관리, 메모리 계층, 심의(deliberation), 승계(succession), 검증(verification)을 담당한다.

Keeper 하나는 다음을 소유한다:
- **identity**: `keeper_meta` 레코드 (이름, persona, instructions, typed goal/task links)
- **context**: `working_context` (system prompt + messages + token count + OAS context)
- **memory**: memory bank + memory policy + recall scoring
- **lifecycle**: heartbeat fiber + supervisor + checkpoint store

Keeper는 외부 세계를 관찰(`world_observation`)하고, 프롬프트를 구성하고, OAS `Agent.run`에 위임하고, 결과로부터 메트릭을 갱신하는 루프를 반복한다.

---

## 2. Architecture

```mermaid
graph LR
  subgraph Types
    KT[keeper_types] --> KC[keeper_config]
    KT --> KCT[keeper_contract]
  end
  subgraph Context
    KWC[working_context] --> KEC[exec_context] --> KCS[checkpoint_store]
  end
  subgraph Memory
    KMB[memory_bank] --> KMP[memory_policy] --> KMR[memory_recall]
  end
  subgraph Turn
    KUT[unified_turn] --> KAR[agent_run] --> KTO[tools_oas]
    KAR --> KHO[hooks_oas]
  end
  subgraph Decision
    KD[deliberation] --> KV[verifier]
    KD --> KL[learning]
  end
  subgraph Supervision
    KRS[supervisor] --> KKA[keepalive]
  end
  KUT --> KWO[world_observation]
  KAR -.-> OAS["OAS Agent.run()"]
```

### 2.1 모듈 분류 (12 범주)

| 범주 | 대표 파일 | 파일 수 |
|------|----------|--------|
| Types | `keeper_types.ml`, `keeper_types_profile.ml`, `keeper_types_support.ml` | 3 |
| Config | `keeper_config.ml`, `keeper_toml_loader.ml` | 2 |
| Context | `keeper_context_core.ml`, `keeper_context_runtime.ml`, `keeper_checkpoint_store.ml` | 3 |
| Memory | `keeper_memory*.ml` (bank, policy, recall) | 4 |
| Prompt / Skill | `keeper_prompt.ml`, `keeper_unified_prompt.ml`, `keeper_skill_routing.ml` | 3 |
| Turn Execution | `keeper_agent_run.ml`, `keeper_unified_turn.ml`, `keeper_tools_oas.ml`, `keeper_hooks_oas.ml` | 4 |
| Decision | `keeper_deliberation.ml` | 1 |
| Supervision | `keeper_supervisor.ml`, `keeper_keepalive.ml`, `keeper_world_observation.ml` | 3 |
| MCP Surface | `keeper_turn.ml`, `keeper_status.ml`, `keeper_persona.ml`, `keeper_schema.ml` | 4 |
| Alerting / Metrics | `keeper_alerting*.ml`, `keeper_status_runtime*.ml`, `keeper_status_detail.ml` | 6+ |

---

## 3. Types

### 3.1 keeper_meta

Keeper의 전체 상태를 담는 레코드. `lib/keeper/keeper_types.ml`에 정의되며, 약 100개 필드를 가진다.

**소스**: `keeper_types.ml` (lines 9-106)

주요 필드 군:

- **Identity**: `name`, `agent_name`, `trace_id`, `trace_history`
- **Lineage**: `generation`, `trace_id`, `trace_history`, `last_handoff_ts`
- **Goal/Task links**: `active_goal_ids`, `current_task_id`, typed goal/task transitions
- **Model**: `runtime_id`, `last_model_used`, derived `active_model`
- **Capability boundary**: the flat Tool catalog plus objective `allowed_paths`
  containment; external effects pass through the Gate.
- **Scope**: `mention_targets`, `bound_workspace_ids`
- **Proactive**: `proactive_enabled`, `proactive_idle_sec`, `proactive_cooldown_sec`
- **Metrics**: `total_turns`, `total_tokens`, `total_cost_usd`, `last_turn_ts` 등
- **Team/Autonomy**: `active_goal_ids`, `autonomous_turn_count`, `board_reactive_turn_count`, `mention_reactive_turn_count`

직렬화: `meta_to_json` / `meta_of_json`로 JSON 왕복. `validate_name`이 역직렬화 시점에 이름/trace_id를 검증한다.

Generation semantics are operational, not genealogical: a successful rollover keeps the same keeper identity but commits a new `trace_id`, increments `generation`, and appends the old trace to `trace_history`.

### 3.2 working_context

**형식 SSOT**: `lib/keeper_types/keeper_types.mli`

```ocaml
type working_context = {
  checkpoint : Agent_sdk.Checkpoint.t;
}
```

Keeper의 실행 중 대화 컨텍스트는 OAS checkpoint 하나를 감싼다.
`Keeper_context_core`의 accessor가 system prompt, exact messages와 OAS context를
projection한다. 로컬 `token_count`, `max_tokens`, importance score, 문자 길이 기반
token 추정치는 이 record에 존재하지 않는다. Provider usage token은 별도 telemetry다.

### 3.3 checkpoint / session_context

```ocaml
type session_context = {
  session_id : string;
  session_dir : string;
}
```

별도 MASC checkpoint record나 mutable checkpoint list는 없다. Canonical 대화 상태는
`Agent_sdk.Checkpoint.t`이고 `Keeper_checkpoint_store`가
`session_dir/<session_id>.json`의 현재 checkpoint와 history archive를 관리한다.
archive retention의 유일한 정의는
`Keeper_checkpoint_store.max_oas_history_retained`이다. 가시 대화와 내부 이력은
각각 `history.jsonl`, `history.internal.jsonl`에 append된다.

### 3.4 Workspace Boundary

Legacy workspace-targeting typed aliases were removed during single-workspace flattening.
JSON/MCP 경계에는 `mention_targets`, `bound_workspace_ids` 같은 workspace collaboration 값만 남고, 별도 scope enum은 더 이상 유지하지 않는다.
`policy_mode`, `policy_shell_mode`, `trigger_mode`, `initiative_*`는 제거되었다.

### 3.5 fiber_health

```ocaml
type fiber_health =
  | Fiber_alive     (* fiber 실행 중, promise 미해소 *)
  | Fiber_zombie    (* registry 존재하나 fiber 종료 *)
  | Fiber_dead      (* 재시작 예산 소진, 수동 복구 필요 *)
  | Fiber_unknown   (* supervised registry에 없음 *)
```

Supervisor가 keeper fiber의 건강 상태를 추적하는 데 사용.

---

## 4. State Machines

### 4.1 Unified Turn Lifecycle

```mermaid
stateDiagram-v2
  [*] --> Observe
  Observe --> BuildPrompt : world_observation 수집
  BuildPrompt --> AgentRun : unified prompt + tools + hooks
  AgentRun --> ToolExecution : Agent.run 내부 tool loop
  ToolExecution --> AgentRun : tool 결과 반환
  AgentRun --> UpdateMetrics : Agent.run 완료
  UpdateMetrics --> PostTurnLifecycle : 메트릭 갱신
  PostTurnLifecycle --> Checkpoint : continuity / checkpoint 정리
  Checkpoint --> CompactCheck : compaction gate
  CompactCheck --> HandoffCheck : handoff gate
  HandoffCheck --> MemoryWrite : memory bank notes
  MemoryWrite --> [*]
```

단계 설명:

1. **Observe**: `keeper_world_observation.observe`로 workspace 상태, 멘션, board 이벤트, idle 시간, 경제 압력 등을 수집
2. **BuildPrompt**: `keeper_unified_prompt.build_prompt`로 keeper identity + observation을 단일 (system_prompt, user_message) 쌍으로 조립
3. **AgentRun**: `keeper_agent_run.run_turn`이 OAS `Agent.run`에 위임. tools + hooks + context_reducer를 전달하며 memory object는 전달하지 않는다
4. **ToolExecution**: Agent가 tool을 호출하면 `keeper_tools_oas`가 `agent_tool_dispatch_runtime.execute_keeper_tool_call`로 디스패치
5. **UpdateMetrics**: `keeper_unified_turn.update_metrics_from_result`가 turn count, token 사용량, cost 등을 keeper_meta에 반영하고 `observation.idle_seconds`를 `masc_keeper_idle_seconds{keeper_name}` OTel metric-store gauge로 노출
6. **PostTurnLifecycle**: `keeper_post_turn.apply_post_turn_lifecycle_with_resilience_handles`가 compaction, handoff rollover, typed checkpoint metadata를 single-writer로 처리
7. **Checkpoint / Compact / Handoff**: checkpoint 저장 후 gate에 따라 compaction 또는 handoff rollover를 실행
8. **MemoryWrite**: `keeper_agent_run` tail에서 MASC-owned memory bank note append를 수행한다

### 4.1.1 Post-turn Persistence Matrix

| 경계 | OCaml owner | 저장소 | TLA/FSM |
|------|-------------|--------|---------|
| compaction | `keeper_post_turn.ml` | 현재 trace checkpoint | post-turn single-writer |
| handoff rollover | `keeper_post_turn.ml` + `keeper_rollover.ml` | 새 trace checkpoint + keeper meta lineage | `KeeperGenerationLineage.tla`, keeper FSM `Handoff_*` events |
| typed checkpoint metadata | `keeper_post_turn.ml` | keeper meta | keeper post-turn contract |
| memory bank | `keeper_agent_run.ml` | `.masc/keepers/<name>.memory.jsonl` | memory policy / bank compaction |
| collaboration activity signal | `workspace_task.ml` + `workspace.ml` | `.masc/activity-events/YYYY-MM/YYYY-MM-DD.jsonl` | task lifecycle + activity graph event contract |

### 4.2 Keeper Supervisor Lifecycle

```mermaid
stateDiagram-v2
  [*] --> Init : supervise_keepalive 호출
  Init --> Alive : fiber 시작 + Promise 등록
  Alive --> Alive : heartbeat loop 반복
  Alive --> Crashed : fiber 종료 (Promise 해소)
  Crashed --> Restarting : 다음 lane-local supervisor sweep
  Restarting --> Alive : sweep_and_recover
  Alive --> Dead : 명시적 durable tombstone 기록
  Crashed --> Dead : 명시적 durable tombstone 기록
  Dead --> [*] : 명시적 operator revival 또는 정리
```

- `supervise_keepalive`: keeper heartbeat loop을 supervised fiber로 실행
- `sweep_and_recover`: crash가 관측된 정확한 Keeper lane만 재시작
- 재시작에는 fleet-wide 정지나 exponential backoff admission을 두지 않는다.
- 최근 5건의 crash log 유지

### 4.3 Compaction Runtime

```mermaid
stateDiagram-v2
  [*] --> Requested : typed Compaction_started 또는 provider overflow
  Requested --> LlmPlan : owner Keeper lane
  LlmPlan --> Apply : configured LLM의 유효한 plan
  LlmPlan --> Preserve : runtime/plan 오류
  Apply --> [*] : LLM plan이 만든 context
  Preserve --> [*] : 원문 checkpoint 유지
```

MASC에는 message importance scorer나 deterministic reducer fallback이 없다.
MASC는 typed compaction stimulus와 provider overflow를 Keeper owner lane에서
처리하고 configured LLM plan만 적용한다. OAS는 model call과 provider 오류를
typed 결과로 전달하며, MASC의 compaction profile이나 ratio/message/token gate를
알지 않는다.

### 4.4 Deliberation Pipeline

WorldObservation -> TypedSignalProjection -> ModelDeliberation -> TypedAction -> RecordDecision

`Keeper_deliberation` 모듈 안에서 `triage`는 admission gate가 아니라 model
prompt용 typed signal projection이다. 모든 observation에 `Triggered triggers`를
반환하며 `triggers=[]`도 유효한 model evaluation이다. Local token/cost/turn
budget으로 deliberation을 Skip하는 경로는 없다.

단, 이 모듈의 triage/prompt/parser/execution 함수는 현재 production Keeper cycle에
연결되어 있지 않다. 따라서 위 흐름은 typed library contract이지 현재 heartbeat
실행 흐름의 완료 증거가 아니다. 이를 연결하기 전에는 deterministic baseline이나
문자열 heuristic이 model 판단을 대신한다고 주장할 수도, 반대로 매 cycle마다 model
판단이 실행된다고 주장할 수도 없다.

---

## 5. Protocol / Data Flow

### 5.1 keeper_msg (메시지 턴)

1. `handle_keeper_msg` -> `run_turn` 호출
2. `load_context_from_checkpoint`로 세션/컨텍스트 복원
3. `build_keeper_system_prompt` + `build_turn_prompt` callback으로 프롬프트 구성
4. `make_tools` (keeper tool bridge) + `make_hooks` (passive timing/usage/tool-result observation) 생성
5. `Keeper_turn_driver.run_named` -> OAS `Agent.run` loop. OAS Guardrails는 permissive이며 실제 외부 효과 adapter가 실행 직전에 Keeper Gate를 호출
6. `persist_message` (assistant 응답 영속화)
7. 결과 반환: `run_result { response_text, model_used, turn_count, tool_calls_made, usage, tools_used }`

### 5.2 Unified Keeper Turn (heartbeat 경로)

1. `keeper_keepalive` heartbeat tick
2. `world_observation.observe` -> 세계 상태 수집
3. `unified_turn.run_keeper_cycle` -> `build_prompt` + `run_turn`
4. `update_metrics_from_result` -> keeper_meta 갱신
5. `write_meta` -> 메타데이터 영속화

### 5.3 OAS 통합 구성

`run_turn`은 OAS에 `runtime_id`, model-visible `tools`, passive observation
`hooks`, configured `context_reducer`, `initial_messages`를 전달한다. OAS
Guardrails는 permissive이고 hooks는 timing, usage, trajectory, tool outcome을
기록할 뿐 실행 권한을 만들지 않는다. 외부 효과는 MASC adapter가 실제
effect sink 직전에 opaque operation + normalized input으로 Keeper Gate를
호출한다. MASC-owned memory object는 OAS에 투영하지 않는다.

---

## 6. Memory Subsystem

### 6.1 계층 구조

```
keeper_memory.ml (facade)
  |-- keeper_memory_recall.ml (recall scoring, cost calculation)
       |-- keeper_memory_bank.ml (bank persistence, dedup, filtering)
            |-- keeper_memory_policy.ml (retention caps, profile-based selection)
```

### 6.2 Memory Bank

- 저장 경로: `.masc/keeper-memory/{name}/memory_bank.jsonl`
- 레코드 형식: `(kind, text, priority)` 튜플
- Kind 예시: `"goal"`, `"observation"`, `"reflection"`, `"procedure"`
- Dedup: `normalize_memory_text_key`로 공백/구두점 제거 후 비교
- Placeholder 필터: `"none"`, `"null"`, `"없음"` 등은 무의미로 간주하여 제외

### 6.3 Memory Policy

Profile별 종류당 보존 상한:

| Profile | Total cap | Kind caps |
|---------|----------|-----------|
| `aggressive` | 낮음 | 종류별 상한 타이트 |
| `balanced` | 중간 | 기본 |
| `conservative` | 높음 | 종류별 상한 느슨 |

`select_memory_candidates_by_profile`이 profile에 맞게 메모리를 필터링.

### 6.4 Memory Recall

- `is_memory_recall_query`: 사용자 메시지가 기억 관련 질의인지 감지 (한국어 + 영어 needle 매칭)
- `expected_topic_hint`: 질의에서 기대 토픽 추출
- `read_keeper_memory_summary`: memory bank에서 최근 N개 라인 읽어 요약
- Cost 계산: `cost_usd_of_usage`로 모델별 가격 추정

### 6.5 MASC-Owned Memory

`run_turn`은 더 이상 OAS memory object를 만들거나 memory hook을 설치하지 않는다. 기억 기록은 명시적 `keeper_memory_write` 도구와 typed tool-result memory note 경로에서만 수행하며, institution/procedural memory는 MASC 소유 파일/모듈에 머문다.

---

## 7. Evaluation and Verification

### 7.1 Task verification and product judgments

Task completion evidence is assembled by
`lib/workspace/workspace_task_verification.ml` and persisted through the
typed verification-request protocol. Evidence strings are observations; local
substring classifiers do not decide completion.

Model judgment belongs to the product operation that consumes it. Fusion,
Keeper failure judgment, board attention, and Task completion review each own
their prompt, structured schema, and result type. There is no generic
Pass/Warn/Fail action-verifier gate shared across these domains. Cost, token,
turn, and latency values remain observations.

### 7.2 Eval Harness (`lib/eval_harness.ml`)

시나리오 기반 행동 평가. `scenario`(goal + graders + tool expectations) -> `Deterministic`(Exact/Contains/Regex) 또는 `ModelBased`(MODEL 채점) grader -> weight 합산 점수.

### 7.3 Anti-Fake (retired)

테스트 코드 품질 점수화 모듈(`lib/anti_fake.ml`)은 #2848 dead-code sweep에서 제거됐다. 테스트 품질은 현재 alcotest + QCheck assertion 및 CI의 `test_ci_hardening_source.ml` contract test가 담당한다.

### 7.4 Trajectory (`lib/trajectory.ml`)

OAS Invocation이 있는 Tool call을
`.masc/keepers/{name}/trajectories/v1/{trace_id}.jsonl`에 JSONL 기록한다.
MASC `keeper_turn_id`와 OAS `turn + schedule + tool_use_id`를 구분해 그대로
보존하며, `execution_id`만 `Keeper_tool_call_log`와 공유하는 typed join key다.
`tool_use_id`는 비어 있거나 반복될 수 있어 identity가 아니다. 용도는 replay,
결과/latency 관측, eval 입력이다. 모델 usage/cost는 OAS inference
observation에서만 오며 상세 `runtime_contract`와 `action_radius`의 영속 SSOT는
`Keeper_tool_call_log`이므로 trajectory에 복제하지 않는다.

---

## 8. Hooks (OAS Integration)

**소스**: `lib/keeper/keeper_hooks_oas.ml`

OAS Agent.run의 hook lifecycle에 keeper 동작을 주입:

### 8.1 pre_tool_use

| 검사 | 동작 |
|------|------|
| Tool timing | 호출 시작 시각을 기록하고 항상 `Continue`한다. |
| Tool observation | 호출, 결과, latency를 trajectory/ledger/dashboard에 기록한다. 모델 usage/cost는 OAS inference observation으로 별도 기록한다. |
| External effect | hook에서 명령 의미를 분류하지 않는다. normalized Gate 경계가 판정한다. |

`pre_tool_use` hook은 tool 이름과 input 의미를 검사하거나
`Override`/`Block`/`ApprovalRequired`를 반환하지 않는다.

### 8.2 Tool surface projection

`Keeper_tool_descriptor.model_visible_descriptors`가 선언한 모델 이름과 schema는
매 turn 실제 OAS `Tool.t`로 전부 materialize된다. Keeper, runtime, provider,
credential 상태는 이 목록을 줄이지 않으며 per-turn ranking, Top-K, allow/deny
list, affinity, discovery overlay를 적용하지 않는다.

비노출은 동일 capability를 이미 가리키는 exact transport alias와 유효한 canonical
schema가 없는 descriptor에만 허용된다. transport alias는 자신을 대신해 노출되는
정확한 model name을 descriptor evidence에 기록한다.

이 경계가 하는 일은 descriptor/registered handler의 존재와 schema join을 exact
검증하는 것뿐이다. 외부 효과는 tool을 숨겨 예방하지 않고 호출 시 normalized
Gate가 Always Allowed, LLM Auto Judge, 비차단 HITL 중 하나로 결정한다. 외부
dependency가 unavailable이면 해당 handler가 명시적 typed failure를 반환한다.

---

## 9. Configuration

### 9.1 Keeper configuration authority

Typed Keeper configuration is defined by the owning modules under
`lib/keeper/`. The generated operator-facing inventory is
[`docs/runtime-tunables.md`](../runtime-tunables.md); this document does not
duplicate knob names or defaults.

Cost, turn-count, and exact OAS Tool schedule observations do not stop, pause,
or budget a Keeper lifecycle. Provider context and output capacities describe
runtime capabilities and invocation intent; they are not Keeper work gates.

**Context capacity**: compaction/handoff decisions are typed capacity signals. They do not classify model text or infer goals; semantic decisions remain at the model boundary.

### 9.2 TOML Configuration

`config/keepers/*.toml`로 keeper를 선언적으로 정의. 파일명이 keeper 이름. 지원 타입: string, int, float, bool, string array. 테이블은 dotted key로 평탄화. 예시: `config/keepers/janitor.toml`.

### 9.3 Keeper Runtime Spec

Canonical file model:

```text
<basepath>/.masc/config/personas/{name}/profile.json
<basepath>/.masc/config/keepers/{name}.toml
<basepath>/.masc/keepers/{name}.json
<basepath>/.masc/keepers/{name}/...
```

- `profile.json`: identity / persona blueprint
- `keepers/{name}.toml`: deployment declaration for this basepath
- `.masc/keepers/{name}.json`: durable runtime state
- `.masc/keepers/{name}/...`: metrics, decisions, trajectories, checkpoints, and other high-cardinality runtime artifacts

keeper는 durable always-on으로 취급되며, `keeper_up`은 inline args, TOML, persona defaults를 합쳐 초기 `keeper_meta`를 생성한다. runtime 중지 여부는 `paused` 또는 `keeper_down`으로 표현한다.

Authored configuration is read from the persona profile and Keeper TOML only.
`.masc/keepers/{name}.json` stores runtime state; it is not a second editable
configuration source.

---

## 10. Proactive Behavior

Keeper는 idle 상태에서 주기적으로 자발적 행동을 생성한다.

문장 길이, 구두점, 언어별 종결어미, 문자열 유사도는 모델 출력의 품질이나
가시성을 판정하지 않는다. configured LLM이 proactive 행동을 생성하며, 빈 출력과
모델 실패는 관측 가능한 typed 결과로 남는다. 해당 cycle의 실패가 다른 Keeper
lane이나 다음 cycle을 중단시키지 않으며 deterministic reply template로 대체하지
않는다.

---

## 12. Learning System (retired)

전용 learning 모듈(`lib/keeper/keeper_learning.ml`, `keeper_feedback_tool.ml`)은 #2589 dead-module sweep에서 제거됐다. decision_record JSONL 스키마와 `record_decision`/`record_outcome`/`record_feedback` 파이프라인도 runtime에서 사라졌다. 심의 기록은 현재 `keeper_deliberation.ml` + trajectory(`lib/trajectory.ml`) + procedural memory(`lib/procedural_memory.ml`)가 나눠 담당한다.

---

## 13. Skill Routing

**소스**: `lib/keeper/keeper_skill_routing.ml`

Keeper turn에서 어떤 "skill" 경로를 사용할지 결정:

허용 skill 목록: `masc-heartbeat`, `masc-keeper-autonomy`

선택 모드:
- `SkillSelectAgent`: MODEL에 skill 선택을 위임하는 단일 모드

---

## 14. Invariants

### INV-KEEPER-001: keeper_meta.name 유효성

`validate_name`이 공유 portable-name 계약(`[A-Za-z0-9._-]+`, 경로 예약값 `.`/`..` 제외)으로 이름을 검증한다. 빈 문자열, 예약값 또는 특수문자 포함 시 `meta_of_json`이 `Error`를 반환한다.

### INV-KEEPER-002: trace_id 유일성

`generate_trace_id`는 `trace-{ms_timestamp}-{5hex_hash}` 형식으로 생성된다. 동일 밀리초 내에서도 `gettimeofday` hash가 달라 충돌 가능성이 낮다.

### INV-KEEPER-003: checkpoint 최대 3개

`max_checkpoints_retained = 3`. `save` 후 `prune`이 호출되어 초과분을 삭제한다.

### INV-KEEPER-006: proactive judgment boundary

proactive 행동의 의미와 품질은 configured LLM이 판단한다. 문장 종결어미, 단어 목록, 유사도, 재시도 횟수 같은 로컬 휴리스틱은 최종 판정이나 의미 있는 fallback을 만들 수 없다. 빈 출력과 모델 실패는 관측 가능한 오류로 남으며 Keeper의 다른 활동을 중단시키지 않는다.

### INV-KEEPER-007: cost observation

cost, token, turn은 집계와 관측 대상이다. MASC의 임의 임계값이 Keeper 행동을 차단하거나 pause/stop으로 전이시키지 않는다.

Provider가 보고한 token/cache/cost 값은 원값 그대로 ledger, runtime aggregate,
최근 inference entry에 남긴다. `0`과 큰 값은 정상적인 관측이며 로컬 상한으로
누락시키지 않는다. 음수 counter는 원값과 `negative_*` anomaly를 함께 노출한다.
`usage_trust`는 provenance일 뿐 수치를 `0`/`null`로 바꾸거나 cost/token 집계를
건너뛰는 권한이 없다. Provider가 usage 자체를 보내지 않은 경우만 명시적
`usage_missing`/`null`로 표현한다.

### INV-KEEPER-008: non-hierarchical effect Gate

외부 효과는 exact Always Allowed, configured LLM Auto Judge, non-blocking HITL 중 하나로 판정하며, 한 요청의 대기는 다른 Keeper나 작업을 차단하지 않는다.

Gate 입력은 제품·도구·명령·위험 등급을 해석하지 않는 opaque operation과 완전히 정규화된 입력이다. 판정은 exact rule/profile, configured LLM, durable HITL 응답, exact one-shot grant만으로 이루어지고, HITL 완료는 해당 Keeper lane만 깨운다. Executor가 Gate 판정을 뒤집거나 추가로 거부할 수 있는 근거는 typed input, capability identity, path jail, sandbox confinement처럼 실행 시점에 직접 증명되는 불변식뿐이다.

한 번 admit한 User 입력 뒤 `ToolCompleted`가 관측된 같은 턴을 다시 실행하려면, 최신 ToolResult checkpoint를 보존하면서 User 입력을 다시 append하지 않는 typed continuation이 있어야 한다. continuation이 없는 runtime 후보 교체는 현재 턴의 명시적 실패로 끝내고 Keeper lane과 다음 cycle은 계속 사용할 수 있게 한다. 이 조건은 tool 이름, read/write 분류, 명령 의미로 추론하지 않는다.

Filesystem capability는 같은 부모에 동등한 쓰기 권한을 이미 가진 독립 same-UID hostile writer와의 MAC 격리를 제공한다고 주장하지 않는다. 그런 격리가 필요하면 Gate 분류를 추가하지 않고 UID, mount namespace, 또는 exclusive writer 경계에서 제공한다.

### INV-KEEPER-009: fiber_health 정합성

`supervised_state.fiber_health`는 Promise 해소 여부와 동기화된다. Promise resolved + registry에 존재하면 Crashed로 관측하며 해당 lane의 재시작을 계속 시도한다. Dead는 실패 횟수가 아니라 명시적 durable tombstone으로만 성립한다.

### INV-KEEPER-010: UTF-8 안전성

`utf8_safe_prefix_bytes`가 max_bytes에서 UTF-8 코드포인트 경계를 지키며 절단한다. `utf8_repair_string`이 잘못된 바이트를 U+FFFD로 치환한다. Checkpoint 직렬화 시 `sanitize_text_utf8`이 적용된다.

### INV-KEEPER-012: structural execution invariants

실행 경계는 typed argv/input, path jail, sandbox confinement와 같이 객관적으로 검증 가능한 불변식만 강제한다. 명령 문자열이나 도구 이름을 destructive pattern으로 분류하지 않으며, 주관적 실행 판정은 Gate의 LLM 또는 HITL 경계가 담당한다.

---

## 15. Known Issues / Technical Debt

### 15.1 keeper_meta 필드 수 (~100)

`keeper_meta` 레코드가 약 100개 필드를 가지며 `meta_to_json`/`meta_of_json`이 각각 ~200줄이다. 필드 군(group)별 sub-record 분할이 필요하다.

### 15.2 keeper_types.ml include chain

`keeper_types.ml`이 `include Keeper_types_profile`과 `include Keeper_types_support`를 연쇄적으로 포함하여, 실제 타입 정의가 3개 파일에 분산된다. 공개 `keeper_types.mli`는 JSONL/history-source/metrics/API-key/alert-path/rotation/delete-action/trace-path/memory/decision-log support helper를 `Keeper_types_support` 소유로 돌렸지만, 구현 include chain 자체는 남아 있어 가독성이 낮다.

### 15.3 keeper_memory 계층의 include chain

`keeper_memory.ml` -> `keeper_memory_recall.ml` -> `keeper_memory_bank.ml` -> `keeper_memory_policy.ml` 순서로 `include`가 연쇄된다. 각 모듈의 경계가 불명확하다.

### 15.4 Token estimation 정밀도

`msg_tokens = (String.length text / 4) + 4`는 영어 기준 근사치이며, 한국어/CJK 문자에서는 과소 추정한다. BPE 기반 정밀 추정으로의 전환이 필요하다.

### 15.5 Memory Boundary

External memory projection은 제거됐다. 남은 경계 이슈는 keeper context/checkpoint nativeization과 raw marker leakage이며, memory storage 자체는 `Masc.Memory.t`, MASC memory bank, institution, procedural 모듈이 소유한다.

---

## 16. References

| 문서 | 경로 |
|------|------|
| Keeper Types | `lib/keeper/keeper_types.ml` |
| Context Core | `lib/keeper/keeper_context_core.ml` (구 `keeper_working_context.ml` 흡수) |
| Execution Context | `lib/keeper/keeper_context_runtime.ml` |
| Agent Run | `lib/keeper/keeper_agent_run.ml` |
| Unified Turn | `lib/keeper/keeper_unified_turn.ml` |
| Deliberation | `lib/keeper/keeper_deliberation.ml` |
| Task verification evidence | `lib/workspace/workspace_task_verification.ml` |
| OAS hook observations | `lib/keeper/keeper_hooks_oas.ml` |
| Eval Harness | `lib/eval_harness.ml` |
| Trajectory | `lib/trajectory.ml` |
| Supervisor | `lib/keeper/keeper_supervisor.ml` |
| Config | `lib/keeper/keeper_config.ml` |
| TOML Example | `config/keepers/janitor.toml` |
| Memory facade | `lib/memory.mli` |
| Memory: keeper 재설계 | `memory/project_dashboard-keeper-detail-redesign.md` |
