---
status: reference
last_verified: 2026-04-17
code_refs:
  - lib/types/
  - lib/tool_dispatch.ml
  - lib/agent_identity.ml
  - lib/agent_ecosystem.ml
---

# Types and Invariants

| 항목 | 값 |
|------|-----|
| Status | Draft |
| Team | Foundation |
| Maps to | `lib/types/`, `lib/message_schema.ml`, `lib/tool_dispatch.ml`, `lib/agent_identity.ml`, `lib/agent_ecosystem.ml` |
| Dependencies | 00-glossary.md |

---

## 1. Newtype Hierarchy

MASC는 ID 타입 간 혼용을 컴파일 타임에 차단하기 위해 추상 newtype 모듈을 사용한다. 모든 ID의 내부 표현은 `string`이지만, 모듈 시그니처가 타입을 불투명(opaque)하게 만들어 `Agent_id.t`와 `Task_id.t`를 직접 비교하거나 대입할 수 없다.

| Module | Type | 생성 방식 | 형식 예시 |
|--------|------|----------|----------|
| `Agent_id` | `Agent_id.t` | `of_string` | `"claude-swift-fox"` |
| `Task_id` | `Task_id.t` | `of_string` / `generate()` | `"task-1711234567000-001a"` |
| `Thread_id` | `Thread_id.t` | `of_string` / `generate()` | `"thread-1711234567000-001a"` |
| `Turn_id` | `Turn_id.t` | `of_string` / `generate ~thread_id ~seq` | `"thread-...-turn-0003"` |

**소스**: `lib/types/types_core.ml` (lines 7-98)

모든 newtype 모듈은 동일한 시그니처를 공유한다:

```ocaml
module type ID = sig
  type t
  val of_string : string -> t
  val to_string : t -> string
  val equal : t -> t -> bool
  val to_yojson : t -> Yojson.Safe.t
  val of_yojson : Yojson.Safe.t -> (t, string) result
end
```

`Task_id.generate`와 `Thread_id.generate`는 `timestamp-seqhex` 패턴으로 고유 ID를 생성한다. `Turn_id.generate`는 thread_id에 순번을 연결한다.

> 참고: `room_info.id`, `task.id`, `message.from_agent` 등 일부 레코드 필드는 아직 `string`을 직접 사용한다. newtype 전환이 완료되지 않은 부분이며, 점진적으로 마이그레이션 대상이다.

---

## 2. Core Domain Types

**소스**: `lib/types/types_core.ml`

### 2.1 Role (task assignment)

```ocaml
type role =
  | Writer      (* Produces artifacts: code, docs, designs *)
  | Reviewer    (* Reviews artifacts: code review, QA, ethics *)
  | Admin       (* Administrative: orchestration, assignment *)
  | Unassigned  (* No specific role (legacy/default) *)
```

`role_satisfies ~required ~agent_role`로 역할 충족 여부를 판정한다. `Admin`은 모든 요구를 충족하고, `Unassigned` 요구는 모든 역할이 충족한다.

### 2.2 Agent Status

```ocaml
type agent_status =
  | Active
  | Busy
  | Listening
  | Inactive
```

JSON 직렬화 시 소문자 문자열(`"active"`, `"busy"`, ...)로 표현된다.

### 2.3 Agent Meta

```ocaml
type agent_meta = {
  session_id : string;
  agent_type : string;        (* "claude", "gemini", "codex" *)
  pid : int option;
  hostname : string option;
  tty : string option;
  worktree : string option;
  parent_task : string option;
}
```

세션 식별과 환경 정보를 담는다. `pid`/`hostname`/`tty`는 디버깅 용도이며 선택 필드다.

### 2.4 Agent

```ocaml
type agent = {
  name : string;               (* 룸 내 유일한 이름: claude-swift-fox *)
  agent_type : string;         (* claude, gemini, codex *)
  status : agent_status;
  capabilities : string list;
  current_task : string option;
  joined_at : string;          (* ISO 8601 *)
  last_seen : string;          (* ISO 8601 *)
  meta : agent_meta option;
}
```

### 2.5 Room Info / Room Registry

