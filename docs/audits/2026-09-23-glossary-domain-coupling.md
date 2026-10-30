# 용어집과 도메인 결합 점검 (2026-09-23)

`docs/spec/00-glossary.md` 를 코드와 맞춰 읽었다. 대상은 Board, Task, Goal, Context,
Keeper, Librarian, Memory, HITL, 접근 제어, Multi Lane(Lane·Runtime·Candidate),
Schedule, TUI 화면(Attention, Team 블록)이다.

모든 줄 번호는 `origin/main` `5be342827e` 기준이다. 코드는 바꾸지 않았고 분리안은 제안이다.

TUI 에 Team 블록은 없다. `bin/masc_tui*.ml` 와 `lib/dashboard` 에서 `Team` 을 찾으면
하나도 안 나온다. 그래서 Team 블록은 아래 표에서 뺐다.

## (a) 어느 도메인이 어느 도메인을 품고 있나

"품는다"는 한쪽 타입이나 저장 파일이 다른 쪽 값을 필드로 들고 있다는 뜻이다.
id 문자열만 들고 있으면 "id 로만"이라고 적었다.

| 바깥 | 안쪽 | 어떻게 들고 있나 | 근거 |
|---|---|---|---|
| Task | Goal | Task 레코드에 `goal_id` 가 없다. 연결은 따로 된 표 `goal_task_links` 가 들고 있다 | `lib/types/types_core.mli:219`, `lib/task/task_goal_assignment.mli:6-7`, `lib/workspace/workspace_goal_index.mli:125` |
| Goal | Task | Goal 레코드에 Task 목록이 없다. Goal 을 지울 때만 연결 표를 정리한다 | `lib/goal/goal_store.mli:33`, `lib/goal/goal_store.ml:630` |
| Task(검증 제출) | Board, Fusion | `evidence_refs : string list` 에 `board:<글 id>`, `fusion:<실행 id>` 문자열로 든다 | `lib/types/types_core.mli:120`, `lib/workspace/workspace_verification_store.ml:117-125` |
| Board | Keeper | Keeper 타입을 안 쓴다. 작성자·대상은 Board 자기 `Agent_id.t` 다. 글 출처(`post_origin`)에서 Keeper 와 이어지는 필드는 `Ids.Turn_ref.t` 하나뿐이다 | `lib/board_types/board_types.mli:70-79`, `:112-121` |
| Board | Task, Goal | 전혀 안 든다. `lib/board/dune` 에 task·goal·keeper 라이브러리가 없다 | `lib/board/dune` |
| Keeper(Board 판정 후보) | Board | 후보 파일이 `Board_dispatch.board_signal` 을 통째로 든다. 제목과 본문이 들어 있다 | `lib/keeper/keeper_board_attention_candidate.mli:148-152`, `lib/board/board_dispatch.mli:73-81`, `lib/keeper/keeper_board_attention_candidate.ml:278-279` |
| Schedule | Keeper | Keeper 타입을 안 쓴다. 깨울 Keeper 이름은 payload 본문의 `"keeper_name"` 문자열이다. 깨우는 코드는 서버가 넣어 준다 | `lib/server/server_schedule_consumers.ml:389`, `lib/schedule/schedule_runner.mli:64-89`, `lib/server/server_bootstrap_maintenance.ml:522-523` |
| HITL(승인 대기) | Keeper, Task, Goal | `keeper_name`·`task_id`·`goal_id` 를 문자열로 든다. 다만 `Keeper_continuation_channel.t` 는 타입째 든다 | `lib/keeper_contract/keeper_approval_queue_rules_types.mli:129-142` |
| Keeper 실행 값 | Checkpoint | `Keeper_types.working_context` 는 필드가 `checkpoint` 하나뿐이다 | `lib/keeper_types/keeper_types.mli:36-38` |
| Librarian 결과 | Memory, Context | `selection` 이 `facts`(Memory OS 타입)와 `working_contexts`(pocket 목록)를 함께 든다 | `lib/keeper/keeper_librarian.mli:114-117` |
| Librarian | Memory OS | Librarian 이 Memory OS 를 쓴다. Memory OS 코드는 Librarian 을 부르지 않는다 | `lib/keeper/keeper_librarian.mli:100-116`, `lib/keeper/keeper_memory_os_current.mli:303`(주석만) |
| Memory OS | Keeper | 기억 꺼내기가 Keeper 메타 전체를 받는다 | `lib/keeper/keeper_memory_os_recall.mli:26` |
| Runtime(아래층) | Keeper(위층) | `lib/runtime/dune` 이 `masc.keeper_runtime` 을 쓴다. 효과 상세·재시도 시각 판정을 Keeper 모듈에서 가져온다 | `lib/runtime/runtime_claude_code.mli:138`, `lib/runtime/runtime_candidate_backpressure_state.ml:24` |
| Exact lane 기록부 | Librarian, HITL, Board, Workspace curator | 공용 기록부의 lane 타입이 위층 기능 넷을 이름으로 적는다. `Runtime.exact_lane` 은 Verifier 를 더해 다섯이다 | `lib/exact_lane_run_registry.mli:4-8`, `lib/runtime/runtime.mli:462-467` |
| Runtime 후보 | Provider 바인딩 | `candidate` 는 바인딩과 최근 rate limit·실패 관측을 든다 | `lib/runtime/runtime_candidate_backpressure.mli:24-39` |
| Memory queue | Keeper lane | `Keeper_memory_lane` 은 `Keeper_lane.t` 를 쓴다. `Runtime_lane`·exact lane 과는 관계없다 | `lib/keeper/keeper_memory_lane.ml:9,18` |
| TUI 개요 Attention | 서버 브리핑 | 서버 JSON(`/api/v1/dashboard/briefing`)을 읽는다 | `bin/masc_tui_loader.ml:1145-1213` |
| TUI Agenda | Task 저장소 | 서버를 거치지 않고 backlog 파일을 직접 읽어 운영자 목록을 다시 계산한다 | `bin/masc_tui_loader.ml:128-131`, `:173-191` |

