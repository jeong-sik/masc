---
status: reference
last_verified: 2026-04-22
code_refs:
  - lib/coord/
  - lib/coord_goals.ml
  - lib/goal/
  - lib/tool_task.ml
  - lib/tool_agent.ml
  - lib/tool_worktree.ml
  - lib/tool_control.ml
  - lib/tool_schemas/tool_schemas_coord_extra.ml
---

# Room Coordination

| 항목 | 값 |
|------|-----|
| Status | Draft |
| Team | Room |
| Maps to | `lib/coord/` (sub-library, ~7.6K LOC) |
| Dependencies | 02-types-and-invariants |
| Modules | 20 (.ml) + 4 (.mli) |
| LOC | ~7,653 |
| MCP Tools | `tool_task`, `tool_agent`, `tool_worktree`, `tool_control` |

---

## 1. Purpose

Room은 MASC의 핵심 조율 단위다. 에이전트가 참여(join)하고, 태스크를 등록/할당받고, 하트비트로 활성 상태를 유지하며, 투표/합의로 의사결정하고, git worktree로 작업을 격리하는 공간.

Room 하나가 소유하는 것:
- **state**: `room_state` 레코드 (protocol version, active agents, message seq, pause flag)
- **agents**: `.masc/agents/` 디렉토리 내 JSON 파일 (또는 PG `masc_kv`)
- **tasks**: `.masc/tasks/backlog.json` (또는 PG) -- 태스크 큐와 스케줄링
- **messages**: `.masc/messages/` -- broadcast 메시지 저장
- **votes**: `.masc/votes/` -- 투표 데이터
- **portals**: `.masc/portals/` + `.masc/a2a_tasks/` -- A2A 통신

---

## 2. Architecture

```mermaid
graph TB
  subgraph "Room Sub-library (masc_room)"
    RS[room_state] --> RI[room_init]
    RS --> RL[room_lifecycle<br>join / leave]
    RS --> RA[room_agent<br>status / caps]
    RS --> RT[room_task<br>add / claim / transition]
    RT --> RTS[room_task_schedule<br>claim_next / stale]
    RS --> RGC[room_gc<br>zombie / archive]
    RS --> RV[room_vote<br>create / cast]
    RS --> RWT[room_worktree<br>create / remove]
    RWT --> RG[room_git<br>git ops]
    RS --> RP[room_portal<br>A2A]
    RS --> RM[room_multi<br>slug / registry]
    RM --> RR[room_rooms<br>list / create / enter]
    RS --> RTE[room_tempo<br>pace control]
    RS --> RCP[room_checkpoint<br>snapshot]
  end

  subgraph "Support Modules"
    HB[heartbeat] --> HBS[heartbeat_smart]
    RES[resilience<br>zombie detect]
    MEN[mention<br>@routing]
    NICK[nickname<br>adj-animal gen]
  end

  subgraph "MCP Tool Layer"
    TR[tool_room] --> RS
    TT[tool_task] --> RT
    TA[tool_agent] --> RA
    TH[tool_heartbeat] --> HB
    TW[tool_worktree] --> RWT
    TC[tool_control<br>pause/resume] --> RI
    TS[tool_social<br>vote] --> RV
  end
```

### Module Size Distribution (상위 10, `lib/coord/`)

| Module | LOC | 역할 |
|--------|-----|------|
| `coord_task` | 1486 | 태스크 CRUD + 상태 전이 |
| `coord_eio` | 670 | Eio 백엔드 구현 (direct-style async I/O) |
| `coord_utils_ops` | 513 | file lock + PG 공통 연산 |
| `coord_gc` | 413 | 좀비 정리, stale 아카이브, 메시지 정리 |
| `coord_worktree` | 403 | task worktree 관리 |
| `coord_utils_backend_setup` | 396 | PG 백엔드 설정 |
| `coord_query` | 373 | 룸 내 에이전트/태스크 카운트 쿼리 |
| `coord_task_schedule` | 337 | claim_next, starvation prevention |
| `coord_utils_paths_backend` | 261 | 경로/백엔드 리졸버 |
| `coord_portal` | 261 | 1:1 portal messaging |

---