```ocaml
type room_info = {
  id : string;                 (* slugified name *)
  name : string;
  description : string option;
  created_at : string;
  created_by : string option;
  agent_count : int;
  task_count : int;
}

type room_registry = {
  rooms : room_info list;
  default_room : string;       (* default: "default" *)
  current_room : string option;
}
```

### 2.6 Task Status (상태 기계)

```ocaml
type task_status =
  | Todo
  | Claimed of { assignee: string; claimed_at: string }
  | InProgress of { assignee: string; started_at: string }
  | Done of { assignee: string; completed_at: string; notes: string option }
  | Cancelled of { cancelled_by: string; cancelled_at: string; reason: string option }
```

각 variant가 메타데이터(who, when)를 직접 보유한다. 이 설계는 "상태와 컨텍스트를 분리하지 않는다"는 원칙을 따른다. 상태 전이 규칙은 [INV-TYPE-002] 참조.

### 2.7 Task

```ocaml
type task = {
  id : string;
  title : string;
  description : string;
  task_status : task_status;
  priority : int;              (* 기본값 3 *)
  files : string list;
  created_at : string;
  worktree : worktree_info option;
  required_role : role;        (* 기본값 Unassigned *)
}
```

### 2.8 Worktree Info

```ocaml
type worktree_info = {
  branch : string;
  path : string;               (* git root 기준 상대 경로 *)
  git_root : string;           (* .git parent 절대 경로 *)
  repo_name : string;
}
```

### 2.9 Message

```ocaml
type message = {
  seq : int;
  from_agent : string;
  msg_type : string;           (* "broadcast" | "direct" *)
  content : string;
  mention : string option;
  timestamp : string;
}
```

### 2.10 Room State

```ocaml
type room_state = {
  protocol_version : string;
  project : string;
  started_at : string;
  message_seq : int;
  active_agents : string list;
  paused : bool;
  pause_reason : string option;
  paused_by : string option;
  paused_at : string option;
  search_strategy_default : string option;
  speculation_enabled : bool;
  speculation_budget : int option;
}
```

`paused = true`일 때 orchestrator는 새 에이전트를 spawn하지 않는다.

### 2.11 Tempo

```ocaml
type tempo_mode = Normal | Slow | Fast | Paused

type tempo_config = {
  mode : tempo_mode;
  delay_ms : int;
  reason : string option;
  set_by : string option;
  set_at : string option;
}
```

클러스터 실행 속도를 제어한다. `delay_ms`는 작업 간 인위적 지연을 삽입한다.

### 2.12 Backlog

```ocaml
type backlog = {
  tasks : task list;
  last_updated : string;
  version : int;
}
```

### 2.13 A2A Task (Google A2A Protocol)

```ocaml
type a2a_task_status = A2APending | A2ARunning | A2ACompleted | A2AFailed | A2ACanceled

type a2a_task = {
  a2a_id : string;
  from_agent : string;
  to_agent : string;
  a2a_message : string;
  a2a_status : a2a_task_status;
  a2a_result : string option;
  created_at : string;
  updated_at : string;
}
```

### 2.14 Portal

```ocaml
type portal_state = PortalOpen | PortalClosed

type portal = {
  portal_from : string;
  portal_target : string;
  portal_opened_at : string;
  portal_status : portal_state;
  task_count : int;
}
```

### 2.15 SSE Session

```ocaml
type sse_session = {
  agent_name : string;
  connected_at : string;
  last_activity : float;  (* Unix timestamp *)
  is_listening : bool;
}
```

### 2.16 Tool Result (core)

`types_core.ml`에 정의된 기본 tool_result:

```ocaml
type tool_result = {
  success : bool;
  message : string;
  data : Yojson.Safe.t option;
}
```

### 2.17 Claim Next Result

스케줄링 결과를 구조화한 ADT. brittle한 문자열 파싱을 방지한다:

```ocaml
type claim_next_result =
  | Claim_next_claimed of {
      task_id : string; title : string;
      priority : int; released_task_id : string option;
      message : string;
    }
  | Claim_next_no_unclaimed
  | Claim_next_no_eligible of { excluded_count : int }
  | Claim_next_error of string
```

---

## 3. Error Hierarchy

MASC는 두 개의 독립된 에러 계층을 갖는다:
- `Error.t` -- 인프라/프로토콜 수준 (6 도메인)
- `masc_error` -- 비즈니스 로직 수준 (MASC 도메인 전용)

