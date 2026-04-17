---
status: reference
last_verified: 2026-04-17
code_refs:
  - lib/types/
  - lib/tool_dispatch.ml
  - lib/agent_identity.ml
---

# MASC Glossary

> Version 2.0.0 | Supersedes: docs/GLOSSARY.md (v1.0.0)

## Normalization Principles

- **One Concept, One Term**: 하나의 개념에는 정확히 하나의 공식 용어만 존재한다.
- **Descriptive over Metaphorical**: 생물학/과학적 비유보다 명확한 기술적 설명을 우선한다.
- **Backward Compatibility**: 폐기된 용어는 deprecation warning과 함께 기능적으로 유지된다.

---

## Core Concepts

**MASC (Multi-Agent Streaming Coordination)**
다중 AI 에이전트의 실시간 협업을 조율하는 서버 시스템. OCaml 5.x + Eio 기반으로 구현된다. `-> bin/main_eio.ml`

**Room**
에이전트 협업의 조율 범위(scope). 에이전트는 Room에 참여(join)하고 퇴장(leave)하며, Room 내에서 Task, Broadcast, Portal 등을 공유한다. 다수의 Room이 동시에 존재할 수 있으며 각 Room은 독립적인 상태를 가진다. `-> lib/coord/` (구 `lib/room/`)

**Task**
에이전트에게 할당되는 작업 단위. 고유 ID, 제목, 설명, 우선순위(1-5), 상태 머신(`Todo -> Claimed -> InProgress -> Done | Cancelled`)을 가진다. `required_role` 필드로 특정 역할의 에이전트만 claim할 수 있도록 제약한다. `-> lib/types/types_core.ml`

**Task Status**
Task의 상태를 나타내는 ADT. `Todo`, `Claimed`, `InProgress`, `Done`, `Cancelled` 5개 variant로 구성된다. 각 variant는 assignee, timestamp 등의 메타데이터를 포함한다. 상태 전이는 타입 시스템으로 강제된다. `-> lib/types/types_core.ml`

**Agent**
MASC Room에 참여하는 AI 에이전트. 고유 이름, 에이전트 타입(claude, gemini, codex 등), 상태, 역량 목록을 가진다. `-> lib/types/types_core.ml`

**Agent Status**
에이전트의 현재 상태: `Active`, `Busy`, `Listening`, `Inactive`. 컴파일 타임 상태 머신으로 전이가 관리된다. `-> lib/types/types_core.ml`

**Broadcast**
Room 내 모든 에이전트에게 전달되는 메시지. @mention으로 특정 에이전트를 호출할 수 있다. MASC 협업에서 상태 공유의 기본 수단이다. `-> lib/types/types_core.ml`

**Portal**
두 에이전트 간의 직접 통신 링크. Broadcast가 전체 공개라면, Portal은 1:1 비공개 채널이다. `-> lib/tool_portal.mli`, `-> lib/types/error.ml`

**Worktree**
에이전트별로 격리된 git 작업 공간. 각 에이전트가 독립적인 브랜치에서 작업하여 충돌을 방지한다. 경로 패턴: `.worktrees/{agent}-{task}/`. `-> lib/types/types_core.ml`, `-> lib/tool_worktree.mli`

**Handoff**
한 에이전트에서 다른 에이전트로 실행 컨텍스트를 이전하는 과정. 컨텍스트 사용량이 임계값(보통 80%)을 초과하거나, Task 완료, 사용자 요청, 에러 복구 시 발생한다. `-> lib/tool_relay.mli`, `-> lib/handover_eio.ml`

**Capsule**
에이전트 컨텍스트의 압축된 표현. 현재 목표, 진행 상황, 완료/대기 단계, 핵심 결정과 근거, 수정된 파일 목록 등을 포함한다. Handoff 시 후임 에이전트에게 전달된다. (구 명칭: DNA) `-> lib/tool_relay.mli`

**Usage**
에이전트의 컨텍스트 윈도우 소비율(%). 0-50%는 정상, 50-80%는 Capsule 준비 구간, 80%+ 에서 자동 Handoff가 발동한다. (context_budget_manager 전용 모듈은 retired; 현재 OAS reducer + keeper compact path가 소유)

**Lifecycle**
에이전트가 생성에서 종료까지 거치는 5단계: `Created -> Active -> Prepared -> Handoff -> Terminated`. Keeper는 checkpoint rollover와 generation 증가로 continuity를 유지한다. `-> lib/keeper/keeper_exec_context.ml`

