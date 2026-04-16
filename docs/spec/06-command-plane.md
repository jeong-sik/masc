# Command Plane (CPv2)

| 항목 | 값 |
|------|-----|
| Status | Historical Reference |
| Team | Foundation |
| Maps to | `lib/command_plane_v2.ml`, `lib/command_plane/*.ml`, `lib/command_plane_orchestra.ml` |
| Dependencies | 02-types-and-invariants, 03-room-coordination |
| LOC | ~10.3K (core ~8.2K + tool surface ~2.1K) |
| MCP Tools | 40 (unit 4, intent 4, operation 7, dispatch 6, detachment 2, policy 5, observe 6, chain 2, extra 4) |

---

## 1. Purpose

Command Plane V2(CPv2)는 MASC의 현재 supported front door가 아닌 internal/historical reference subsystem이다. 남아 있는 code path, migration context, retained read-model vocabulary를 설명하기 위해 보존하며, 새 caller onboarding은 repo coordination, keeper runtime, dashboard/operator read visibility를 기준으로 한다.

핵심 역할:

- **조직 위계 관리**: Company > Platoon > Squad > Agent_unit 4단계 트리 구조
- **작전 생명주기**: Planned -> Active -> Paused -> Completed/Failed/Cancelled 상태 전이
- **Search Fabric V1**: Bayesian posterior 기반 Unit-Operation 매칭 최적화
- **정책 게이팅**: cross-platoon 재배치, kill-switch 등 위험 작업의 승인 큐
- **Orchestra 시각화**: 전체 시스템을 node/edge/signal 그래프로 투영

---

## 2. Module Dependency Chain

```
Cp_types -> Cp_paths -> Cp_serde -> Cp_io
  -> Cp_cleanup
  -> Cp_unit -> Cp_unit_projection
  -> Cp_snapshot_core -> Cp_snapshot_summaries -> Cp_snapshot
  -> Cp_search_fabric -> Cp_lifecycle_search -> Cp_lifecycle_intents
  -> Cp_lifecycle -> Cp_lifecycle_policy
```

`Command_plane_v2`는 `Cp_lifecycle_policy`를 `include`하는 backward-compatible facade이다. 외부 모듈(`tool_command_plane`, `operator_control`, `swarm_status`)은 이 facade를 통해 접근한다.

`Command_plane_orchestra`는 별도 모듈로, CPv2 snapshot + Swarm status + Operator state를 node-edge-signal 그래프로 합성한다.

---

## 3. Core Concepts

### 3.1. Unit

조직 단위. 4-level 트리 구조를 형성한다.

| Kind | Policy Class | Autonomy Default | Headcount Cap |
|------|-------------|-----------------|---------------|
| `Company` | strategic | L5_Independent | 128 |
| `Platoon` | tactical | L4_Autonomous | 32 |
| `Squad` | execution | L3_Guided | 8 |
| `Agent_unit` | worker | L2_Suggestive | 1 |

**구조 규칙**:

- Company는 parent를 가질 수 없다 (root)
- Platoon은 Company 아래에만 배치 가능
- Squad는 Company 또는 Platoon 아래
- Agent_unit은 Squad 아래에만

**자동 생성**: managed unit이 없거나 root가 여러 개이면 `company-runtime` 자동 생성. 할당되지 않은 live agent는 `squad-unassigned`에 배치된다.

**Unit Record 주요 필드**:
- `unit_id`, `label`, `kind`, `parent_unit_id`
- `leader_id`, `roster` (agent 목록)
- `capability_profile` (태그 기반: `runtime:xxx`, `model:xxx`, `tool:xxx`)
- `policy` (policy_envelope), `budget` (budget_envelope)

#### Policy Envelope

```ocaml
type policy_envelope = {
  policy_class : string;       (* strategic | tactical | execution | worker *)
  approval_class : string;     (* strict | guarded *)
  tool_allowlist : string list;
  model_allowlist : string list;
  requires_human_for : string list;
  autonomy_level : string;     (* L2..L5 *)
  escalation_timeout_sec : int;
  kill_switch : bool;
  frozen : bool;
}
```

#### Budget Envelope

```ocaml
type budget_envelope = {
  headcount_cap : int;
  active_operation_cap : int;
  max_cost_usd : float;
  max_tokens : int;
}
```

### 3.2. Operation

지휘 통제의 실행 단위. 목표(objective)를 Unit에 할당하고, 상태를 추적한다.

**Operation Status 상태 전이**:

```
Planned -> Active -> Paused -> Active (resume)
                  -> Completed (finalize)
                  -> Failed
                  -> Cancelled (stop)
```