### 3.1 Error.t (인프라/프로토콜 에러)

**소스**: `lib/types/error.ml`

```ocaml
type t =
  | Room of room_error
  | Task of task_error
  | Agent of agent_error
  | Federation of federation_error
  | Storage of storage_error
  | Mcp of mcp_error
  | Internal of string
```

7개 variant, 6개 도메인 에러 + 1개 catch-all.

#### 3.1.1 room_error (4 variants)

```ocaml
type room_error =
  | RoomNotFound of string
  | RoomAlreadyExists of string
  | RoomLocked of string
  | RoomFull of int
```

#### 3.1.2 task_error (4 variants)

```ocaml
type task_error =
  | TaskNotFound of string
  | TaskAlreadyClaimed of string
  | TaskInvalidState of string * string  (* current, expected *)
  | TaskCycleDetected
```

#### 3.1.3 agent_error (4 variants)

```ocaml
type agent_error =
  | AgentNotFound of string
  | AgentTimeout of string * int         (* agent_id, timeout_ms *)
  | AgentHeartbeatMissing of string
  | AgentCapabilityMismatch of string
```

#### 3.1.4 federation_error (4 variants)

```ocaml
type federation_error =
  | PortalConnectionFailed of string
  | PortalAuthFailed of string
  | PortalTimeout of int
  | PortalProtocolError of string
```

#### 3.1.5 storage_error (5 variants)

```ocaml
type storage_error =
  | FileNotFound of string
  | FilePermissionDenied of string
  | FileLocked of string
  | GitError of string
```

#### 3.1.6 mcp_error (5 variants)

```ocaml
type mcp_error =
  | McpParseError of string
  | McpMethodNotFound of string
  | McpInvalidParams of string
  | McpAuthError of string
  | McpInternalError of string
```

#### Recoverability

`is_recoverable`가 `true`를 반환하는 variant (재시도 안전):
- `RoomLocked`, `TaskAlreadyClaimed`, `AgentTimeout`, `AgentHeartbeatMissing`, `PortalTimeout`, `FileLocked`

#### Severity Mapping

| Severity | Variants |
|----------|----------|
| Warning | `RoomLocked`, `TaskAlreadyClaimed`, `AgentTimeout`, `AgentHeartbeatMissing`, `PortalTimeout`, `FileLocked`, `McpMethodNotFound` |
| Critical | `Internal` |
| Error | 나머지 전부 |

### 3.2 masc_error (비즈니스 로직 에러)

**소스**: `lib/types/types_auth.ml`

```ocaml
type masc_error =
  | NotInitialized
  | AlreadyInitialized
  | AgentNotFound of string
  | AgentNotJoined of string
  | AgentAlreadyJoined of string
  | TaskNotFound of string
  | TaskAlreadyClaimed of { task_id: string; by: string }
  | TaskNotClaimed of string
  | TaskInvalidState of string
  | TaskRoleMismatch of { task_id: string; required: string; actual: string }
  | PortalNotOpen of string
  | PortalAlreadyOpen of { agent: string; target: string }
  | PortalClosed of string
  | InvalidJson of string
  | IoError of string
  | InvalidAgentName of string
  | InvalidTaskId of string
  | InvalidFilePath of string
  | Unauthorized of string
  | Forbidden of { agent: string; action: string }
  | TokenExpired of string
  | InvalidToken of string
  | RateLimitExceeded of rate_limit_error
  | AutonomyError of autonomy_error
  | CacheError of cache_error
```

25개 variant. `autonomy_error`(3 variants)와 `cache_error`(4 variants)는 상호 재귀 타입으로 정의된다.

```ocaml
and autonomy_error =
  | AutonomyGraphQLFailed of string
  | AutonomyAgentNotCached of string
  | AutonomyInvalidResponse of string

and cache_error =
  | CacheReadFailed of string
  | CacheWriteFailed of string
  | CacheExpired of { key: string; age_hours: float }
  | CacheCorrupted of string
```

Result alias: `type 'a masc_result = ('a, masc_error) result`

---

## 4. Tool Dispatch Types

**소스**: `lib/tool_dispatch.mli`

### 4.1 Handler

```ocaml
type handler = name:string -> args:Yojson.Safe.t -> (bool * string) option
```