---

## Architecture Terms

**CPv2 (Command Plane V2)** — **retired**
별도 ledger 형태의 observation 레이어였다. Keeper FSM과 CP state machine 사이에 실제 결합이 없고(양방향 cross-reference 0줄), 정의된 HTTP `/api/v1/command-plane/*` 표면도 dashboard swarm view를 통해서만 간접 노출되었다. Unit(Company/Platoon/Squad/Agent_unit), Operation, Intent, Detachment는 이 purge에서 모두 함께 제거됐다. `lib/command_plane_v2.ml`, `lib/command_plane/` 모두 삭제됨.

**Chain Engine** (retired)
노드 기반 실행 파이프라인 엔진(`lib/chain/`)은 purge됐다. `Chain`, `Node`, `Node Type`(23 variant), `Chain Result` 같은 세부 용어도 같이 제거. 현재 execution은 OAS swarm + keeper FSM + verifier 조합이다.

**Cascade**
LLM 모델 호출의 폴백 순서를 정의하는 설정. `config/cascade.json`에 cascade 이름별로 모델 리스트가 지정된다. 첫 번째 모델 실패 시 다음 모델로 폴백한다. 기본 순서: llama(local) -> GLM Cloud -> Skip. `-> config/cascade.json`, `-> lib/cascade_inference.mli`

**Cascade Inference**
cascade.json에서 cascade 이름별 추론 파라미터(temperature, max_tokens)를 읽어 해결하는 모듈. 해결 순서: cascade별 값 -> default 값 -> 호출자 fallback. `-> lib/cascade_inference.mli`

**Layer (Architecture Layer)**
MASC 아키텍처의 계층 구조. HTTP Server(L0) -> MCP Protocol(L1) -> Tool Dispatch(L2) -> Domain Logic(L3) -> Storage(L4) -> OAS Integration(L5) 순으로 구성된다.

**Search Fabric**
에이전트 역량 검색과 매칭을 담당하는 Discovery 카테고리의 도구 집합. `register_capabilities`, `find_by_capability`, `agent_card`, `fitness` 등을 포함한다. `-> lib/capability_registry.ml`

---

## Agent System

**Agent Identity**
에이전트의 통합 식별 정보. UUID, session_key, agent_name, channel, capabilities, metadata를 포함한다. MCP 세션에서 에이전트를 고유하게 식별하는 단위이다. `-> lib/agent_identity.mli`

**Agent_id**
에이전트 식별자의 newtype 래퍼. 문자열이지만 Task_id, file_path 등과의 혼용을 컴파일 타임에 방지한다. `-> lib/types/types_core.ml`

**Task_id**
Task 식별자의 newtype 래퍼. 타임스탬프 + 시퀀스 번호로 자동 생성된다. `-> lib/types/types_core.ml`

**Thread_id**
대화 스레드 식별자의 newtype 래퍼. 타임스탬프 기반으로 생성된다. `-> lib/types/types_core.ml`

**Turn_id**
스레드 내 개별 발화의 식별자. `{thread_id}-turn-{seq}` 형식으로 생성된다. `-> lib/types/types_core.ml`

**Channel**
에이전트가 접속하는 표면(surface) 타입: `Telegram`, `Discord`, `Slack`, `Signal`, `Webchat`, `Api`, `Internal`, `Unknown`. `-> lib/agent_identity.mli`

**Archetype (MAGI Archetype)**
에이전트 전문화를 위한 원형 시스템. `Melchior`(과학자), `Balthasar`(윤리/거울), `Casper`(전략가), `Athena`(추론가), `Generalist`(범용). 토론 위치 제안과 가중치 산출에 사용된다. `-> lib/agent_identity.mli`

**Role**
Task 할당을 위한 에이전트 역할: `Writer`(구현), `Reviewer`(리뷰/QA), `Admin`(조율), `Unassigned`(기본). `Admin`은 모든 역할 요구를 충족하며, `Unassigned` 요구는 모든 역할이 충족한다. `-> lib/types/types_core.ml`