**Operation Record 주요 필드** (22개):
- `operation_id`, `objective`, `assigned_unit_id`, `trace_id`
- `intent_id` (optional, Intent와 연결)
- `workload_profile`: `coding_task` | `research_pipeline`
- `workload_template`: `coding_team` | `research_team` | `ops_governance_team`
- `stage`: workload에 따른 단계 (coding: decompose/inspect/implement/verify/review)
- `search_strategy`: `best_first_v1` | `legacy`
- `chain`: 선택적 Chain Engine 연결 (chain_record)
- `checkpoint_ref`: 검증 지점 참조
- `detachment_session_id`: Team Session 연결

**Workload Profile별 Stage Graph**:

| Profile | Stages |
|---------|--------|
| `coding_task` | decompose -> inspect -> implement -> verify -> review |
| `research_pipeline` | normalize -> verify -> curate -> rank -> audit |

`coding_task`의 `verify` stage는 `implement` dependency를 필수로 요구하고, `review`는 `verify` dependency를 요구한다.

### 3.3. Intent

Operation 위에 위치하는 목표 추적 단위. 여러 Operation을 하나의 의도 아래 묶는다.

**Intent State**: Adopted -> Active_intent -> Blocked_intent -> Suspended_intent -> Handoff_ready -> Completed_intent -> Dropped_intent

Intent는 `workload_profile`, `success_metric`, `invariants`, `artifact_priors`, `current_focus`를 보유한다. Operation 상태 변화 시 연결된 Intent 상태가 자동 갱신된다.

### 3.4. Detachment

Operation에서 파생되는 실행 파견 단위. Operation이 활성화되면 할당된 Unit의 roster와 leader를 기반으로 Detachment가 자동 생성(`sync_managed_detachments`)된다.

주요 필드: `detachment_id`, `operation_id`, `assigned_unit_id`, `leader_id`, `roster`, `session_id`, `runtime_kind`, `runtime_ref`, `heartbeat_deadline`.

### 3.5. Policy Decision

위험 작업(cross-platoon move, kill-switch, freeze)에 대한 승인 큐. `pending` -> `approved`/`denied`/`expired` 상태를 거친다. TTL 기반 자동 만료가 적용된다.

### 3.6. Trace (Event)

모든 CPv2 변경은 `events.jsonl`에 append-only로 기록된다. 각 event는 `event_id`, `trace_id`, `event_type`, `operation_id`, `unit_id`, `actor`, `ts`, `detail`을 포함한다. trace_id로 Operation의 전체 생애를 추적할 수 있다.

---

## 4. Persistence

### 4.1. Canonical Paths

모든 CP 데이터는 `.masc/control-plane/` 디렉터리에 JSON/JSONL로 저장된다.

| Path | Format | Entity |
|------|--------|--------|
| `units.json` | JSON (versioned wrapper) | Unit records |
| `operations.json` | JSON (versioned wrapper) | Operation records |
| `intents.json` | JSON (versioned wrapper) | Intent records |
| `detachments.json` | JSON (versioned wrapper) | Detachment records |
| `decisions.json` | JSON (versioned wrapper) | Policy decision records |
| `events.jsonl` | JSONL (append-only) | Event log |
| `search-stats.json` | JSON | Search Fabric stats |
| `traces/` | Directory | Trace artifacts |
| `archive/operations.json` | JSON | Archived terminal operations |
| `swarm-live/` | Directory | Swarm live artifacts per run |

### 4.2. I/O Layer (`cp_io.ml`)

모든 read/write는 `Cp_io`를 경유한다. `ensure_dirs`로 디렉터리 존재를 보장한다. JSON wrapper는 항상 `{"version": "cp-v2", "updated_at": "...", "<entity>": [...]}` 형태를 유지한다.

Event ID 생성: `{prefix}-{unix_ms}-{random_hex4}` (예: `op-1711234567890-a3f2`)

---

## 5. Snapshot System

### 5.1. snapshot_state

6개 데이터 섹션을 하나의 레코드로 합성한다.

```ocaml
type snapshot_state = {
  config : Room.config;
  agents : Types.agent list;
  managed_units : unit_record list;
  units : unit_record list;       (* managed + auto-generated *)
  source : string;                (* "auto" | "hybrid" | "explicit" *)
  sessions : session list;        (* capped at 50 *)
  intents : intent_record list;
  operations : operation_record list;
  detachments : detachment_record list;
  decisions : policy_decision_record list;
  live_agents : string list;
  status_map : (string * string) list;
  child_map : (string * unit_record list) list;
  unit_lookup : (string * unit_record) list;
}
```

### 5.2. Section Cache

`section_cache`는 mutable record로, 각 섹션별 file mtime을 추적하여 변경된 파일만 re-read한다. heartbeat 등의 빈번한 변경이 전체 재빌드를 유발하지 않도록 incremental update를 수행한다 (5초 full rebuild -> sub-100ms).