모든 MCP 도구 호출은 이 시그니처로 통일된다. `None`을 반환하면 "이 핸들러가 해당 도구를 모른다"는 의미다.

### 4.2 Hooks

```ocaml
type pre_hook = name:string -> args:Yojson.Safe.t -> Tool_result.t option
(* None -> 진행, Some result -> 핸들러를 건너뛰고 즉시 반환 *)

type post_hook = Tool_result.t -> Tool_result.t
(* 핸들러 결과를 변환하거나 관찰 *)
```

실행 순서: pre_hooks -> handler -> post_hooks.

### 4.3 Module Tag (2-level dispatch)

```ocaml
type module_tag =
  | Mod_plan | Mod_run | Mod_operator | Mod_command_plane
  | Mod_local_runtime | Mod_team_session | Mod_voice | Mod_cache
  | Mod_tempo | Mod_portal | Mod_worktree
  | Mod_code_swarm | Mod_code | Mod_code_write | Mod_vote | Mod_social
  | Mod_council | Mod_a2a | Mod_handover
  | Mod_relay | Mod_goals | Mod_heartbeat | Mod_encryption
  | Mod_auth | Mod_hat | Mod_audit | Mod_rate_limit
  | Mod_cost | Mod_agent | Mod_task | Mod_room
  | Mod_control | Mod_agent_timeline | Mod_misc | Mod_suspend
  | Mod_library | Mod_keeper | Mod_compact | Mod_mdal
  | Mod_notifications | Mod_inline
  | Mod_autoresearch | Mod_research | Mod_model_catalog
  | Mod_shard | Mod_fire_task
```

43개 variant. 도구 이름으로 O(1) tag lookup 후, tag별로 적합한 모듈 컨텍스트를 지연 생성한다.

### 4.4 Tool_result.t (structured)

**소스**: `lib/tool_result.mli`

```ocaml
type t = {
  success : bool;
  data : Yojson.Safe.t;
  tool_name : string;
  duration_ms : float;
}
```

레거시 `(bool * string)` 튜플은 `wrap ~tool_name ~start_time`으로 변환된다. `to_legacy`로 역변환이 가능하다.

---

## 5. Agent Identity Types

**소스**: `lib/agent_identity.mli`

### 5.1 Channel

```ocaml
type channel =
  | Telegram | Discord | Slack | Signal
  | Webchat | Api | Internal
  | Unknown of string
```

MCP 세션의 접속 경로를 나타낸다. `Unknown`은 미등록 채널에 대한 확장점이다.

### 5.2 Agent Identity Record

```ocaml
type t = {
  uuid : string;
  session_key : string;
  agent_name : string;
  channel : channel option;
  user_id : string option;
  room_id : string option;
  capabilities : string list;
  registered_at : float;
  mutable last_seen : float;   (* 유일한 mutable 필드 *)
  metadata : (string * string) list;
}
```

`last_seen`만 mutable이다. 이유: heartbeat마다 새 레코드를 할당하는 비용을 피하기 위함.

### 5.3 Identity Registry

```ocaml
module Registry : sig
  type registry
  val create : unit -> registry
  val register : registry -> t -> t
  val find_by_session : registry -> string -> t option
  val find_by_name : registry -> string -> t option
  val touch : registry -> string -> ?room_id:string -> unit -> unit
  val unregister : registry -> string -> unit
  val list_active : registry -> within_seconds:float -> t list
  val count : registry -> int
end
```

### 5.4 Archetype (MAGI system)

```ocaml
type archetype =
  | Melchior    (* Scientist *)
  | Balthasar   (* Mirror/Ethics *)
  | Casper      (* Strategist *)
  | Athena      (* Reasoner *)
  | Generalist  (* No specialization *)
```

MAGI 3인 체제(Melchior/Balthasar/Casper)에 Athena와 Generalist를 추가한 확장. 각 archetype은 가중치 계산(`archetype_weight`)을 지원한다.

---

## 6. Agent Ecosystem Types

**소스**: `lib/agent_ecosystem.mli`

### 6.1 Agent Type (생명주기)

```ocaml
type agent_lifecycle =
  | Keeper_long_lived  (* Keepalive 기반 장기 실행 *)
  | Visitor            (* Session 기반 *)
  | Ephemeral          (* Task 기반, 작업 완료 후 소멸 *)
```