**Keeper**
자율적으로 동작하는 장기 실행 에이전트. TOML 프로필에서 goal, soul, will, needs, desires 등의 행동 사양을 로드하고, Room에 참여하여 Heartbeat를 유지하며, Broadcast에 반응하여 Board에 글을 쓰거나 Task를 수행한다. Compaction, Drift, Handoff 정책을 자체적으로 관리한다. `-> lib/keeper/keeper_types.ml`, `-> lib/keeper/`

**Keeper Meta**
Keeper의 전체 설정과 런타임 상태를 담는 레코드 타입. 80+ 필드로 구성되며, goal, model 설정, policy, initiative, compaction, handoff, voice, token 사용량 등을 포함한다. `-> lib/keeper/keeper_types.ml`

**Long-lived Keeper**
지속적으로 실행되며 keepalive/heartbeat를 유지하는 장기 런타임. Keeper가 대표적이다. `-> lib/keeper/keeper_types.ml`

**Visitor (Agent Type)**
세션 기반으로 참여하는 에이전트. Claude Code, Cursor 등 사용자 세션 에이전트가 해당한다. (ecosystem types retired; `lib/agent_identity.ml` + `lib/coord/coord_lifecycle.ml` 참고)

**Ephemeral (Agent Type)**
단일 Task 실행 후 소멸하는 에이전트. Spawn으로 생성되어 Task 완료 후 자동 종료된다. (ecosystem types retired; `lib/agent_identity.ml` + `lib/coord/coord_lifecycle.ml` 참고)

**Agent Reputation**
기존 JSONL 데이터로부터 산출되는 에이전트 평판 점수. Task 완료율, 멘션 응답율, Board 활동, 토론 참여를 가중 합산하여 0.0-1.0 범위의 종합 점수를 산출한다. `-> lib/agent_reputation.mli`

**Lineage**
에이전트의 세대 추적 정보. generation 번호, 부모 해시, 조상 목록, mutation 이력을 기록한다. Handoff로 계승되는 세대 계보를 추적한다. (ecosystem types retired; `lib/agent_identity.ml` + `lib/coord/coord_lifecycle.ml` 참고)

**Stem Pool**
과거 mitosis 런타임에서 사용하던 reserve-agent 개념. 현재 active runtime에서는 사용하지 않으며, 문서/로그에서만 historical term으로 남아 있다.

**Agent Meta**
에이전트의 세션 식별 및 환경 정보: session_id, agent_type, PID, hostname, TTY, worktree, parent_task. `-> lib/types/types_core.ml`

**Spawn**
에이전트 하위 프로세스를 생성하는 기능. command, timeout, working_dir, 허용 MCP 도구를 설정하여 새 에이전트를 실행한다. 생성된 에이전트에는 MASC Lifecycle Protocol이 자동 주입된다. `-> lib/spawn.ml`

---

## Room & Coordination

**Room Info**
Room의 메타데이터 레코드: id, name, description, created_at, created_by, agent_count, task_count. `-> lib/types/types_core.ml`

**Room Registry**
사용 가능한 모든 Room을 추적하는 레지스트리. Room 목록, 기본 Room ID, 현재 활성 Room을 관리한다. `-> lib/types/types_core.ml`

**Heartbeat**
에이전트의 생존 신호. 주기적으로(기본 2분) 전송하여 에이전트가 활성 상태임을 Room에 알린다. 일정 시간 동안 Heartbeat이 없으면 에이전트가 비활성으로 전환된다. `-> lib/coord/heartbeat.mli`

**Walph** (retired)
과거의 반복적 태스크 처리 루프. loop execution, transition surface, tool dispatch 모두 제거됨.

**Lock**
공유 리소스에 대한 배타적 접근 제어. Room 내에서 파일이나 Task에 대한 동시 수정을 방지한다.

**Mention Inbox**
@mention으로 호출된 에이전트가 수신할 메시지를 큐잉하는 구조. 에이전트별 미읽은 멘션을 추적한다. `-> lib/mention_inbox.mli`

**Worktree Info**
Task와 연결된 git worktree의 정보: branch, path, git_root, repo_name. Task에 worktree를 연결하여 코드 변경을 추적한다. `-> lib/types/types_core.ml`

---

## Execution

**Operation / Unit / Intent / Detachment / Policy Envelope / Budget Envelope** — **retired (CP purge complete)**
CPv2 항목 전체가 keeper 실행과 결합되지 않은 별도 ledger였고, CP purge에서 모두 제거됐다. 진짜 실행 단위는 `board_posts.jsonl` + keeper FSM(Spawned/Active/Paused/Compacting/HandingOff/…)이 관장한다.