## 3. Types

### 3.1 Room State (`room_state`)

```ocaml
type room_state = {
  protocol_version : string;       (* "0.1.0" *)
  project : string;                (* base_path basename *)
  started_at : string;             (* ISO 8601 *)
  message_seq : int;               (* broadcast 시퀀스 *)
  active_agents : string list;     (* 현재 참여 에이전트 닉네임 *)
  paused : bool;
  pause_reason : string option;
  paused_by : string option;
  paused_at : string option;
  search_strategy_default : string option;  (* "best_first_v1" | "legacy" *)
  speculation_enabled : bool;
  speculation_budget : int option;
}
```

### 3.2 Agent (in room)

```ocaml
type agent = {
  name : string;           (* nickname: "claude-swift-fox" *)
  agent_type : string;     (* base type: "claude", "gemini" *)
  status : agent_status;   (* Active | Busy | Inactive *)
  capabilities : string list;
  current_task : string option;
  joined_at : string;
  last_seen : string;      (* heartbeat 갱신 대상 *)
  meta : agent_meta option;
}

type agent_meta = {
  session_id : string;
  agent_type : string;
  pid : int option;
  hostname : string option;
  tty : string option;
  worktree : string option;
  parent_task : string option;
}
```

### 3.3 Task Status (ADT)

```ocaml
type task_status =
  | Todo
  | Claimed of { assignee : string; claimed_at : string }
  | InProgress of { assignee : string; started_at : string }
  | Done of { assignee : string; completed_at : string; notes : string option }
  | Cancelled of { cancelled_by : string; cancelled_at : string; reason : string option }
```

### 3.4 Room Info (registry entry)

```ocaml
type room_info = {
  id : string;              (* slugified name *)
  name : string;
  description : string option;
  created_at : string;
  created_by : string option;
  agent_count : int;
  task_count : int;
}
```

### 3.5 Tempo Config

```ocaml
type tempo_mode = Normal | Slow | Fast | Paused

type tempo_config = {
  mode : tempo_mode;
  delay_ms : int;           (* Normal=0, Slow=2000, Fast=0, Paused=0 *)
  reason : string option;
  set_by : string option;
  set_at : string option;
}
```

---

## 4. State Machines

### 4.1 Room Lifecycle

```
[not_initialized] --init--> [active] --pause--> [paused] --resume--> [active]
                                                                  \--reset--> [not_initialized]
```

- `init`: `.masc/` 디렉토리 구조 생성 (agents/, tasks/, messages/), `room_state` 초기화
- `pause`: `paused = true` 설정, broadcast 통보, orchestrator가 새 에이전트 스폰 중단
- `resume`: `paused = false`, broadcast 통보
- `reset`: `.masc/` 전체 삭제 (확인 필수)

### 4.2 Agent in Room

```
           join (new)
[absent] ---------> [Active] <--heartbeat-- (last_seen 갱신)
   ^                   |
   |              task claim
   |                   v
   |                [Busy] --task done/release--> [Active]
   |                   |
   |              leave / timeout
   |                   v
   '---- gc ----  [Inactive] --rejoin--> [Active]
```

- `join`: 닉네임 생성 (Docker-style: `{type}-{adj}-{animal}`), 에이전트 JSON 기록, `active_agents` 갱신
- `rejoin`: 기존 닉네임 재사용, `Inactive -> Active`, `last_seen` 갱신
- `heartbeat`: `last_seen` 타임스탬프만 갱신 (file lock 보호)
- `leave`: heartbeat 중단, 에이전트 파일 삭제, `active_agents` 제거
- `zombie detect`: `last_seen` 기준 threshold 초과 시 GC 대상

### 4.3 Task Lifecycle

```
                add_task
[backlog] ---------> [Todo] --claim--> [Claimed] --start--> [InProgress]
                       |                  |                      |
                       |                  |--release--> [Todo]   |--release--> [Todo]
                       |                  |                      |
                       '--cancel--> [Cancelled]   done -------> [Done]
                                          ^                      |
                                          '--cancel--------------'
```

**전이 규칙** (`transition_task_r`):