6개 섹션: topology(units+agents), sessions, intents, operations, detachments, decisions. 각 섹션은 자신의 의존 섹션 mtime도 추적한다 (예: operations는 topology, sessions 변경 시 재계산).

### 5.3. Summary Outputs

`summary_json`은 7개 하위 요약(topology, intents, operations, detachments, alerts, decisions, swarm_proof)을 합성한다.

Alerts는 Unit 상태(leader_missing, roster_offline, headcount_cap_exceeded 등)와 Operation 상태(orphaned_operation, detachment_quiet)에서 파생된다. severity 기반 정렬: bad > warn. 6h+ quiet detachment는 critical로 승격.

---

## 6. Search Fabric V1

### 6.1. Strategy

| Strategy | 설명 |
|----------|------|
| `legacy` | 단순 후보 필터링, score 없음 |
| `best_first_v1` | 10차원 weighted scoring, Bayesian posterior |

`best_first_v1`이 기본값. `legacy`는 explicit opt-out.

### 6.2. Score Breakdown (10 dimensions)

```ocaml
type score_breakdown = {
  capability_match : float;        (* max 25.0 — keyword overlap + stage bonus *)
  artifact_locality : float;       (* max 20.0 — artifact scope keyword match *)
  intent_successor : float;        (* reserved, 0.0 *)
  verification_readiness : float;  (* reserved, 0.0 *)
  runtime_fit : float;             (* max 15.0 — runtime/model/tool tag match *)
  posterior_success : float;       (* max 15.0 — Beta(alpha, beta) posterior mean *)
  capacity_headroom : float;       (* max 10.0 — free slots / cap ratio *)
  cost_efficiency : float;         (* max 5.0 — local/cheap model hints *)
  queue_age : float;               (* max 5.0 — operation age normalized to 1h *)
  stickiness : float;              (* 5.0 if current assignment, else 0.0 *)
  total : float;
}
```

### 6.3. Bayesian Success Tracking

`stats_store`는 `(unit_id, workload_profile, stage)` 키별로 `alpha`, `beta` 파라미터를 유지한다. `posterior_mean = alpha / (alpha + beta)` (Beta distribution). Operation checkpoint 시 success, failure 시 beta를 +1.0 업데이트한다.

### 6.4. Readiness

Operation의 `depends_on_operation_ids`를 기반으로 upstream dependency가 완료(completed) 또는 checkpoint 존재 시 Ready, 아니면 Blocked.

---

## 7. Lifecycle Management

### 7.1. Operation Lifecycle

`start_operation`: validation chain 실행.

1. `assigned_unit_id` 존재 확인 (unit_guard)
2. `workload_template` -> `workload_profile` + `stage` 추론
3. `workload_profile` 유효성 검증
4. `stage` 유효성 검증 (workload별 허용 stage)
5. `search_strategy` 유효성 검증
6. `intent_id` 존재 + workload_profile 일치 검증
7. `coding_task` verify/review의 dependency 요건 검증
8. chain record 파싱
9. Operation 생성, Detachment 동기화, Event 기록

`checkpoint_operation`: checkpoint_ref 저장 + best_first_v1이면 search stats 업데이트 (success).

`update_operation_status`: status 전이 + chain status 연동 + intent state 갱신 + detachment 동기화.

### 7.2. Policy Lifecycle

`create_policy_decision`: TTL 기반 expires_at 설정, pending 상태로 생성.
`check_expired_decisions`: pending + expires_at < now인 decision을 expired로 전환.
`check_blocked_intents`: Blocked_intent가 timeout_sec을 초과하면 Dropped_intent로 전환.

### 7.3. Cleanup (`cp_cleanup.ml`)

5단계 순차 정리:

1. **Dead units**: 빈 roster + leader 없음 + stale(N일 초과) -> 삭제
2. **Orphaned units**: parent가 존재하지 않는 unit -> 삭제
3. **Terminal operations**: Completed/Cancelled/Failed + stale -> archive로 이동
4. **Orphaned detachments**: operation_id가 존재하지 않는 detachment -> 삭제
5. **Dropped intents**: Dropped_intent + stale -> 삭제

`Room_hooks.cp_cleanup_fn` ref callback으로 Room_gc에서 호출되어 순환 의존을 회피한다.

---

## 8. Orchestration (`command_plane_orchestra.ml`)

전체 시스템 상태를 `orchestra.v1` 형식의 그래프로 합성한다.

### 8.1. Node Types