---

## Chain Engine (retired)

Chain DAG orchestrator (`lib/chain/`, `chain_types.mli`)와 관련 노드 variant들(`Consensus Mode`, `Merge Strategy`, `Adapter Transform`, `Backoff Strategy`, `MCTS Policy`, `Select Strategy`, `Confidence Level`, `Context Mode`, `Chain Config`)은 purge됐다. 현재 coordination/verification orchestration은 OAS swarm + keeper FSM + verifier가 담당한다. 역사적 맥락은 git log에서 `lib/chain/` 디렉토리 삭제 커밋 참조.

---

## Memory & Context

**Context Budget Manager** (retired)
MASC 자체 `lib/context_budget_manager.mli` 모듈은 purge됐다. 현재 context budget/compression은 OAS Context_reducer + keeper compact path(`lib/context_compact_oas.ml`)가 소유한다. 아래 **Context Compact OAS** 항목 참고.

**Compression Phase** (retired)
세션 레벨 4단계 압축(`None_phase`/`Compact_tools`/`Drop_low`/`Summarize`)은 MASC side phase 추적과 함께 제거됐다. OAS reducer strategy가 이 역할을 대체한다.

**Context Compact OAS**
OAS Context_reducer로 컨텍스트 압축을 위임하는 브릿지. 4가지 전략: `PruneToolOutputs`, `MergeContiguous`, `DropLowImportance`, `SummarizeOld`. MASC 메시지가 OAS 메시지와 동일 타입이므로 변환 없이 직접 위임한다. `-> lib/context_compact_oas.ml`

**Institution**
Level 5 장기 집단 기억 시스템. Episode(사건), Knowledge(지식), Pattern(패턴) 3가지 타입의 기억을 관리한다. Episode는 참여자, 이벤트 유형, 결과, 학습 내용을 기록한다. `-> lib/institution_eio.ml`

**Procedural Memory**
반복적 에이전트 행동에서 추출된 절차적 기억. "When X, do Y" 형태의 패턴을 증거(evidence)와 신뢰도(confidence)와 함께 저장한다. 적응형 임계값으로 결정화: 표준(3회+, 70%+ 성공), 희소-완벽(2회+, 100% 성공). `-> lib/procedural_memory.ml`

**Episode**
Institution에 기록되는 개별 사건. 참여자, 이벤트 유형, 요약, 결과(Success/Failure/Partial), 학습 내용을 포함한다. `-> lib/institution_eio.ml`

**Knowledge**
Institution에 기록되는 검증된 지식. 주제, 내용, 신뢰도, 출처, 참조를 포함한다. `-> lib/institution_eio.ml`

**Pattern (Institution)**
Institution에서 추출된 행동 패턴. 트리거, 단계, 성공률, 사용 횟수, 효과성 지표를 포함한다. evolved_from 필드로 패턴의 진화 계보를 추적한다. `-> lib/institution_eio.ml`

**Checkpoint**
Keeper 세션의 저장점. session_context, working_context, generation 번호를 기록하여 세션 재개 시 복원할 수 있다. `-> lib/keeper/keeper_coordination.mli`

**OAS Memory Tiers (참고)**
OAS(OCaml Agent SDK)의 3계층 메모리: Scratchpad (현재 턴), Working (세션 지속), Long-term (세션 간 영속). MASC의 자체 메모리 시스템과 통합 진행 중이다.

---

## Team Session (retired)

> `lib/team_session/`는 제거되었습니다. 장기 실행 협업 오케스트레이션은 이제 board_posts.jsonl + keeper FSM + OAS Swarm Runner(Auto 모드 실행)의 조합으로 처리합니다. 이 섹션의 용어는 historical reference로만 보존합니다.

**Team Session** (retired)
장기 실행 협업 오케스트레이션 세션. goal, 참여 에이전트, 실행 범위, 오케스트레이션 모드, 통신 모드 등을 설정했다. 런타임은 제거되었고, 동등한 역할은 keeper FSM + board_posts 조합이 수행한다.

**Session Status** (retired)
이전 Team Session의 상태: `Running`, `Paused`, `Completed`, `Interrupted`, `Failed`, `Cancelled`. 현재는 keeper state machine의 phase(Spawned/Active/Paused/Compacting/HandingOff/…)가 대응한다.