| 현재 | action | 조건 | 다음 |
|------|--------|------|------|
| Todo | claim | - | Claimed |
| Todo | cancel | - | Cancelled |
| Claimed | start | assignee == agent | InProgress |
| Claimed | release | assignee == agent OR force | Todo |
| Claimed | done | assignee == agent OR force | Done |
| Claimed | cancel | assignee == agent OR force | Cancelled |
| InProgress | release | assignee == agent OR force | Todo |
| InProgress | done | assignee == agent OR force | Done |
| InProgress | cancel | assignee == agent OR force | Cancelled |

- `force = true`는 keeper GC가 고아(orphan) 태스크를 해제할 때 사용
- 태스크에 `required_role`이 설정된 경우, `claim`에서 `agent_role` 일치 검사 수행
- 모든 전이는 `backlog.version + 1`로 버전 증가 (optimistic concurrency)
- `expected_version` 옵션으로 CAS(compare-and-set) 가능

### 4.4 Task Scheduling (`room_task_schedule`)

`claim_next_r` 알고리즘:

1. **Auto-release**: 현재 에이전트가 보유한 Claimed/InProgress 태스크를 자동 해제 (BUG-004 수정)
2. **Stale archive**: `stale_threshold_days`(기본 7일) 초과 Todo 태스크 자동 아카이브
3. **Starvation prevention**: 24시간 대기 시 priority boost (-1/24h, min 1)
4. **정렬**: effective priority 오름차순, 동일 priority 내 FIFO (older first)
5. **제외 목록**: `exclude_task_ids` + 직전 auto-release된 태스크

---

### 4.5 Goal Planning FSM

Planning의 Goal Store는 task lifecycle과 별개의 Goal-native FSM을 가진다. source of truth는 legacy `status`가 아니라 explicit `phase`다.

```ocaml
type goal_phase =
  | Executing
  | Awaiting_verification
  | Awaiting_approval
  | Blocked
  | Paused
  | Completed
  | Dropped
```

핵심 필드:
- `goal.phase`: 실제 Goal FSM 상태
- `goal.status`: coarse compatibility projection (`active | paused | done | dropped`)
- `goal.verifier_policy`: parent inheritance + local override가 가능한 verifier roster / quorum 설정
- `goal.require_completion_approval`: verification 통과 후 operator approval gate 필요 여부

도구 surface:
- `masc_goal_list`: `phase` 기준 조회를 우선 지원하고, `status`는 compatibility alias로만 유지
- `masc_goal_upsert`: goal metadata + verifier policy 설정
- `masc_goal_transition`: explicit Goal FSM action (`request_complete`, `pause`, `resume`, `operator_block`, `approve_completion`, ...)
- `masc_goal_verify`: open verification request에 대한 1 principal 1 vote
- `masc_goal_review`: legacy wrapper. 새 lifecycle / quorum flow의 정식 surface는 아님

전이 요약:

| 현재 | action | 다음 | 메모 |
|------|--------|------|------|
| `executing` | `request_complete` | `completed` | verifier policy도 approval gate도 없을 때 |
| `executing` | `request_complete` | `awaiting_verification` | quorum verification request snapshot 생성 |
| `awaiting_verification` | quorum pass | `awaiting_approval` or `completed` | approval 요구 여부에 따라 분기 |
| `awaiting_verification` | quorum fail | `executing` | goal은 다시 실행 상태로 복귀 |
| `awaiting_approval` | `approve_completion` | `completed` | verification 이후 최종 operator gate |
| `awaiting_approval` | `reject_completion` | `blocked` | approval rejection은 blocked로 이동 |
| `blocked` | `operator_unblock` | `executing` | 재실행 가능 |

Goal verification은 기존 task verification과 저장/판정 모델이 다르다:
- task verification: criteria 기반 request evaluation
- goal verification: operator / keeper mixed principals의 N-of-M quorum voting

따라서 Goal verification은 task verification storage를 재사용하지 않고 `lib/goal/goal_verification.ml`의 sibling subsystem으로 유지한다.

---

## 5. Heartbeat Protocol

### 5.1 Basic Heartbeat

`Heartbeat.t` 레코드로 관리. `start`로 등록, `stop`으로 해제, `stop_by_agent`로 에이전트 전체 정리.