접근 제어는 한 도메인이 아니다. 서로 모르는 개념 여섯이 따로 있다.

| 개념 | 정의 | 누가 지키나 |
|---|---|---|
| 에이전트 역할 `Worker`·`Admin` | `lib/types/types_auth.mli:45` | `Auth.check_permission` (`lib/auth/auth.mli:328`) |
| 도구 권한 `required_permission` | `lib/tool/tool_catalog.mli:28` | 위 역할 권한을 그대로 쓴다. 여기만 둘이 이어져 있다 |
| Keeper 도구 허용 목록 `attached_tool_allow` | `lib/keeper/keeper_types_profile_defaults.mli:36` | 도구 이름 문자열 목록이다. 위 권한과 안 이어진다 |
| HITL 허락 출처 `authorization_source` | `lib/keeper_contract/keeper_approval_queue_rules_types.mli:171` | 승인 대기열 |
| SubBoard 접근 `Open`·`Members_only`·`Owner_only` | `lib/board_types/board_types.mli:212` | 글 쓸 때만 검사한다 (`lib/board/board_core_persist.ml:516`). 읽기는 열려 있다 |
| Board 공개 범위 `Public`·`Unlisted`·`Internal`·`Direct` | `lib/board_types/board_types.mli:84` | 타입이 아니라 부르는 쪽이 지킨다. `list_posts` 는 필터를 안 주면 전부 준다 (`lib/board/board_core.ml:98`) |

## (b) 세지만 필요 없는 결합

"필요 없다"는 기준은 하나다. 받는 쪽이 실제로 읽는 값이 id 몇 개나 함수 하나인데,
다른 도메인의 레코드 전체나 내부 모듈을 가져오는 경우다.

### 1. TUI 가 서버를 건너뛰고 도메인 저장소를 직접 읽는다