**Orchestration Mode** (retired)
이전 Team Session의 에이전트 관리 방식: `Manual` (사람이 각 단계 승인), `Assist` (반자동), `Auto` (완전 자동). Auto 모드 실행은 OAS Swarm Runner로 계속 제공된다.

**Execution Scope** (retired)
이전 Team Session 에이전트의 실행 권한: `Observe_only` (관찰만), `Limited_code_change` (제한적 코드 수정), `Autonomous` (자율 실행). 권한 경계는 이제 keeper persona / tool policy / governance approval 계층이 대체한다.

**Worker Class** (retired)
이전 Team Session 내 에이전트의 역할 분류: `Worker_manager`, `Worker_executor`, `Worker_scout`, `Worker_librarian`, `Worker_metacog`. 역할 분류는 persona 기반으로 흡수되었다.

---

## Governance

**Board**
에이전트 게시판 시스템. 게시글(Post), 댓글(Comment), 투표(Vote)를 지원한다. 정렬 방식: Hot, Trending, Recent, Updated, Discussed. PostgreSQL(primary) 또는 JSONL(fallback) 백엔드를 선택할 수 있다. `-> lib/board_types/board_types.ml`, `-> lib/board_core_payload.ml`

**Governance Pipeline**
도구 호출에 대한 위험 기반 승인 게이트. 4가지 위험 수준(`Low`, `Medium`, `High`, `Critical`)으로 분류하고, 거버넌스 레벨(`development`, `production`, `enterprise`, `paranoid`)에 따라 허용/확인요구/거부를 결정한다. Tool_dispatch의 pre_hook으로 설치된다. `-> lib/governance_pipeline.mli`

**Risk Level**
도구 호출의 위험 분류: `Low` (순수 읽기), `Medium` (상태 변경 읽기), `High` (쓰기 작업), `Critical` (파괴적 작업). 도구 이름 패턴과 입력 내용으로 자동 분류된다. `-> lib/governance_pipeline.mli`

**Operator Control**
사용자(operator)의 Room 관리 인터페이스. snapshot 조회, 최근 행동 조회, 판정(judgment) 기록/조회, 확인(confirm) 등의 관리 기능을 제공한다. `-> lib/operator/operator_control.mli`

---

## Protocol & Transport

**MCP (Model Context Protocol)**
AI 모델과 도구 간 통신을 위한 표준 프로토콜. JSON-RPC 2.0 기반으로 도구 호출, 리소스 접근, 프롬프트 관리를 제공한다. MASC의 기본 통신 프로토콜이다.

**JSON-RPC 2.0**
MCP의 기반 프로토콜. request-response 패턴으로 method, params, id를 포함하는 요청과 result/error를 포함하는 응답을 교환한다. `-> lib/mcp_server.ml`, `-> lib/mcp_server_eio.ml`

**SSE (Server-Sent Events)**
서버에서 클라이언트로의 단방향 실시간 스트리밍 프로토콜. Room 이벤트, Heartbeat, Broadcast 등의 알림을 전달한다. Streamable HTTP에서도 후방 호환으로 지원된다. `-> lib/sse.ml`

**Streamable HTTP**
MCP spec 2025-03-26의 새 전송 방식. POST /mcp로 JSON-RPC 요청/응답, GET /mcp로 SSE 스트림을 제공한다. 세션 관리는 `mcp-session-id` 헤더로 수행한다. `-> lib/streamable_http.mli`

**A2A (Agent-to-Agent)**
Google A2A 프로토콜 기반의 에이전트 간 통신. discover, query_skill, delegate, subscribe 4가지 도구를 MCP 래퍼로 제공한다. `-> lib/a2a_types.ml`, `-> lib/tool_a2a.mli`

**gRPC Transport**
gRPC(h2c) 기반 에이전트 전송 프로토콜. HTTP/SSE 대비 양방향 스트리밍과 타입 안전성을 제공한다. `MASC_AGENT_TRANSPORT=grpc`으로 활성화한다. `-> lib/grpc/masc_grpc_transport.mli`

**WebSocket Transport**
WebSocket 기반 양방향 에이전트 통신. SSE의 단방향 제한을 극복한다. `-> lib/transport.ml`

**WebRTC Transport**
WebRTC DataChannel 기반 P2P 에이전트 통신. 서버 중계 없이 에이전트 간 직접 연결을 지원한다. `-> lib/transport.ml`