```ocaml
type t = {
  id : string;
  agent_name : string;
  interval : int;          (* seconds *)
  message : string;
  mutable active : bool;
  created_at : float;
}
```

### 5.2 Smart Heartbeat (`heartbeat_smart.mli`)

토큰 절약을 위한 적응형 하트비트. OpenClaw 스타일.

```ocaml
type decision =
  | Emit                        (* 지금 하트비트 전송 *)
  | Skip_busy                   (* 에이전트가 작업 중 -- 100% skip *)
  | Skip_idle of float          (* idle 구간 -- 3x 간격 적용, 다음 emit 시각 *)
```

**구성**:
- `base_interval_s`: 30초 (기본값)
- `idle_multiplier`: 3.0 (idle > 5분 시 90초 간격)
- `busy_skip`: true (Busy 상태면 하트비트 생략)
- `idle_threshold_s`: 300초 (5분)

**절감 효과**:
- 작업 중 에이전트: 100% skip
- 5분+ idle 에이전트: 33% emission (3x interval)

### 5.3 Zombie Detection (`resilience.mli`)

```ocaml
module Zombie : sig
  val is_zombie : ?threshold:float -> string -> bool
  val is_zombie_for_agent : agent_name:string -> string -> bool
  val is_keeper : name:string -> agent_type:string -> bool
end
```

- 일반 에이전트 기본 threshold: 300초 (5분)
- Keeper 에이전트 threshold: 3600초 (1시간) -- keeper는 장기 실행
- `is_keeper` 판별: `"keeper-*-agent"` 이름 패턴 OR `agent_type = "keeper"`

### 5.4 Zero-Zombie Protocol

`Resilience.ZeroZombie` 모듈: Eio 백그라운드 루프로 자동 정리.

```ocaml
val run_loop :
  ?interval:float ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  cleanup_fn:(unit -> string list) ->
  unit -> unit
```

- 주기적으로 `cleanup_fn` 호출, 정리된 에이전트 이름 반환
- `global_stats`로 cleanup 횟수/최근 정리 대상 추적
- `is_benign_error`: 시작 시 미초기화 에러 무시

---

## 6. Garbage Collection (`room_gc`)

5단계 파이프라인:

| Phase | 동작 | 실패 시 |
|-------|------|---------|
| 1. Detect | 좀비 에이전트 탐지 (threshold 기반) | - |
| 2. Transition | 상태를 Inactive로 전이, heartbeat 중단 | Inactive + in-list (self-healing) |
| 3. Release | 좀비가 보유한 태스크를 Todo로 해제 | 해당 에이전트 파일 삭제 건너뜀 |
| 4. Delete | 에이전트 JSON 파일 삭제 | 로그 경고 |
| 5. Update | `active_agents`에서 제거 | - |

`gc` 함수는 추가로:
- 오래된 Todo 태스크 아카이브 (N일 기준)
- 오래된 메시지 삭제 (open task 참조 메시지는 보존)
- Board artifact 정리, governance purge (Room_hooks 콜백)

---

## 7. Voting & Consensus

### 7.1 Room Vote (`room_vote`)

단순 다수결 투표 시스템.

```
vote_create -> vote_cast (N회) -> auto-resolve
```

- **상태**: `VotePending | VoteApproved | VoteRejected | VoteTied`
- `required_votes` 도달 시 자동 해결
- 각 에이전트는 1표만 행사 (중복 투표 거부)
- 투표 데이터: `.masc/votes/{vote_id}.json`

## 8. Mention Routing (`mention`)

@mention 기반 메시지 라우팅.

```ocaml
type mode =
  | Stateless of string    (* @agent -> 가용한 에이전트 중 1명 *)
  | Stateful of string     (* @agent-adj-animal -> 특정 에이전트 *)
  | Broadcast of string    (* @@agent -> 해당 타입 전체 *)
  | None                   (* mention 없음 *)
```

**파싱 우선순위**: `@@agent` > `@agent-adj-animal` > `@agent`

