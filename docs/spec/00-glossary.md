---
status: reference
---

# MASC Glossary

이 문서는 현재 코드와 운영 표면에 존재하는 용어만 정의한다.

## Core

**MASC**
: Multi-Agent Shared Context의 약어. 다중 에이전트의 Board, Task, Goal, Schedule,
  Keeper와 도구 실행을 조율하는 OCaml/Eio 서버.

**Agent Core**
: `packages/agent_core`의 재사용 모델 실행 계층. MASC coordinator를 참조하지
  않아 MASC 없이도 쓸 수 있다. `Agent_core.Agent`를 거치는 실행의 Agent 구성,
  tool turn, provider 요청, typed 응답·사용량·실패를 소유한다. 공통 타입은
  레인과 무관하게 공유한다. 공식 클라이언트 레인도 `Agent_core.Error`·
  `Agent_core.Llm_provider`·`Agent_core.Retry`를 쓰고, provider 요청은 자기
  프로세스에서 보낸다. MASC는 Keeper 실행과 제품 조율을 소유한다.
  코드 식별자는 `agent_core`와 `Agent_core`다.
  → [Agent Core 경계](13-agent-core.md)

**Official Client Lane**
: Claude Code, Codex, Antigravity 같은 공식 클라이언트가 자기 프로세스에서
  provider 요청을 보내고, MASC는 새 turn과 결과를 조율·관찰하는 실행 경로.

**MCP**
: Model Context Protocol의 약어. MASC는 양쪽으로 쓴다. 자기 도구와 협업 상태를
  MCP 서버로 내보내고(`masc_*` 도구), Agent는 `mcp_clients`로 바깥 MCP 서버에
  붙어 그쪽 도구를 가져온다.

**HITL**
: Human-in-the-Loop의 약어. Gate의 외부 효과를 사람이 판정하는 비차단 권한 경로다.
  대기 중인 HITL 판정은 다른 Keeper의 턴이나 서로 독립인 작업을 멈추지 않는다.

**Surface**
: 같은 MASC 상태에 접근하고 관찰하는 사용자 표면. TUI, MCP, Dashboard처럼 서로 다른
  입구를 가리키며, 각 표면은 독립 상태를 소유하지 않는다.

**Workspace**
: 에이전트와 협업 상태가 공유되는 조율 범위.

**Cluster**
: `.masc/` 상태 디렉터리 레이아웃을 가르는 이름 범위(`MASC_CLUSTER_NAME`). 기본값은
  `default`이며 그때 경로는 `<base>/.masc/`다. 다른 이름은
  `<base>/.masc/clusters/<sanitized>/`를 쓴다. TUI 개요의 `Cluster:` 행이 이 값을
  보여준다. Turn Boundary와 Read Position 같은 runtime 좌표는 선택한 cluster의
  디렉터리에만 의미가 있고, 같은 이름의 Keeper라도 다른 cluster와 공유하지 않는다.
  Memory OS와 Working Context는 cluster가 아니라 Keeper 이름에 귀속되므로 cluster
  간에 공유된다.
  → [masc_root_dir_from](../../lib/workspace/workspace_utils_paths_backend.mli),
  [backend_config_for](../../lib/workspace/workspace_utils_backend_setup.mli),
  [cluster_name](../../lib/config/env_config_core.mli)

**Workspace Heartbeat**
: `Workspace.heartbeat`가 Agent 파일의 `last_seen`을 갱신하는 Workspace 저장 작업.
  `Heartbeat_updated`만 실제 쓰기와 Workspace writability를 증명한다. 이는 Keeper의
  `keeper_heartbeat` SSE나 MCP·transport activity 같은 별도 liveness signal의 부재를
  뜻하지 않으며, 해당 신호는 이 Workspace 쓰기가 갱신되지 않아도 발생할 수 있다.
  → [Workspace_gc.heartbeat](../../lib/workspace/workspace_gc.mli)

**Agent**
: Workspace에 참여해 typed capability를 호출하는 실행 주체.

**Keeper**
: MASC가 lifecycle을 관리하는 장기 실행 Agent. 현재 typed event와 tool schema를
  관찰하고 자율 turn을 실행한다. 이어 실행할 상태는 runtime에 따라 AGENT_CORE 또는
  공식 클라이언트가 관리한다([`Runtime_execution.checkpoint_owner`](../../lib/runtime/runtime_execution.mli)).