- `bin/masc_tui_loader.ml:128-131` 이 `Workspace_backlog` 로 backlog 파일을 연다.
- `:173-191` 이 `Masc.Operator_task_attention.project` 를 직접 돌리고 그 생성자를 match 한다.
- 같은 목록을 서버도 따로 만든다 (`lib/dashboard/dashboard_attention.ml:120`).
- `lib/tui_decode.mli:2613-2618` 은 TUI 해석기인데 `Masc_domain.task` 를 받는다.
- `bin/masc_tui_render.ml:4881` 은 그리는 코드가 `Exact_lane_run_registry.Hitl_auto_judge` 를 match 한다.
- 용어집의 Surface 는 "각 표면은 독립 상태를 소유하지 않는다"고 적는다. 지금은 같은 목록을 두 곳에서 계산한다.

제안: Agenda 도 개요처럼 서버 브리핑의 운영자 Task 줄을 읽는다. `Tui_decode` 는 JSON 만 받고,
lane 은 서버가 준 이름으로 고른다.

### 2. Librarian 이 Keeper 메타 전체와 checkpoint 저장소 내부를 끌어온다

- `lib/keeper/keeper_librarian_durable_consumer.ml:561-571` 이 Keeper 메타 전체를 읽고
  `Keeper_checkpoint_store.load_agent_core` 를 직접 부른다.
- 쓰는 값은 `trace_id`, `instructions`, `total_turns`, `current_task_id` 넷과 checkpoint 의 `messages` 뿐이다
  (`keeper_librarian_durable_consumer.ml:587,1110`, `keeper_librarian_queue_refresh.ml:211-214,424-431`).
- `keeper_librarian_continuity.ml:4,53-62` 도 checkpoint 저장소의 오류 생성자를 그대로 match 한다.
- 그런데 Librarian 의 입력 타입은 이미 좁다. `messages : Agent_core.Types.message list` 다 (`keeper_librarian.mli:50`).
  넓은 결합은 입력을 만드는 쪽에만 있다.

제안: `trace_id -> 메시지 목록` 을 돌려주는 읽기 함수 하나와, 위 네 값만 담은 작은 레코드를 Keeper 쪽이 만들어 넘긴다.
Librarian 은 checkpoint 저장소 오류 타입을 모르게 된다.

### 3. 아래층 Runtime 이 위층 Keeper 와 그 기능 이름을 안다

- `lib/runtime/dune` 이 `masc.keeper_runtime` 을 쓴다.
  `runtime_candidate_backpressure_state.ml:24` 은 재시도 시각 판정을 `Keeper_runtime_failure_route` 에서 가져온다.
  `runtime_claude_code.mli:138` 은 `Keeper_terminal_effect_detail.t` 를 쓴다.
- `lib/exact_lane_run_registry.mli:4-8` 과 `lib/runtime/runtime.mli:462-467` 은 Librarian·HITL·Board 판정 같은
  위층 기능을 lane 이름으로 박아 둔다. `lib/runtime/runtime_schema.mli:332-333` 도 `board_attention`·`absorb_gate`
  두 필드를 설정 타입에 박는다.
- 새 exact lane 을 만들려면 Runtime 타입부터 고쳐야 한다.

제안: 재시도 판정과 효과 상세 타입을 Runtime 쪽 중립 모듈로 옮긴다. lane 이름은 Keeper 층이 정하고
Runtime 은 등록된 id 로만 받는다.

### 4. Board 판정 후보가 게시글 본문 사본을 저장한다

- 후보 레코드가 `Board_dispatch.board_signal` 을 통째로 든다 (`keeper_board_attention_candidate.mli:148-152`).
- 그 안에 `title`·`content` 가 있고 파일에 그대로 적힌다 (`board_dispatch.mli:73-81`, `keeper_board_attention_candidate.ml:278-279`).
- 후보 id 는 본문을 빼고 계산한다 (`keeper_board_attention_candidate.mli:220-221`). 즉 식별에는 본문이 필요 없다.
- Board 의 dispatch 타입이 바뀌면 Keeper 쪽 저장 파일 형식도 같이 바뀐다.

제안: Keeper 쪽이 판정용 사본 타입을 따로 갖는다. 모델 호출 전에 저장한다는 원칙은 그대로 두되,
Board 모듈 타입 대신 Keeper 가 소유한 필드만 적는다.

### 5. Schedule 소비자가 Keeper 내부 모듈 여럿을 직접 부른다