`resolve_targets`: mode + available_agents -> target 목록
- Stateless: agent_type 일치하는 첫 번째 에이전트
- Stateful: 닉네임 정확 일치
- Broadcast: agent_type 일치하는 전체

---

## 9. Git Operations (`room_worktree`)

에이전트별 git worktree 격리.

### 9.1 Worktree Create

```
worktree_create_r ~agent_name ~task_id ~base_branch
```

1. git 저장소 검증 (`.git` 존재 확인)
2. worktree 경로 생성: `.worktrees/{agent_name}-{task_id}`
3. branch 이름: `{agent_name}/{task_id}`
4. `git fetch origin` -> `git worktree add` (base branch에서 분기)
5. 에이전트 `current_task` 갱신
6. 태스크 backlog에 `worktree_info` 연결 (`link_task` 옵션)

### 9.2 Worktree Remove

```
worktree_remove_r ~agent_name ~task_id
```

- `git worktree remove --force`
- 로컬 브랜치 삭제

### 9.3 Task Sandbox (`task_sandbox`)

`Room_worktree` 위에 고수준 샌드박스 생명주기를 제공.

```ocaml
type sandbox = {
  task_id : string;
  worktree_path : string;
  branch_name : string;
  created_at : float;
}
```

- 샌드박스 생성 -> 작업 실행 -> diff 수집 -> 정리

---

## 10. Multi-Room & Federation

### 10.1 Room Registry (`room_multi`, `room_rooms`)

- Room ID: `slugify(name)` (소문자, alphanumeric + dash)
- Registry: `.masc/rooms/registry.json`
- Current room: `.masc/current_room` 파일 (mtime 캐싱)
- `"default"` room은 항상 존재 (registry에 없어도 자동 포함)

**작업 흐름**:
```
set_room(path) -> write/read current_room -> current-room-scoped task/agent/message operations
```

### 10.2 Portal (A2A, `room_portal`)

에이전트 간 직접 통신 채널.

```ocaml
type portal = {
  portal_from : string;
  portal_target : string;
  portal_opened_at : string;
  portal_status : portal_status;   (* PortalOpen | PortalClosed *)
  task_count : int;
}
```

- `portal_open_r`: 양방향 포탈 생성 (reverse portal 자동)
- A2A task: 포탈을 통한 메시지 교환 (pending -> accepted -> completed)
- 데이터: `.masc/portals/`, `.masc/a2a_tasks/`

---

## 11. Checkpoint (`room_checkpoint.mli`)

Room 전체 스냅샷 캡처 및 복원.

```ocaml
type t = Yojson.Safe.t

val capture : room_state:Yojson.Safe.t -> tasks:Yojson.Safe.t -> agents:Yojson.Safe.t -> t
val timestamp : t -> float
val room_state : t -> Yojson.Safe.t option
val tasks : t -> Yojson.Safe.t option
val agents : t -> Yojson.Safe.t option
val diff : t -> t -> Yojson.Safe.t     (* 두 checkpoint 간 차이 *)
val to_string : t -> string
val of_string : string -> t option
```

- 실패 작업 후 rollback 지원
- JSON 직렬화로 저장/복원

---

## 12. Tempo (`room_tempo`)

클러스터 전체 에이전트 페이싱 제어.

| Mode | delay_ms | 용도 |
|------|----------|------|
| Normal | 0 | 기본 동작 |
| Slow | 2000 | 신중한 작업, 디버깅 |
| Fast | 0 | 제한 없음 |
| Paused | 0 | 에이전트 일시 정지 |

`set_tempo`는 broadcast로 전체 에이전트에 통보.

---

## 13. Concurrency Model

### 13.1 File Locking

`with_file_lock config path fn`: 파일 단위 lock으로 원자적 read-modify-write.
- backlog 갱신, 에이전트 상태 갱신 등 모든 mutation에 적용
- PG 백엔드 사용 시에도 filesystem lock 유지 (dual-write)

### 13.2 State Persistence

| 대상 | Filesystem | PostgreSQL |
|------|-----------|-----------|
| Room state | `.masc/state.json` | `masc_kv[room:state]` |
| Agent | `.masc/agents/{nick}.json` | `masc_kv[agents:{nick}]` |
| Backlog | `.masc/tasks/backlog.json` | (filesystem only) |
| Messages | `.masc/messages/*.json` | (filesystem only) |