**Keeper Cycle**
: 현재 상태와 event를 관찰하고 Keeper turn 실행 여부를 결정하는 서버 loop의
  한 회차. 모든 cycle이 모델 호출을 실행하지는 않는다.

**Keeper Turn**
: MASC가 하나의 Keeper 작업을 시도하는 단위. 선택한 runtime에 따라 AGENT_CORE
  Agent run 또는 공식 클라이언트의 모델·도구 실행을 사용한다
  ([`Runtime_execution.t`](../../lib/runtime/runtime_execution.mli)). MASC는 해당 레인의 결과를
  조율·기록한다.

**Keeper Chat Operation**
: Keeper Owner가 접수한 메시지 실행의 durable 기록. `operation_id`로 식별하며
  `state`가 대기·실행·성공·실패·취소를 구분한다. Board 맥락 추론도 이 operation을
  제출하고, 응답의 `keeper_name`은 제출 경로가 해석한 실제 대상 Keeper다.
  접수 응답은 실행 완료를 뜻하지 않는다.

**Checkpoint Load**
: 저장된 Keeper 이력을 읽는 단계. 파일 없음은 새 이력을 뜻하지만 읽기·파싱 오류는
  새 이력을 허용하지 않는다. 명시적인 checkpoint 버전 교체만 기존 파일을 남겨 두고
  새 이력을 시작하며, 첫 저장이 받아들여진 뒤 재시작을 기록한다.

**agent core Turn**
: 하나의 agent core Agent run 내부에서 provider response와 tool 실행이 진행되는 한
  단계. Keeper turn과 동일한 단위가 아니다.

**Runtime Attempt**
: Keeper turn에서 하나의 resolved runtime 후보를 실행하는 시도.

**Official-client Session Recovery**
: 공식 클라이언트 세션에 기록된 `Input_rejected` 때문에 같은 runtime의 새 실행
  요청을 거절하는 상태. `bootstrap_floor_exceeded`는 줄일 수 있는 이력을 제거한
  입력도 용량을 넘은 경우이고, `effect_fenced`는 앞선 응답이나 도구 실행이 관측되어
  입력을 줄여 재실행할 수 없는 경우다. 현재 거절은 provider 호출 전에 일어나며 앞선
  provider attempt의 효과 자체와 구분한다. 상태 표시는 원인·runtime ID·recovery ID를
  기존 session에서 전달하며, 복구 승인이나 fence 해제를 수행하지 않는다.
  Fleet는 일시정지되지 않은 `Failing` Keeper의 이 원인을 `recovering`과 구분해
  `official_client_recovery_required_keeper_count/names`로 표시한다. 이는 운영자
  조치가 필요한 fleet health 저하 사유이며, 다른 차단 사유가 없으면 `degraded`로
  표시한다. 실행 fiber의 생존·실행 가능 여부를 바꾸거나 세션 복구를 승인하지 않는다.

**Usage Scope**
: Runtime이 보고한 토큰 수의 집계 범위(`Runtime_usage_scope`). `per_request`는
  요청별, `turn_total`은 공식 클라이언트 턴 안의 여러 provider 요청 합계,
  `conversation_cumulative`는 대화 누적, `unavailable`은 범위 미상이다.
  합계·누적·범위 미상인 값으로 단일 요청의 컨텍스트 점유율이나 비용을 계산하지
  않는다. 클라이언트 턴 합계도 failover를 포함한 Keeper turn 전체 합계는 아니다.