| Kind | Visual Class | Source |
|------|-------------|--------|
| `room` | room-core | Room state |
| `session` | session-island | Team sessions |
| `operation` | operation-core | Active CP operations |
| `detachment` | detachment-shell | Active detachments |
| `lane` | worker-lane / control-lane | Swarm worker lanes |
| `worker` | worker-unit | Actual swarm workers |
| `worker` (ghost) | worker-ghost | Planned but not yet spawned |
| `keeper` | continuity-keeper | Keeper agents |

각 node는 `id`, `kind`, `label`, `tone` (ok/warn/bad), `pulse` (steady/pulse/blink/flow), `provenance` (truth/derived/fallback), `facts`, `link_tab`, `link_surface` 속성을 가진다.

### 8.2. Edge Types

`contains`, `attached`, `materializes`, `routes`, `feeds`, `planned`, `continuity` 등으로 node 간 관계를 표현한다.

### 8.3. Signals

Alert, pending confirm, runtime blocker, hot proof 등 비정상 상태를 signal로 발행한다. Focus는 bad signal > unhealthy session > room 순서로 결정된다.

---

## 9. MCP Tool Surface

### 9.1. Unit Management (4)

| Tool | 동작 |
|------|------|
| `masc_unit_define` | Unit 생성/수정 (kind, label, roster, policy, budget) |
| `masc_unit_list` | Managed + effective units 조회 |
| `masc_unit_reparent` | Unit parent 변경 |
| `masc_unit_reassign` | Unit leader/roster 변경 |

### 9.2. Intent Management (4)

| Tool | 동작 |
|------|------|
| `masc_intent_create` | Intent 생성 |
| `masc_intent_status` | Intent 상태 조회 |
| `masc_intent_update` | Intent 상태/focus 갱신 |
| `masc_intent_forecast` | Intent 예측 |

### 9.3. Operation Management (7)

| Tool | 동작 |
|------|------|
| `masc_operation_start` | Operation 생성 + validation chain |
| `masc_operation_status` | Operation 상태 조회 (card with search context) |
| `masc_operation_checkpoint` | Checkpoint 기록 + search stats 갱신 |
| `masc_operation_pause` | Active -> Paused |
| `masc_operation_resume` | Paused -> Active |
| `masc_operation_stop` | -> Cancelled |
| `masc_operation_finalize` | -> Completed + search stats 갱신 |

### 9.4. Dispatch (6)

| Tool | 동작 |
|------|------|
| `masc_dispatch_plan` | Search Fabric 기반 후보 scoring + 추천 |
| `masc_dispatch_assign` | Operation을 다른 Unit으로 재할당 |
| `masc_dispatch_rebalance` | 자동 재분배 |
| `masc_dispatch_escalate` | 상위 Unit으로 에스컬레이션 |
| `masc_dispatch_recall` | Detachment 회수 |
| `masc_dispatch_tick` | 주기적 상태 갱신 |

### 9.5. Policy (5)

| Tool | 동작 |
|------|------|
| `masc_policy_status` | 보류 중인 decision 조회 |
| `masc_policy_approve` | Decision 승인 |
| `masc_policy_deny` | Decision 거절 |
| `masc_policy_update` | Unit policy 직접 변경 |
| `masc_policy_freeze_unit` / `masc_policy_kill_switch` | Unit 동결/비상 정지 |

### 9.6. Observe (6)

| Tool | 동작 |
|------|------|
| `masc_observe_topology` | Unit 트리 + health + operation count |
| `masc_observe_alerts` | Alert 목록 (severity 정렬) |
| `masc_observe_operations` | Operation 요약 + microarch |
| `masc_observe_capacity` | Unit별 utilization |
| `masc_observe_traces` | Event log + team session + operator traces |

---

## 10. Known Issues and Limitations

| Issue | 설명 | Status |
|-------|------|--------|
| Search Fabric reserved dimensions | `intent_successor`, `verification_readiness`가 항상 0.0 | Reserved |
| Cleanup callback indirection | Room_gc -> Room_hooks ref callback으로 순환 의존 회피. 직접 호출 불가 | Architectural |
| Section cache mutable state | `section_cache`가 mutable record. 멀티 쓰레드 안전하지 않으나 Eio single-domain에서는 문제 없음 | By design |
| orchestra.ml LOC | ~800줄. node builder + edge wiring이 같은 함수에 혼재 | Split candidate |

---

## 11. Configuration

| Env / Config | 기본값 | 설명 |
|-------------|--------|------|
| `Env_config_runtime.Cp.cleanup_days` | (configurable) | Stale 판정 기준 일수 |
| `Env_config.Decision.ttl_seconds` | (configurable) | Policy decision 만료 시간 |
| Room state `search_strategy_default` | `best_first_v1` | Room별 기본 search strategy |
| Room state `speculation_enabled` | false | 추측적 실행 활성화 |
| Room state `speculation_budget` | 2 | 추측적 실행 예산 |