- PG 백엔드(`is_pg_backend`)가 활성이면 dual-write (file + PG)
- 읽기: PG 우선, fallback to file

### 13.3 Nickname Generation

Docker-style `{agent_type}-{adjective}-{animal}`:
- 30 adjectives x 30 animals = 900 조합
- `Random.State.make_self_init()` 사용 (fiber-safe)
- 동일 `agent_type`이 이미 참여 중이면 기존 닉네임 재사용

---

## 14. MCP Tool Surface

### 14.1 Room Management (`tool_room`)

| Tool | 동작 |
|------|------|
| `masc_status` | 현재 room 상태 조회 |
| `masc_init` | Room 초기화 (.masc/ 생성) |
| `masc_reset` | Room 리셋 (.masc/ 삭제, confirm 필수) |
| `masc_workflow_guide` | 워크플로우 가이드 출력 |
| `masc_check` | room 건강 상태 점검 |

참고:
- named-room inventory/create/enter surface는 제거되었다.
- 현재는 `current_room` pointer와 per-room lazy bootstrap만 compatibility layer로 남아 있다.

### 14.2 Task Operations (`tool_task`)

| Tool | 동작 |
|------|------|
| `masc_add_task` | 태스크 추가 (title, priority 1-5, description) |
| `masc_batch_add_tasks` | 복수 태스크 일괄 추가 |
| `masc_claim_next` | 최고 우선순위 미할당 태스크 자동 할당 |
| `masc_transition` | 통합 상태 전이 (claim, start, done, cancel, release) |
| `masc_update_priority` | 태스크 우선순위 변경 |
| `masc_tasks` | 태스크 목록 조회 |
| `masc_task_history` | 태스크 이벤트 이력 |

### 14.3 Agent Operations (`tool_agent`)

| Tool | 동작 |
|------|------|
| `masc_agents` | 에이전트 목록 (상태, 좀비 여부 포함) |
| `masc_register_capabilities` | 에이전트 능력 등록 |
| `masc_agent_update` | 에이전트 상태/능력 갱신 |
| `masc_find_by_capability` | 능력 기반 에이전트 검색 |
| `masc_get_metrics` | 에이전트 성과 메트릭 |
| `masc_agent_fitness` | 에이전트 적합도 평가 |
| `masc_select_agent` | 태스크에 최적 에이전트 선택 |
| `masc_collaboration_graph` | 협업 그래프 |
| `masc_consolidate_learning` | 학습 통합 |
| `masc_agent_card` | 에이전트 카드 조회 |
| `masc_agent_relations` | 에이전트 관계 조회 |

### 14.4 Heartbeat (`tool_heartbeat`)

| Tool | 동작 |
|------|------|
| `masc_heartbeat` | 하트비트 갱신 (last_seen 갱신) |
| `masc_heartbeat_start` | 주기적 하트비트 시작 |
| `masc_heartbeat_stop` | 하트비트 중단 |
| `masc_heartbeat_list` | 활성 하트비트 목록 |

### 14.5 Worktree (`tool_worktree`)

| Tool | 동작 |
|------|------|
| `masc_worktree_create` | 에이전트+태스크별 worktree 생성 |
| `masc_worktree_remove` | worktree 삭제 |
| `masc_worktree_list` | worktree 목록 |

### 14.6 Control (`tool_control`)

| Tool | 동작 |
|------|------|
| `masc_pause` | Room 일시 정지 |
| `masc_resume` | Room 재개 |
| `masc_pause_status` | 정지 상태 조회 |

### 14.7 Social (`tool_social`, vote 부분)

| Tool | 동작 |
|------|------|
| `masc_vote` | 투표 생성/행사 |

---

## 15. Invariants