- Schedule 라이브러리 자체는 깨끗하다. Keeper 를 이름 문자열로만 안다. payload 는 추상 타입이고(`lib/schedule/schedule_domain.mli:67-74`), 이름은 서버 consumer 가 꺼낸다(`lib/server/server_schedule_consumers.ml:389`).
- 그런데 서버의 소비자 `lib/server/server_schedule_consumers.ml` 이 `Keeper_registry`(:405),
  `Keeper_meta_store`(:408), `Keeper_reaction_ledger`(:430-466), `Keeper_owner_registry`(:549),
  `Keeper_event_queue.scheduled_wake`(:1008) 를 한 파일에서 모두 부른다.

제안: Keeper 쪽에 "이 Keeper 를 이 긴급도로, 이 회차 id 로 깨워라" 함수 하나를 둔다. 소비자는 그것만 부른다.

### 그 밖에 확인한 결합

| 자리 | 가져오는 것 | 실제로 필요한 것 | 제안 |
|---|---|---|---|
| `lib/verification_collaboration_evidence.ml:29-30` | Board 저장소 레코드 필드 `workspace_masc_dir` | 디렉터리 하나 | Board 가 접근 함수를 내보낸다 |
| `lib/workspace/workspace_verification_store.ml:117-125` | `board:`·`fusion:` 접두 문자열 판별 | 근거 종류 | 근거를 닫힌 합타입으로 받고 문자열은 경계에서만 푼다 |
| `lib/goal/goal_store.ml:630` | Task 연결 표 정리 함수 | 지워진 goal id | Goal 은 id 를 돌려주고 연결 표 정리는 Task 쪽이 한다 |
| `lib/keeper/keeper_tool_board_runtime.ml:84` | Board 내부 모듈 `Board_core_classify` | 글 종류 이름 | `Board` 나 `Board_types` 가 내보낸다 |
| `lib/keeper/keeper_memory_os_recall.mli:26` | Keeper 메타 전체 | `name`, `trace_id` | 두 값을 인자로 받는다 |
| `lib/keeper_contract/keeper_approval_queue_rules_types.mli:142` | `Keeper_continuation_channel.t` | 이어갈 곳의 id | 승인 계약이 소유한 불투명 id 로 바꾼다 |
| `lib/keeper_approval/dune` | `masc.keeper_runtime`, `masc.keeper_failure_taxonomy` | 예외 기록 함수 하나, 위치 이름 하나 (`audit.ml:22,315,320,465`) | 콜백으로 받는다 |

## (c) 용어집 이름 문제

### 한 개념에 이름이 둘

| 항목 | 문제 | 처리 |
|---|---|---|
| Evidence / Evidence Reference | 같은 `evidence_refs` 를 두 항목이 따로 설명했다 | 이번 PR 에서 Evidence Reference 하나로 합쳤다 |
| 받은 일 정리 / Working Context | 서로를 가리키며 같은 묶음을 설명했다. RFC-librarian-lifecycle:54 는 `working_contexts` 를 "받은 일 정리"라 부른다 | 이번 PR 에서 "Working Context (받은 일 정리)" 하나로 합쳤다 |
| Assignee / Producer | `AwaitingVerification` 의 제출자를 두 이름으로 부른다. Producer 항목은 "이 RFC 의 1단계가 `assignee` 를 `producer` 로 바꾼다"는 계획을 적었지만 코드는 아직 `assignee` 다 (`types_core.mli:127-128`). `producer` 는 반려 기록에만 있다 (`types_core.mli:400`) | 이번 PR 에서 Producer 항목을 지금 코드 그대로 고쳤다. 필드 이름 통일은 코드 변경이라 남긴다 |
| Cluster / Memory OS / Working Context | cluster 공유 규칙을 세 항목이 따로 적었다 | Memory OS·Working Context 는 Cluster 항목을 가리키게 줄였다 |
| Continuity Snapshot / Working State | 두 항목이 "설명 절반·범위 절반" 을 서로 반복한다 | 남긴다. 합치려면 항목 구조를 다시 짜야 한다 |

### 한 이름에 개념이 둘 이상