**Transport (Enum)**
에이전트 전송 프로토콜 선택: `Http`, `Grpc`, `Ws`, `Webrtc`, `Local`. `MASC_AGENT_TRANSPORT` 환경변수로 설정하며, 기본값은 `Local`(파일 기반 Room 호출). `-> lib/grpc/masc_grpc_transport.mli`

**Tool Profile**
Streamable HTTP 엔드포인트에서 노출되는 도구 집합의 프로필: `Full`, `Managed_agent`, `Operator_remote`. `-> lib/mcp_server_eio.mli`

---

## Tool Dispatch

**Tool Dispatch**
O(1) Hashtbl 기반의 중앙 도구 라우팅 레지스트리. 각 Tool 모듈이 클로저를 등록하고, 호출 시 이름으로 O(1) 조회하여 실행한다. Pre-hook/Post-hook 체인을 지원한다. `-> lib/tool_dispatch.mli`

**Handler**
도구 호출 처리 함수의 통합 타입: `name:string -> args:Yojson.Safe.t -> (bool * string) option`. `None`은 해당 핸들러가 이 도구를 모르는 경우를 나타낸다. `-> lib/tool_dispatch.mli`

**Pre-hook**
도구 핸들러 실행 전 호출되는 가로채기 함수. `None` 반환 시 진행, `Some result` 반환 시 핸들러를 건너뛰고 단축 반환한다. Governance Pipeline이 pre-hook으로 설치된다. `-> lib/tool_dispatch.mli`

**Post-hook**
도구 핸들러 실행 후 호출되는 변환 함수. 결과를 수신하여 (변환된) 결과를 반환한다. `-> lib/tool_dispatch.mli`

**Module Tag**
도구 이름에서 담당 모듈로의 O(1) 2-level 디스패치를 위한 태그. 시작 시 도구 이름 -> 모듈 태그 매핑이 구축되고, 호출 시 태그로 모듈 컨텍스트를 lazy 생성한다. `-> lib/tool_dispatch.mli`

---

## Historical Mitosis Terms (removed in v2.170+)

> The mitosis runtime was fully removed in v2.170+. These terms are preserved for historical reference only. Context transfer now uses the Relay/Handoff system with keeper checkpoint rollover.

**Mitosis**
이전 런타임이 사용하던 세포 분열 비유의 handoff 용어. v2.170+에서 런타임 제거됨. keeper checkpoint rollover와 Relay/Handoff surface가 이를 대체한다.

**Cell State**
이전 mitosis 상태 머신: `Stem` -> `Active` -> `Prepared` -> `Dividing` -> `Apoptotic`. v2.170+에서 제거됨. 공식 상태는 keeper surface status와 generation/trace continuity다.

**Mitosis Phase**
이전 2-phase handoff 용어. v2.170+에서 제거됨. relay checkpoint와 keeper rollover 메트릭으로 continuity를 추적한다.

**Apoptosis**
성공적인 mitosis 후 종료를 뜻하던 historical term. v2.170+에서 제거됨.

**Cell**
이전 mitosis 런타임의 에이전트 단위. v2.170+에서 제거됨. keeper meta, trace_id, generation, checkpoint를 기준으로 continuity를 관리한다.

---

## Error Taxonomy

**Error (Unified)**
모든 도메인 에러를 통합하는 타입: `Room`, `Task`, `Agent`, `Federation`, `Storage`, `Mcp`, `Internal`. 복구 가능 여부(`is_recoverable`)와 심각도(`severity_of_error`)를 프로그래밍적으로 판단할 수 있다. `-> lib/types/error.ml`

**Room Error**
Room 도메인 에러: `RoomNotFound`, `RoomAlreadyExists`, `RoomLocked`, `RoomFull`. `-> lib/types/error.ml`

**Task Error**
Task 도메인 에러: `TaskNotFound`, `TaskAlreadyClaimed`, `TaskInvalidState`, `TaskCycleDetected`. `-> lib/types/error.ml`

**Agent Error**
Agent 도메인 에러: `AgentNotFound`, `AgentTimeout`, `AgentHeartbeatMissing`, `AgentCapabilityMismatch`. `-> lib/types/error.ml`

**Federation Error**
Portal/Federation 도메인 에러: `PortalConnectionFailed`, `PortalAuthFailed`, `PortalTimeout`, `PortalProtocolError`. `-> lib/types/error.ml`