| ID | 규칙 | 검증 위치 |
|----|------|----------|
| INV-ROOM-001 | Room state 갱신은 반드시 `with_file_lock`으로 보호된다 | `room_state.update_state` |
| INV-ROOM-002 | `active_agents`는 중복 없는 리스트다 (`filter ((<>) name)` 후 추가) | `room_lifecycle.join` |
| INV-ROOM-003 | 에이전트는 join 없이 claim/broadcast를 수행할 수 없다 | `tool_task.handle_claim` (is_agent_joined 검사) |
| INV-ROOM-004 | 태스크 전이는 assignee 일치 또는 `force=true` 조건을 충족해야 한다 | `room_task.transition_task_r` |
| INV-ROOM-005 | `backlog.version`은 단조 증가한다 (매 mutation +1) | `room_task`, `room_task_schedule` |
| INV-ROOM-006 | Zombie threshold: 일반 에이전트 300s, Keeper 3600s | `resilience.Zombie.is_zombie_for_agent` |
| INV-ROOM-007 | Smart heartbeat: Busy 에이전트는 하트비트를 emit하지 않는다 | `heartbeat_smart.should_emit` |
| INV-ROOM-008 | GC Phase 3 실패 시 Phase 4(파일 삭제)를 건너뛴다 (데이터 보존) | `room_gc.cleanup_zombies` |
| INV-ROOM-009 | claim_next는 현재 보유 태스크를 자동 해제한 후 새 태스크를 할당한다 | `room_task_schedule.claim_next_r` (BUG-004) |
| INV-ROOM-010 | 닉네임은 동일 agent_type에 대해 세션 내 재사용된다 (identity drift 방지) | `room_lifecycle.join` |
| INV-ROOM-011 | Worktree 경로는 반드시 `.worktrees/` 하위에 생성된다 (경로 탈출 방지) | `room_worktree.ensure_worktree_path` |
| INV-ROOM-012 | historical: `"default"` room은 named-room registry에서 reserved였다 | removed named-room registry |
| INV-ROOM-013 | 투표에서 각 에이전트는 1회만 투표할 수 있다 | `room_vote.vote_cast` |
| INV-ROOM-014 | Portal은 양방향이다 (reverse portal 자동 생성) | `room_portal.portal_open_r` |
| INV-ROOM-015 | GC 시 open task를 참조하는 메시지는 보존된다 | `room_gc.gc` (mentions_open_task) |
| INV-ROOM-016 | PG 백엔드 사용 시 filesystem과 PG에 동시 기록한다 (dual-write) | `room_state.write_state`, `room_lifecycle.join` |

---

## 16. Known Issues & Bug Fixes

| ID | 설명 | 수정 위치 |
|----|------|----------|
| BUG-004 | claim_next가 이전 claim을 해제하지 않아 orphaned task 발생 | `room_task_schedule.claim_next_r` (auto-release) |
| BUG-005 | join 없이 claim 가능했음 | `room_task.claim_task_r` (agent_joined 검사 추가) |
| BUG-009 | stale Todo 태스크가 큐를 막음 | `room_task_schedule` (auto-archive, threshold 7일) |
| BUG-010 | 빈 title/잘못된 priority 태스크 생성 가능 | `tool_task.handle_add_task` (validation 추가) |
| BUG-1600 | room-scoped 에이전트 조회 시 root 디렉토리 미검사 | `room_agent.update_agent_r` (dual path 검사) |

---

## 17. References

- `lib/coord/dune`: sub-library 정의 (`masc_coord`, wrapped=false)
- `lib/coord/coord_utils.ml`, `coord_utils_ops.ml`, `coord_utils_paths_backend.ml`, `coord_utils_backend_setup.ml`: 공통 유틸리티
- `lib/coord/coord_hooks.ml`: 콜백 ref (GC, board, governance)
- `lib/coord/coord_query.ml`: 룸 내 에이전트/태스크 카운트 쿼리
- `lib/coord/coord_status.ml`: 상태 요약 출력
- `lib/coord/coord_git.ml`: git 명령 래퍼 (base branch 해석, worktree 목록)
- `lib/task_sandbox.ml`: 태스크별 worktree sandbox 고수준 API
- 02-types-and-invariants: `agent_status`, `task_status`, `room_state` 타입 정의
- 05-keeper-agent: Keeper가 Room GC와 태스크 해제에 관여하는 경로
- 09-server-transport: MCP tool dispatch가 Room 함수를 호출하는 경로