**Tool**
: 이름·입력 schema·handler로 노출되는 호출 단위. MASC가 제공하는 Tool의
  descriptor와 권한 검사는 MASC가 소유한다. → [Tool boundary](13-agent-core.md#tool-boundary)

**Tool-host failure report**
: 클라이언트가 관측한 도구 연결 실패 기록. HTTP 인증 결과의 보고자는 감사
  이벤트의 `actor`가 된다. 본문의 `agent_name`은 실패가 보고된 Agent이며,
  감사 상세의 `reported_agent`와 실패 envelope에 보존한다. 허용된 tokenless
  요청의 보고자는 기존 로컬 attribution 정책을 따른다.

**Provider**
: 모델에 접속하는 protocol·transport·credential을 소유하는 설정 항목.
  → [Runtime_schema.provider](../../lib/runtime/runtime_schema.mli)

**Runtime**
: Provider·Model·Binding을 해석해 얻은 실행 후보 하나.
  → [Runtime.t](../../lib/runtime/runtime.mli)

**Lane**
: Keeper turn이 Runtime 후보를 시도할 순서. Runtime Lane도 같은 뜻이다.
  → [Runtime_lane.t](../../lib/runtime/runtime_lane.mli)

**Runtime execution**
: 모델·도구·재개 상태를 Agent Core가 소유하는지 공식 클라이언트가 소유하는지의 구분.
  → [Runtime_execution.t](../../lib/runtime/runtime_execution.mli)

**Exact-output route**
: Librarian 같은 단독 모델 작업의 목적별 실행 경로. 해당 설정은 API slot과
  후속 CLI 후보 순서를 선언한다. 코드 이름은 `exact_output_lane_decl`이다.
  → [선언](../../lib/runtime/runtime_schema.mli),
  [작업 기록](../../lib/exact_lane_run_registry.mli)

**Memory queue**
: Keeper별 Librarian 작업을 직렬화하는 제출 경로. 현재 실행 하나와 교체 가능한
  최신 대기 하나를 가진다. 코드 이름은 `Keeper_memory_lane`이다.
  → [Keeper_memory_lane](../../lib/keeper/keeper_memory_lane.mli)

**Composition**
: Tool 노드의 실행 선후 관계와 결과 참조 등 구조를 검사한 실행 계획. 합성 Skill은
  허용된 계획을 Tool로 노출한다. → [선언 문법](../../lib/keeper/keeper_tool_composition_catalog.mli),
  [실행 계획](../../lib/keeper/keeper_tool_plan.mli)

**Parallel Tool Calls**
: 모델 응답 하나에 여러 도구 호출이 들어오는 것. 모델의 지원 여부는 카탈로그의
  `supports_parallel_tool_calls`, 실행별 억제는 runtime binding의
  `disable-parallel-tool-use`가 정한다. 억제 요청을 받아들이는 provider 계약은
  provider catalog의 `supports_parallel_tool_suppression`이며, 미선언이면 억제를
  요청할 수 없다. 이 요청 정책은 도구를 실행할 때의 동시성이나
  spawn으로 시작한 별도 에이전트의 동시 실행과 다르다.

## Collaboration State

**Board**
: 공유 발견, 질문, 답변, 의견과 결정을 게시하는 durable 협업 표면.

**Broadcast**
: 이 저장소에서 서로 다른 넷을 가리킨다. 문장에 어느 것인지 함께 적는다.
  (1) 워크스페이스 broadcast: `Workspace.broadcast
  ~audience:Workspace_broadcast.Fleet_conversation`으로 모든 Keeper의 대화창에 닿는
  발화. 입구는 Keeper 도구 `keeper_broadcast`, MCP 도구 `masc_broadcast`, 운영자
  제어(`lib/operator/operator_control.ml`), dashboard HTTP
  (`lib/server/server_routes_http_dashboard_handlers.ml`),
  gRPC(`lib/server/masc_grpc_service.ml`)다. (2) SSE broadcast: 서버가 연결된 client
  전부의 stream에 event를 밀어 넣는 전송 동작(`09-server-transport.md`).
  (3) Board `audience`의 `Broadcast`: 글을 특정 대상 없이 모두에게 라우팅하는 값
  (`lib/board_types/board_types.mli`). (4) 로그 분류 `Log.Broadcast`
  (`lib/masc_log/log.ml`).

**Task**
: 실제 작업의 소유권과 검증 상태를 기록하는 단위. 상태는 `Todo`, `Claimed`,
  `InProgress`, `AwaitingVerification`, `Done`, `Cancelled`다.
  Activity도 커밋된 상태를 표시한다. 맡은 Task의 취소 요청은 검증 제출이고,
  `Todo`는 직접 취소할 수 있다. 실제 `Cancelled` 커밋 뒤에 취소 사건을 기록한다.
  판정자의 이름은 authority이고, 판정 payload의 `producer`가 작업 관계와 실행
  구간의 소유자다. `AwaitingVerification`은 `Held_pending_verdict`로 claim에
  응답하므로 Keeper가 다시 맡을 수 없다. 완료·취소 verdict는 Keeper action이
  아니라 system LLM 또는 인증된 운영자의 authority 경계에서만 적용된다.

**Evidence**
: 관찰·검증·전환을 근거에 연결하는 분류된 reference. `evidence_refs` 같은 필드로 전달한다.
  `note:<text>`는 허용된 서술형 근거이며, Task handoff summary와 completion notes도 이
  형식으로 정규화된다. Note evidence는 artifact나 collaboration source의 증명은 아니다.

**Goal**
: 장기 의도와 Task 연결을 기록하는 단위. phase는 `Executing`, `Verifying`,
  `Awaiting_confirmation`, `Completed`, `Dropped`다. 완료를 요청하면
  `Verifying`으로 들어가고, verifier가 증명을 통과시킨 뒤 사람이 확인해야
  `Completed`가 된다(`lib/goal/goal_phase.mli`). `Verifying` 중에도 연결된
  Task는 계속 진행할 수 있다. 완료 verdict는 verifier가 기록하고, 사람의
  확인이 `Completed` 전이를 확정한다. `goal_phase.mli`의
  `admits_self_directed_progress`가 이 경계를 정의한다.

**Schedule**
: 미래 시점에 Keeper를 깨우는 durable 요청. 만들기, 조회, 수정, 취소와
  기록 추가·조회 도구가 있다. Schedule은 이후 외부 효과를 자동 승인하지 않는다.

**Fusion**
: 여러 독립 판단을 비동기로 수집하고 하나의 결론으로 합성하는 실행.

**Gate**
: 외부 효과를 Always Allowed, Auto Judge, HITL 중 설정된 정책으로 판정하는
  경계. pending 판정은 다른 작업을 막지 않는다.

## Task Lifecycle

**Created By**
: Task 를 만든 에이전트나 사람의 이름(`created_by`). 만들 때 한 번 적히고 바뀌지 않는다.
  Keeper 는 자기가 만든 `Todo` 를 자동 claim 대상에서 뺀다.

**Assignee**
: `Claimed`, `InProgress`, `AwaitingVerification` 에 적힌 에이전트 이름. 앞의 둘에서는
  지금 일을 맡은 쪽이고, `AwaitingVerification` 에서는 제출한 쪽이다.

**Producer**
: 판정 쪽 코드가 제출한 에이전트를 부르는 이름. 이 RFC의 1단계가
  `AwaitingVerification.assignee`도 `producer`로 바꾼다. 이후 새 Task 생애주기
  코드는 제출자를 `producer`로만 부른다. verification 레코드의 외부 스키마 키
  `worker`는 남지만 Task 소유권이나 관계를 찾는 키로 사용하지 않는다.

**Claim**
: `Todo` 인 Task 를 맡는 전이. 한 에이전트는 `Claimed` 와 `InProgress` 를 합쳐 하나만
  가질 수 있고, 이 검사는 claim 할 때만 한다. Keeper 의 claim 은 곧바로 Start 를 이어
  보낸다.

**Release**
: 맡은 쪽이 Task 를 `Todo` 로 돌려놓는 전이. Handoff Context 를 남긴다.

**Submission**
: 맡은 쪽이 증거와 함께 완료를 내는 전이(`Submit_for_verification`). 상태는
  `AwaitingVerification` 이 되고 새 Verification ID 를 받는다. 판정을 기다리는 Task 는
  claim 한도에 세지 않는다. Producer 는 기다리는 중에 다시 낼 수 있고 그때마다 id 가
  바뀐다.

**Verification ID**
: 제출 하나의 식별자. 판정은 자기가 읽은 id 가 지금 id 와 같을 때만 적용된다.

**Completion Authority**
: 판정을 내리는 쪽. 서버 안의 판정 에이전트(`System_llm_agent`)이거나 인증된 HTTP
  경로로 들어온 운영자(`Human_operator`)다. Keeper 는 판정하지 못한다. 취소 요청은
  운영자만 승인한다.

**Verdict**
: `Verdict_approved` 또는 `Verdict_rejected { reason }`. 완료 제출의 승인은 `Done`, 취소
  요청의 승인은 `Cancelled`, 반려는 어느 쪽이든 Producer 의 `InProgress` 다.

**Handoff Context**
: Task 에 붙어 다니는 인계 메모. summary, reason, next_step, evidence_refs, updated_by
  를 담는다. Release, Submission, cancel 이 쓰고 Claim 과 Start 는 지우지 않는다. 반려
  판정은 이 메모를 판정 사유로 덮어쓴다.

**Evidence Reference**
: 제출에 다는 증거 참조. `artifact:`, `note:`, `board:`, `fusion:` 네 형식만 열린다.

**Operator Attention**
: 운영자만 풀 수 있는 Task 의 목록(`Operator_task_attention.item`). 종류는 `Cancel_claim`,
  `Held_without_actor`, `Producer_record_unreadable` 이다.

**Current Task**
: 에이전트 기록의 `current_task`, Keeper meta 의 `current_task_id`, planning 의 current
  task. 기준은 backlog 이고 이 셋은 거기서 다시 계산되는 표시다.

## Skills

**Skill**
: 선언된 source의 `<package>/SKILL.md`로 발행하는 재사용 지식 또는 도구 합성.
  출처·패키지·이름·문서 revision으로 식별한다.
  Memory OS의 Fact와 별개다. `validated_approach`나 `lesson`을 기억했다고 Skill이
  생성되지는 않는다. 현재 발행·사용 경로는 [Skills](../SKILLS.md)를 따른다.
  `keeper_skill_validate`는 export한 문서를 정적 검증하며, 실행 성공·안전성·발행을
  뜻하지 않는다. 입력과 발행 경계도 위 [Skills](../SKILLS.md) 문서를 따른다.
  → [Keeper_skill_catalog](../../lib/keeper/keeper_skill_catalog.mli),
  [Skill_reference](../../lib/skill_reference/skill_reference.mli)

**Instruction Skill**
: Keeper가 `keeper_skill`로 본문과 참조 파일을 읽고 적용할 방법을 판단하는 Skill.
  본문을 읽었다는 사실은 그 절차를 실행했거나 성공했다는 증거가 아니다.

**Composition Skill**
: 본문의 `toml composition` fence가 도구 노드와 입력 연결을 선언하는 Skill.
  검증된 계획이 `keeper_compose_<name>` 도구가 된다. 실행기는 선언된 입력과
  의존 관계를 따르며, 노드 사이의 새 모델 판단을 대신하지 않는다. 필요한 노드
  도구가 Keeper의 현재 표면에 없으면 합성 도구도 그 턴에 제공하지 않는다.

**Skill Reference**
: source, package, name으로 이뤄진 신원과 content revision의 조합
  (`Skill_reference.t`). 이름 하나가 아닌 이 참조로 읽을 내용을 지정한다.

**Skill Snapshot**
: `Skill_catalog_snapshot_service`가 발행한 source 관측과 원문 bytes의 불변 묶음.
  Keeper는 턴 경계에서 고정한 snapshot으로 Skill을 선택한다. 원문이 바뀌어도
  이미 시작한 턴의 참조를 새 내용으로 바꾸지 않는다.

**Skill Activation**
: 정확한 Skill 참조의 본문·리소스 읽기 또는 합성 호출을 기록한 사건.
  `Keeper_skill_activation_ledger`는 결과 전달(`delivery`)과 이후 모델이 고른
  도구 호출(`actions`)을 별도로 붙인다. 이후 호출이 있다는 사실만으로 Skill이
  그 행동의 원인이었거나 작업을 성공시켰다고 판정하지 않는다.

## Repository Execution

**Repository Catalog**
: repository ID, remote URL, default branch를 소유하는 identity SSOT.

**Repository Checkout**
: Keeper가 실제로 읽고 수정할 수 있는 Git checkout. Catalog 등록만으로
  checkout 존재를 보장하지 않는다.

**Checkout Freshness**
: checkout HEAD와 명시된 local tracking ref의 ahead/behind 관계. 이 값은
  네트워크 fetch 시각이 아니라 로컬 tracking ref를 기준으로 한다.

**Sandbox**
: Keeper tool이 접근할 수 있는 writable filesystem 경계. 도구에는 반환된
  sandbox-relative path를 사용한다.

**Worktree**
: 한 repository 안에서 branch 작업을 격리하는 Git worktree.

## Continuity

**Checkpoint**
: History와 설정을 담은 Agent Core의 durable 저장점. trace당 파일 하나
  (`<trace 디렉터리>/<trace id>.json`)다. 실행 중에는
  `Keeper_types.working_context`가 이 checkpoint 하나를 감싼다.
  공식 클라이언트의 대화 이력은 이 파일에 옮겨 저장하지 않는다. MASC는
  클라이언트 세션 식별자와 turn 진행 상태를 별도의
  [공식 클라이언트 세션 저장소](../../lib/keeper/keeper_official_client_session_store.mli)에
  기록한다.
  → [Keeper_types.working_context](../../lib/keeper_types/keeper_types.mli)

**받은 일 정리**
: 미처리 event·chat 요청의 원본에 묶인 파생 맥락과 다음 행동 제안. 실행 권한이나
  checkpoint 이력이 아니다. 코드 이름은 `Keeper_librarian_context`다.
  → [Keeper_librarian_context](../../lib/keeper/keeper_librarian_context.mli)

**History**
: Checkpoint의 `messages`. 그 trace에서 오간 message가 시간순으로 쌓인 목록이다.
  Keeper turn은 이 목록 끝에 message를 덧붙인다. 목록 안에는 어느 message가 어느
  Keeper turn의 것인지 표시가 없다.
  `keeper_memory_search`가 여러 저장 위치의 사용자 본문을 합칠 때에는 추출한 본문
  전체의 일치로 중복을 판정한다. 현재 Working Context, 현재 trace의 저장된 메시지,
  `trace_history`에 기록된 trace 순서로 검색하며, 각 위치에서는 최신 메시지부터 읽는다.
  검색 결과 수는 검색어와 일치하고 중복되지 않는 본문에 적용한다. 그 전에 후보 메시지나
  원문 줄 수를 제한하지 않는다. 읽지 못한 파일·행은 `history_read_errors`로 알리며,
  불완전한 빈 검색 결과를 `no_match`로 표시하지 않는다.
  운영자의 `masc_keeper_clear`는 Keeper Owner의 배타적 유지보수 구간에서 비운다.
  함께 남아 있던 official-client session binding도 지워 다음 provider turn을 새 session으로
  시작한다. 진행 중인 turn이 있으면 거절하며, paused Keeper는 다시 실행하지 않고 비울 수 있다.

**Message**
: History의 한 항목. role(`System`, `User`, `Assistant`, `Tool`) 하나와 content
  조각(`Text`, `Thinking`, `ToolUse`, `ToolResult`, `Image`)의 목록으로 이뤄진다.

**Atom**
: History를 자를 때 쓰는 가장 작은 단위. `User` message 하나, 또는 `Assistant`
  message 하나와 그것에 답한 `Tool` message들이다. 따로 저장되지 않고 History를
  앞에서부터 세면 나온다(`Runtime_model_input_tail_window`). tool 호출과 결과가
  갈라지면 provider가 요청을 거절하므로 자르는 자리는 Atom 경계에만 온다. Atom의
  크기는 고르지 않아서 Atom 개수는 위치를 말할 뿐 요청 크기를 말하지 않는다.

**Carried Front (실어 보낼 이력의 시작 위치)**
: 요청에 실리는 가장 오래된 Atom의 번호와 그 Atom을 여는 Message의 digest.
  후보별 usage 원장에서 읽되, 같은 Keeper turn의 거절이 더 뒤로 옮긴 위치가 있으면
  그 위치를 쓴다. 반 자르기와 묶음 비우기 모두 다음 후보로 이 위치를 전달한다.
  다른 History의 위치는 digest가 맞지 않으므로 쓰지 않는다.

  저장된 응답 관측의 범위는 당시의 사실이다. 현재 카탈로그에서 그 runtime을
  지우거나 바꾸어도 이 사실을 취소하지 않으며, 현재 History의 같은 위치·digest로 검증한다.
  원장이 없으면 보관 중인 기록에서 같은 trace의 마지막 응답 관측까지 거슬러 찾는다.
  응답 없는 기록이 쌓여도 이 관측을 가리지 않는다. 재시도가 같은 turn 번호를 쓰면
  나중에 저장한 응답 관측을 선택한다. 다음 요청 예측도 같은 reader를 쓴다.

**Model Input Ledger (모델 입력 원장)**
: Keeper·runtime·trace별로 응답에서 확인한 Atom 범위와 제공된 usage를 기록한 프로세스 내 원장.
  상한 판정과 거절 뒤 이동은 후보 안의 작업값에 적용하고, 응답 관측으로 원장을 갱신한다.
  원장이 아직 세지 않은 위치까지 거절이 앞을 옮길 수 있다. 이때 다음 요청은 턴이
  보관한 Carried Front를 쓴다.

**Turn Boundary**
: 끝난 Keeper turn이 남기는 한 줄(`keepers/<keeper>/turn-boundaries.jsonl`).
  선택한 cluster의 runtime root 아래에 저장한다. 그 turn이
  끝났을 때 저장된 History가 몇 Atom인지와 마지막 Atom의 digest를 적는다.
  History 안에는 turn의 경계가 없으므로, turn이라는 사건을 History 안의 위치로
  옮겨 적는 유일한 기록이다. turn이 Atom이 없는 History에서 시작했는지
  (`fresh`/`continued`)도 같이 적는다. Checkpoint 파일이 있었는지가 아니라 Atom이
  있었는지로 정한다. Keeper는 빈 Checkpoint를 갖고 만들어지기 때문이다. 읽는 쪽은
  같은 재시작 구간 안의 줄을 Atom 수로 줄 세운다.
  같은 파일에 `history_restarted` 줄도 쌓인다. "이 trace의 Atom 번호가 이 줄부터
  0에서 다시 시작한다"를 말하는 줄이고, History를 다시 시작하게 만든 쪽이 쓴다.
  `masc_keeper_clear`는 비운 Checkpoint가 저장된 뒤에 쓴다. Atom이 없는 History에서
  시작하는 turn은, 저장된 History에 Atom이 없는 것을 알면 시작할 때 쓰고,
  Checkpoint를 못 읽어서 모르면 처음 받아들여진 저장 뒤에 쓴다. 읽는 쪽은 이 줄을
  보는 즉시 0부터 읽어도 되므로, 어느 쪽도 다시 시작하기 전에 쓰지 않는다. `fresh`
  줄과 `history_restarted` 줄은 읽는 쪽에 같은 말을 한다. 가장 최근의 이 두 종류
  중 하나부터 현재 History의 끝 경계를 고른다. 그 앞의 줄은 같은 메시지가 반복되어
  digest가 맞더라도 쓰지 않으며, `fresh` turn의 자기 끝 경계는 포함한다.
  이 파일의 Atom 위치는 선택한 cluster의 History만 가리키는
  cluster-scoped 좌표다. 같은 이름의 Keeper라도 다른 cluster와 공유하지 않는다.

**Read Position**
: Librarian이 History를 어디까지 읽었는지 적은 값(`keepers/<keeper>/librarian-progress.json`).
  Turn Boundary와 같은 cluster의 Keeper runtime 디렉터리에 저장한다.
  Turn Boundary 파일의 줄 번호가 아니라 값이다: trace, 읽은 Atom 수, 마지막으로
  읽은 Atom을 여는 Message의 digest. 그 파일에는 지난 History의 줄도 남아 있어서
  줄 번호로는 지금 History 안의 자리를 말할 수 없다. 파일이 없으면 아직 읽은 적이 없다는 뜻이다. 못
  읽는 파일은 "읽은 적 없음"으로 치지 않고 오류로 다룬다. 그렇게 치면 History
  전체가 안 읽은 것으로 보인다.
  이 값도 선택한 cluster의 Turn Boundary와 History에만 의미가 있으며, 다른
  cluster의 같은 이름 Keeper가 이어서 쓰는 공유 진행도가 아니다.
  Librarian이 이 값을 언제부터 읽고 쓰는지는 `RFC-librarian-lifecycle` §8을 본다.

**Generation**
: 같은 Keeper가 새 trace로 이어진 횟수. 초기값은 0이다.

**Trace ID**
: 현재 Keeper generation의 실행 식별자. Checkpoint의 `session_id` 필드와
  `Turn_ref`의 trace id가 이 값이다.

**Memory OS**
: Keeper의 durable personal facts와 recall을 소유하는 typed memory store.
  현재 Memory OS와 working context는 operator config의 Keeper 이름에 귀속되어,
  같은 base path에서 같은 이름을 쓰는 Keeper는 cluster가 달라도 공유한다.
  Turn Boundary와 Read Position만 cluster runtime 좌표로 분리된다.

**Working Context**
: Librarian이 Keeper가 받은 요청을 묶어 저장한 현재 작업 맥락. Memory OS와 같은
  operator-config Keeper 이름 범위이므로 같은 이름의 Keeper는 cluster 간에 공유한다.
  cluster별 Librarian Read Position과는 별개의 상태다.

**Fact**
: Memory OS의 기억 하나. 문장(`claim`), `category`, 처음·마지막으로 본 시각,
  `origin`, `basis`로 이뤄진다. id 필드는 없고 Memory ID는 `claim` 글자의
  SHA-256이다. 글자가 하나라도 다르면 다른 Fact다.

**Origin**
: Fact를 누가 적었나. `authored`는 Keeper가 `memory_write`로 직접 적은 것,
  `injected`는 Librarian이 대화에서 뽑아 넣은 것이다.

**Basis**
: Fact가 무엇에 근거하나. `observed`는 읽은 곳(자기 대화 또는 Board 글)을 갖고,
  `derived`는 근거가 된 다른 Fact의 Memory ID를 갖는다. 근거가 사라지면 `derived`
  Fact도 무효가 된다.

**Dropped / Supersedes / Absorbs**
: Librarian이 기억을 바꾸는 세 가지 말. `dropped`는 이유를 적고 버린다.
  `supersedes`는 옛 Fact 하나를 새 claim 하나로 고쳐 쓰며(1:1) 옛 id는 `dropped`
  에도 있어야 한다. `absorbs`는 Fact 여러 개를 새 claim 하나가 대신 말하며(N:1)
  그 id들은 `dropped`에 없어야 한다. 흡수된 원문은
  `<keeper>.memory-absorbed.jsonl`에 남는다. Librarian이 말하지 않은 Fact는
  그대로 남고, 규칙을 어긴 답은 통째로 거절된다.

**Memory Event**
: Fact에 일어난 일의 기록(`<keeper>.memory-events.jsonl`). `retrieved`는
  `keeper_memory_search` 결과에 나온 것, `revised`는 `supersedes`로 고쳐 써진
  것이다. `retracted`는 Keeper가 `keeper_memory_retract`로 그 Fact를 id로 지목해
  철회한 것이다. 철회 뒤 같은 claim을 다시 저장하면 같은 Memory ID에 과거 기록이
  붙는다. TUI의 `History: Retracted`는 그 철회 횟수이며, 현재 Fact의 신뢰도나
  강화 정도를 뜻하지 않는다.

**Librarian**
: Keeper마다 따로 도는 기억 정리자. Keeper의 History와 현재 facts를 읽고 LLM을
  한 번 불러, 더할 fact와 버릴 fact와 합칠 fact를 정해 Memory OS에 적는다. 같은
  호출에서 미처리 요청을 묶고 다음 행동을 제안한다. Keeper의 판단을
  대신하지 않는다.
  History를 읽는 경로의 구현 진척은 `RFC-librarian-lifecycle` §8을 본다.
  Agent Core의 읽은 위치가 저장되면 같은 wake에서 남은 이력을 계속 읽는다.
  읽을 것이 없거나 읽기·저장에 실패하면 멈추고, 실패한 범위는 다음 신호에서 다시 읽는다.
  매 회차 설정을 확인하므로 꺼진 동안에는 다음 범위를 읽지 않는다.
**JEV / Noul**
: JEV는 TypeSafe AI System One의 모델이다. Noul은 명시한 질문에 대한 답이
  참일 확률을 반환하는 응답 종류다. Noul 값은 기억 보존율이나 전체 기능의
  통과율이 아니다. Board의 Choice 판정과도 구분한다.
  Librarian에서는 새 claim이 흡수할 원문을 전달하는지 검사하며, 이 판정은
  Memory 저장 성공과 별개다. 실행의 `run.status`와 판정의 `absorb_gate.status`를 구분한다.
  `skipped`는 검사를 건너뛴 이유, `incomplete`는 중단 전에 완료된 응답만 담는다.
  `open`은 검사 실패 후 기존 처리 규칙에 따라 반환한 결과이고, `judged`는 검사를 마친 결과다.
  취소된 실행에서 완료된 응답이 보여도 Memory가 바뀌었다는 뜻은 아니다.
  반대로 실행의 `cancelled`도 Memory를 되돌렸다는 뜻은 아니다. 저장 뒤 취소되면
  `output.after`에 저장된 snapshot과 revision을 남긴다. 저장 전 취소는 이 기록이 없다.
  이미 저장된 실행 완료 결과는 이후 화면 갱신 알림의 취소로 덮어쓰지 않는다.

**Continuity Measurement (의미 보존 측정)**
: 특정 턴에서 만든 질문에 이후의 facts와 unread만으로 답하고, 참조 턴과
  비교해 그 답을 평가하는 관측. `masc-librarian-continuity`는 명시한 합성
  입력과 각 단계의 결과를 JSON 파일에 저장한다. TUI의 `/measurement SHA`는
  게시한 결과 사본을 읽는다. 운영 Librarian 실행이나 Memory 변경을 승인하는
  Gate가 아니다. 실행 방법과 결과의 한계는 [Benchmark Runbook](../BENCHMARK-RUNBOOK.md)을 본다.