| 이름 | 뜻들 | 근거 | 처리 |
|---|---|---|---|
| working context | ① Librarian 의 pocket 묶음 ② Keeper 가 쥔 checkpoint 하나를 담은 값 ③ Librarian 입력 필드 | `keeper_librarian.mli:117`, `keeper_types.mli:36-38`, `keeper_librarian.mli:49` | 용어집에 "다른 뜻" 을 적었다. 제안: 코드의 ② 를 `checkpoint_handle` 같은 이름으로 바꾼다 |
| lane | ① exact lane ② Runtime Candidate Order ③ Official Client Lane ④ Memory queue ⑤ Keeper fiber 칸 | `exact_lane_run_registry.mli:4`, `runtime_lane.mli:10`, `keeper_memory_lane.ml:9`, `keeper_lane.mli:1-8` | Lane 항목 경계에 ④⑤ 를 더했다. 제안: `Keeper_memory_lane` 을 `Keeper_librarian_queue` 로 |
| attention | ① Board 판정 후보 ② 운영자 Task 목록 ③ Dashboard 브리핑 항목(3단계) ④ TUI 개요 항목(4단계) | `keeper_board_attention_candidate.mli:148`, `operator_task_attention.mli:25`, `dashboard_attention.mli:17-19`, `bin/masc_tui_types.ml:1236-1241` | Operator Attention 항목에 "다른 뜻" 을 적었다. 제안: ③④ 의 심각도 단계를 하나로 맞춘다 |
| candidate | Board 판정 후보와 Runtime 후보 | 이미 용어집에 적혀 있다 | 그대로 둔다 |
| `Human_operator` | 완료 판정 주체, HITL 결정 출처, Schedule 요청자 종류 | `types_core.mli:85`, `keeper_approval_queue_rules_types.mli:162`, `schedule_domain.mli:8` | 코드 이름이라 두고 기록만 한다 |

### 딱딱하거나 뜻이 흐린 말

이번 PR 에서 코드 이름은 건드리지 않고 문장만 고쳤다.

| 항목 | 전 | 후 |
|---|---|---|
| Board | 공유 발견… 결정을 게시하는 durable 협업 표면 | 에이전트와 사람이 발견·질문·답변·의견·결정을 올리는 게시판. 글마다 보는 범위가 있고 재시작해도 남는다 |
| Schedule | 미래 시점에 Keeper를 깨우는 durable 요청… 외부 효과를 자동 승인하지 않는다 | 정한 시각에 Keeper를 깨우라는 요청… 깨어난 Keeper가 하려는 바깥 작업을 대신 허락하지 않는다 |
| HITL | Gate의 외부 효과를 사람이 판정하는 비차단 권한 경로 | Gate에 걸린 바깥 작업을 사람이 허락하거나 거절하는 경로 |
| Gate | 외부 효과를 Always Allowed, Auto Judge, HITL 중… 판정하는 경계 | 코드의 세 값(`Keeper_gate_mode.t`: `Always_allow`·`Auto_judge`·`Manual`)으로 적는다. 문장은 #38228 것을 쓴다 |
| Task | 판정자의 이름은 authority이고… authority 경계에서만 적용된다 | 판정하는 쪽은 authority로, 일을 낸 쪽은 `producer`로 적는다… 판정 에이전트나 인증된 운영자만 내린다 |
| Memory OS | durable personal facts와 recall을 소유하는 typed memory store | Keeper 하나가 오래 들고 가는 기억(Fact)을 저장하고 다시 꺼내 주는 곳 |

### 정의가 없는 말

- **Keeper Owner**: Keeper Chat Operation 항목과 History 항목이 쓰지만 항목이 없다.
  코드는 `lib/keeper/keeper_owner.mli:1` "Keeper 하나의 메타데이터를 혼자 바꾸는 fiber" 다.
  제안 문구: "Keeper 하나의 메타데이터와 작업 접수를 혼자 바꾸는 fiber. 다른 코드는 메일박스로 요청한다."
- **Access Control**: 용어집에 항목이 없다. 위 (a) 의 여섯 개념이 따로 있다는 것부터 적는 항목을 제안한다.