### 6.2 Agent Profile

```ocaml
type agent_profile = {
  name : string;
  role : string;
  traits : string list;
  avatar : string option;
}
```

### 6.3 Lineage (세대 추적)

```ocaml
type lineage = {
  generation : int;
  parent_hash : string option;
  ancestors : string list;
  mutations : string list;
}
```

에이전트 간 계보를 추적한다. `spawn_child`로 새 세대를 생성하면 `generation`이 증가하고 부모 해시가 기록된다.

### 6.4 Extended Identity

```ocaml
type extended = {
  base : Agent_identity.t;
  hash : string;
  agent_type : agent_type;
  profile : agent_profile;
  lineage : lineage;
}
```

`Agent_identity.t`를 확장하여 프로필, 생명주기 타입, 계보를 추가한다. `to_base_with_metadata`/`from_base_with_metadata`로 base identity와 상호 변환한다.

---

## 7. Checkpoint Types

**소스**: `lib/checkpoint_types.ml`

### 7.1 Checkpoint Status

```ocaml
type checkpoint_status =
  | Pending
  | InProgress
  | Interrupted
  | Completed
  | Rejected
  | Reverted     (* Time Travel: 이전 체크포인트로 되돌림 *)
  | Branched     (* 이 체크포인트에서 새 분기 생성 *)
```

7개 variant. 상태 전이는 `can_transition ~from ~to_`로 검증한다:

| from | to | 허용 |
|------|----|------|
| Pending | InProgress | yes |
| InProgress | Interrupted | yes |
| InProgress | Completed | yes |
| Interrupted | Completed | yes (approved) |
| Interrupted | Rejected | yes (rejected) |
| 그 외 | * | no |

터미널 상태: `Completed`, `Rejected`, `Reverted`.

### 7.2 Checkpoint Info

```ocaml
type checkpoint_info = {
  id : string;
  task_id : string;
  step : int;
  action : string;
  agent : string;
  status : checkpoint_status;
  interrupt_message : string option;
  created_at : float option;
}
```

---

## 8. Context Budget Types

**소스**: `lib/context_budget_manager.mli`

### 8.1 Compression Phase

```ocaml
type compression_phase =
  | None_phase      (* 0-50%: 전체 설명, 압축 없음 *)
  | Compact_tools   (* 50-70%: 도구 설명을 한 줄로 *)
  | Drop_low        (* 70-85%: 중요도 낮은 메시지 제거 *)
  | Summarize       (* 85%+: 오래된 턴 요약 *)
```

### 8.2 Budget Tracker

```ocaml
type t  (* abstract *)

val create : ?max_budget:int -> unit -> t
val record_tool_schemas : t -> count:int -> estimated_tokens:int -> unit
val record_turn : t -> estimated_tokens:int -> unit
val current_phase : t -> compression_phase
val usage_ratio : t -> float
val total_tokens : t -> int
val max_budget : t -> int
```

기본 `max_budget`는 환경변수 `MASC_CONTEXT_BUDGET_MAX` (fallback: 100000).

---

## 9. Auth Types

**소스**: `lib/types/types_auth.ml`

### 9.1 Agent Role (auth)

```ocaml
type agent_role = Reader | Worker | Admin
```

`role`(Section 2.1)과는 별개의 타입이다. `role`은 task assignment 용도, `agent_role`은 인증/인가 용도다.

### 9.2 Permission

```ocaml
type permission =
  | CanInit | CanReset | CanJoin | CanLeave
  | CanReadState | CanAddTask | CanClaimTask | CanCompleteTask
  | CanBroadcast
  | CanOpenPortal | CanSendPortal
  | CanCreateWorktree | CanRemoveWorktree
  | CanVote | CanInterrupt | CanApprove
  | CanAdmin
```

17개 variant. 각 `agent_role`에 허용된 permission 목록:

| Role | Permissions |
|------|------------|
| Reader | `CanReadState`, `CanJoin`, `CanLeave` (3개) |
| Worker | Reader + `CanAddTask`, `CanClaimTask`, `CanCompleteTask`, `CanBroadcast`, `CanOpenPortal`, `CanSendPortal`, `CanCreateWorktree`, `CanRemoveWorktree`, `CanVote` (12개) |
| Admin | Worker + `CanInit`, `CanReset`, `CanInterrupt`, `CanApprove`, `CanAdmin` (17개, 전체) |