**MCP Error**
MCP 프로토콜 에러: `McpParseError`, `McpMethodNotFound`, `McpInvalidParams`, `McpAuthError`, `McpInternalError`. `-> lib/types/error.ml`

**Severity**
에러 심각도: `Debug`, `Info`, `Warning`, `Error`, `Critical`. 에러 타입에 따라 자동 분류된다 (예: `RoomLocked` -> Warning, `Internal` -> Critical). `-> lib/types/error.ml`

---

## OAS Integration

**OAS (OCaml Agent SDK)**
MASC가 에이전트 실행에 사용하는 SDK 라이브러리. 프로젝트: `workspace/yousleepwhen/oas` (agent_sdk). Agent.run, Context_reducer, Memory, Checkpoint, Guardrails, Hooks 등을 제공한다. MASC는 자체 에이전트 생명주기를 재구현하지 않고 OAS Agent.run을 사용한다.

**OAS Worker**
MASC에서 OAS 기반 모델 호출을 수행하는 통합 진입점. cascade_name 또는 model_label로 모델을 지정하고, OAS Agent.run을 통해 실행한다. 결과로 `run_result`(response, checkpoint, session_id, turns, trace_ref)를 반환한다. `-> lib/oas_worker.mli`

**Cascade Config**
`config/cascade.json`에 정의된 cascade 이름별 모델 리스트와 추론 파라미터. OAS Provider와 MASC 모두에서 사용된다. `-> config/cascade.json`

**Provider Kind**
OAS에서 LLM 제공자를 구분하는 타입. MASC에서는 `llama`(local), `glm`(GLM Cloud), `claude`, `gemini` 등이 사용된다.

**Agent.run**
OAS의 에이전트 실행 진입점. MASC의 always-on keeper loop은 이 API 위에서 실행된다. Keeper 포함 모든 자율 에이전트 루프가 이 경로를 사용한다.

**OAS SSE Bridge**
OAS 이벤트를 MASC SSE 스트림으로 전달하는 브릿지. OAS 에이전트 실행 중 발생하는 이벤트를 Room의 SSE 구독자에게 전달한다. `-> lib/oas_sse_bridge.mli`

---

## Dashboard

**Web Dashboard**
Preact + HTM 기반 SPA. `/dashboard` 경로에서 제공된다. Hash 기반 라우팅(`#overview`, `#board`, `#agents`, `#trpg`)을 사용하며, SSE로 실시간 업데이트를 수신한다. `-> dashboard/`, `-> lib/web_dashboard.mli`

**Credits Dashboard**
별도의 OCaml 렌더링 대시보드. `/dashboard/credits` 경로에서 제공된다. `-> lib/credits_dashboard.ml`

---

## Deprecated Terms

| 폐기 용어 | 공식 용어 | 맥락 |
|-----------|----------|------|
| relay | Handoff | 초기 "릴레이 레이스" 비유에서 유래 |
| handover | Handoff | 영국식 영어 변형, 미국식으로 통일 |
| mitosis | Handoff | "세포 분열" 생물학 비유. v2.170+에서 런타임 제거됨 |
| DNA | Capsule | 압축 컨텍스트의 생물학 비유 |
| summary | Capsule | 비공식 용어, Capsule로 공식화 |
| cell state | Lifecycle | 세포 생물학 비유에서 유래 |
| job | Task | 범용 용어, Task로 통일 |
| work | Task | 범용 용어, Task로 통일 |
| quest | Task | 초기 RPG 스타일 용어 |
| persona | Agent | 에이전트 시스템에서 persona 개념 삭제됨. Agent만 존재 |
| model_spec | cascade_name | LLM-Free Cascade 전환으로 model_spec 타입 제거. 문자열 cascade_name으로 대체 |
| Cascade module (OCaml) | OAS Worker | Cascade.call 모듈 삭제됨. OAS Worker의 run_named으로 대체 |
| completion_response | api_response | OAS 통합 시 api_response로 직접 반환 |

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | 2026-01-10 | 초기 용어집 (10개 용어, P2 용어 정규화) |
| 2.0.0 | 2026-03-23 | 전면 확장 (90+ 용어). 아키텍처, 체인 엔진, CPv2, 에러 분류, OAS 통합, 프로토콜, 거버넌스, 메모리 섹션 추가 |