### 9.3 Agent Credential

```ocaml
type agent_credential = {
  agent_name : string;
  token : string;         (* SHA256 hash -- raw token은 저장하지 않음 *)
  role : agent_role;
  created_at : string;
  expires_at : string option;
}
```

### 9.4 Auth Config

```ocaml
type auth_config = {
  enabled : bool;
  room_secret_hash : string option;
  require_token : bool;
  default_role : agent_role;    (* 기본값: Worker *)
  token_expiry_hours : int;     (* 기본값: 24 *)
}
```

### 9.5 Rate Limit

```ocaml
type rate_limit_config = {
  per_minute : int;
  burst_allowed : int;
  priority_agents : string list;
  reader_multiplier : float;    (* 0.5x *)
  worker_multiplier : float;    (* 1.0x *)
  admin_multiplier : float;     (* 2.0x *)
  broadcast_per_minute : int;
  task_ops_per_minute : int;
}

type rate_limit_category = GeneralLimit | BroadcastLimit | TaskOpsLimit

type rate_limit_error = {
  limit : int;
  current : int;
  wait_seconds : int;
  category : rate_limit_category;
}
```

---

## 10. Structured Message Types

**소스**: `lib/message_schema.mli`

### 10.1 Validation Mode

```ocaml
type validation_mode = Strict | Warn | Permissive
```

### 10.2 Structured Message

```ocaml
type structured_message =
  | TaskUpdate of { task_id: string; status: string; payload: Yojson.Safe.t option }
  | StatusReport of { agent: string; progress: float; details: string }
  | Request of { target: string; action: string; params: Yojson.Safe.t }
  | Response of { request_id: string; success: bool; result: Yojson.Safe.t }
  | Freeform of string
```

5개 variant. `Freeform`은 구조화되지 않은 메시지에 대한 하위호환 경로다.

### 10.3 Swarm Envelope

```ocaml
type swarm_envelope = {
  sender : string;
  timestamp : float;
  sequence : int;
  channel : string;
  message : structured_message;
}
```

swarm 내부 메시지는 반드시 envelope로 감싸서 전송한다. `sequence`는 메시지 순서를 보장하고 중복 감지에 사용된다.

---

## 11. Global Invariants

아래 불변식은 MASC 도메인 전체에 적용되며, 테스트로 검증 가능하다.

### Identity

| ID | 불변식 | 검증 방법 |
|----|--------|----------|
| INV-TYPE-001 | 에이전트 name은 룸 내에서 유일하다. 동일 이름으로 `masc_join` 시 `AgentAlreadyJoined` 반환. | `masc_join` 중복 호출 테스트 |
| INV-TYPE-002 | Newtype ID 모듈(`Agent_id`, `Task_id`, `Thread_id`, `Turn_id`)은 모듈 경계에서 타입이 불투명하다. 서로 다른 ID 타입 간 직접 비교/대입은 컴파일 에러다. | 컴파일러가 강제 |

### State Machine

| ID | 불변식 | 검증 방법 |
|----|--------|----------|
| INV-TYPE-003 | `task_status` 전이는 단방향이다: `Todo -> Claimed -> InProgress -> Done\|Cancelled`. `Done`에서 `Todo`로 역전이하거나, `Todo`에서 `Done`으로 건너뛰는 것은 허용되지 않는다. | `task_status` 전이 함수 + 단위 테스트 |
| INV-TYPE-004 | `checkpoint_status` 전이는 `can_transition`이 정의한 5가지 경로만 허용된다. 터미널 상태(`Completed`, `Rejected`, `Reverted`)에서는 어떤 전이도 불가하다. | `can_transition` 단위 테스트 |
| INV-TYPE-005 | `agent_status`의 기본 fallback은 `Active`다. 알 수 없는 문자열 입력 시 예외 대신 `Active`를 반환한다. | `agent_status_of_string "unknown"` 테스트 |

### Error Handling

| ID | 불변식 | 검증 방법 |
|----|--------|----------|
| INV-TYPE-006 | `Error.t`의 match는 7개 variant 전부를 처리해야 한다 (exhaustiveness). OCaml 컴파일러 warning 8이 이를 강제한다. | 컴파일러가 강제 |
| INV-TYPE-007 | `masc_error`의 모든 variant는 `masc_error_to_string`에서 처리된다. 새 variant 추가 시 `masc_error_to_string`도 반드시 업데이트해야 한다 (exhaustive match). | 컴파일러 warning 8 |
| INV-TYPE-008 | `is_recoverable`이 `true`인 에러만 재시도 대상이다. 그 외 에러에 대한 자동 재시도는 금지된다. | `is_recoverable` 반환값 기준 분기 테스트 |

### Concurrency

| ID | 불변식 | 검증 방법 |
|----|--------|----------|
| INV-TYPE-009 | 모든 공유 가변 상태는 `Eio.Mutex`로 보호된다. `Stdlib.Mutex`는 Eio 환경에서 EDEADLK를 유발하므로 사용 금지다. | `rg 'Stdlib\.Mutex\|Mutex\.create\b' lib/` (Stdlib.Mutex 사용 0건 확인) |

### Dispatch

| ID | 불변식 | 검증 방법 |
|----|--------|----------|
| INV-TYPE-010 | 도구 핸들러 등록은 서버 시작(init) 시점에 완료된다. init 이후 동적 등록은 발생하지 않는다. `is_tag_registry_initialized()`가 `true`를 반환한 후에는 `register_module_tag` 호출이 없어야 한다. | init 직후 `registered_count()` 스냅샷 비교 |
| INV-TYPE-011 | `dispatch`는 O(1) Hashtbl lookup이다. 등록된 도구 수에 비례하는 순차 탐색은 발생하지 않는다. | 구현 검사 (Hashtbl.find) |
| INV-TYPE-012 | `pre_hook`이 `Some result`를 반환하면 핸들러를 건너뛴다 (short-circuit). `post_hook`은 실행되지 않는다. | hook 테스트 |

### Auth

| ID | 불변식 | 검증 방법 |
|----|--------|----------|
| INV-TYPE-013 | `auth_config.enabled = false`이면 모든 도구 호출이 인가된다. 토큰 검증을 수행하지 않는다. | `check_permission` with `enabled = false` 테스트 |
| INV-TYPE-014 | raw token은 저장하지 않는다. `agent_credential.token` 필드에는 SHA256 해시만 저장된다. | `create_token` 후 credential 파일 내용 검사 |
| INV-TYPE-015 | initial admin(auth를 활성화한 에이전트)은 bootstrap grace로 모든 permission을 갖는다. | `check_permission` with initial_admin 테스트 |
| INV-TYPE-016 | strict mode(`MASC_TOOL_AUTH_STRICT=true`, 기본값)에서 `permission_for_tool`에 매핑되지 않은 `masc_*` 도구는 최소 `CanBroadcast` 권한을 요구한다. | unmapped tool name 테스트 |

### Serialization

| ID | 불변식 | 검증 방법 |
|----|--------|----------|
| INV-TYPE-017 | `structured_message`는 roundtrip 무손실이다: `roundtrip msg = Ok msg`. | `roundtrip` 함수의 QuickCheck/단위 테스트 |
| INV-TYPE-018 | `swarm_envelope`도 roundtrip 무손실이다: `roundtrip_envelope env = Ok env`. | `roundtrip_envelope` 단위 테스트 |
| INV-TYPE-019 | 모든 `_to_yojson`/`_of_yojson` 쌍은 roundtrip 호환이다. JSON 직렬화 후 역직렬화하면 원본과 동일한 값을 복원한다. | 주요 타입별 roundtrip 테스트 |

### Role System

| ID | 불변식 | 검증 방법 |
|----|--------|----------|
| INV-TYPE-020 | `role`(task assignment)과 `agent_role`(auth)은 별개의 타입 시스템이다. 컴파일 타임에 혼용이 차단된다. | 컴파일러가 강제 |
| INV-TYPE-021 | `role_satisfies ~required:Unassigned ~agent_role:_`는 항상 `true`다. `role_satisfies ~required:_ ~agent_role:Admin`도 항상 `true`다. | `role_satisfies` 단위 테스트 |
