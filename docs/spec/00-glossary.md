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

**Agent Run (에이전트 실행)**
: `Agent_core.Agent`를 거치는 한 번의 실행. 그 수명주기를 `Agent_core.Event_bus`의 typed
  event가 그린다 — `agent_started`·`agent_completed`·`agent_failed`·`agent_yielded`·`…`.
  Keeper turn과 같은 단위가 아니며, 그 안에 여러 agent core Turn이 있다.
  `agent_completed`·`agent_yielded`는 걸린 시간(`elapsed_s`)을, `agent_failed`는 걸린
  시간과 오류의 `error_code`·`error`를, `agent_input_required`는 요청(`request`)을
  payload에 싣는다. 이 event들은 payload의 `task_id`에 **Agent run ID**를 싣는다 —
  `agent_lifecycle_events`가 `AgentStarted`에서 연 run id를 그대로 쓴다. 그 id가 무엇이고
  Activity가 어떻게 읽는지는 **Agent run ID** 항목에 있다.
  → [Agent_core.Event_bus](../../packages/agent_core/lib/event_bus.mli),
  [agent_lifecycle_events](../../packages/agent_core/lib/agent/agent_lifecycle_events.ml)

**Official Client Lane**
: Claude Code, Codex, Antigravity 같은 공식 클라이언트가 자기 프로세스에서
  provider 요청을 보내고, MASC는 새 turn과 결과를 조율·관찰하는 실행 경로.

**Clients (TUI 클라이언트 표)**
: `GET /api/v1/dashboard/clients` 한 읽기를 그리는 TUI 표. 한 워크스페이스에 붙은
  모두를 한 번에 보여준다 — directory agent, state-backed session, runtime fiber.
  행의 `cr_status`는 닫힌 `client_status` 넷(`Client_active`·`Client_busy`·
  `Client_listening`·`Client_inactive`)이고, `cr_keeper_name`은 Keeper에 묶인 행만
  이름을 갖는다(비-Keeper MCP 클라이언트는 `None` — 이 표가 보여주려는 행이다).
  - **ACTING FOR** 열: 어떤 클라이언트가 **제 이름으로** Keeper의 세션에 묶였을 때
    그 Keeper를 적는다. Keeper 자신의 세션은 Keeper 이름으로 접수되므로 그 행에서는
    이름을 되풀이하지 않는다(`client_acting_for`가 `keeper_name = name`이면 `None`).
    그런 행이 하나도 없으면 열 자체를 그리지 않는다(`clients_act_for_others`) — 빈 열이
    행 끝 시계를 잘라 먹기 때문이다. **그래서 열이 안 보이는 것은 결함이 아니라 정보이다
    — 남을 대신하는 클라이언트가 없다는 뜻이다.**
  → [Tui_decode.client_row](../../lib/tui_decode.mli),
  [Masc_tui_types.client_acting_for](../../bin/masc_tui_types.ml)

**MCP**
: Model Context Protocol의 약어. MASC는 양쪽으로 쓴다. 자기 도구와 협업 상태를
  MCP 서버로 내보내고(`masc_*` 도구), Agent는 `mcp_clients`로 바깥 MCP 서버에
  붙어 그쪽 도구를 가져온다.

**HITL**
: Human-in-the-Loop의 약어. Gate에 걸린 바깥 작업을 사람이 허락하거나 거절하는
  경로다. 사람의 답을 기다리는 동안에도 다른 Keeper의 턴이나 상관없는 작업은 계속 돈다.

**Approval Detail Pane (승인 상세 화면)**
: TUI에서 단일 HITL 승인 요청의 전체 질문과 인자를 펼쳐 확인하는 상세 화면
  (`Approval_detail`). 한 줄 요약(`single_line`)만으로 수십 줄의 코드 편집이나 명령을
  다 보지 못한 채 운영자가 승인하는 위험을 막기 위해, 작성된 줄바꿈을 유지하며 전체
  내용을 래핑하여 렌더링한다.
  - **제어 문자·보이지 않는 글자 이스케이프 경계**: 모델이 작성한 질문(`kta_question`)이나
    인자(`kta_args`)에 든 바이트가 터미널 커서를 옮기거나(ANSI 제어 문자 `ESC [ 1 A` 등)
    화면에는 보이지 않은 채 승인 해시에만 들어가면, 운영자가 읽은 글과 승인하는 바이트가
    달라진다(Loopjacking 완화). 그래서 모든 라벨은 `sanitize_terminal_text`, 모든 값은
    `sanitize_terminal_lines`를 거친다. 개행(`LF`)만 실제 줄바꿈으로 남기고, 나머지는
    지우거나 공백으로 숨기지 않고 눈에 보이는 이스케이프로 그린다. 제어 바이트(0x20 미만,
    DEL 0x7F, 0x80–0x9F)와 잘못된 UTF-8 바이트는 `\xNN`(ESC는 `\x1B`, 탭은 `\x09`),
    UTF-8로 쓴 C1 제어 문자(U+0080–U+009F)는 `\u00NN`으로 그린다. 보이지 않는 글자
    (Unicode `Default_Ignorable_Code_Point`: zero-width 문자, word joiner 계열, 한글 채움
    문자 U+115F·U+1160·U+3164·U+FFA0, soft hyphen, variation selector, tag 문자)는
    `\uXXXX`나 `\UXXXXXXXX`로 그린다(#38445·#38501·#38851). 예외는 셋이다 — 그림 문자 둘을
    잇는 ZWJ(🤷‍♂️), 텍스트가 기본인 이모지(U+2764 등) 바로 뒤의 VS15·VS16 하나, 검은
    깃발(U+1F3F4) 뒤에 tag 문자로 붙인 지역 깃발. 한자 뒤의 variation selector는 등록된
    이체자인지 이 경계가 가릴 수 없어 이스케이프한다. 행 타입이 비공개
    (`type line = private`)라 화면의 모든 행은 이 경계를 우회할 수 없다(#38478).
  → [Approval_detail](../../bin/masc_tui_approval_detail.mli),
  [Tui_decode](../../lib/tui_decode.mli)

**Surface**
: 같은 MASC 상태에 접근하고 관찰하는 사용자 표면. TUI, MCP, Dashboard처럼 서로 다른
  입구를 가리키며, 각 표면은 독립 상태를 소유하지 않는다.

**Goals 블록 (Overview Goals)**
: TUI Overview 최상단에서 fleet의 활성 작업이 목표를 실제로 진전시키고 있는지를
  보여주는 자리(`Masc_tui_overview_goals`). Attention 패널 뒤, Team 블록 앞에
  배치된다. 헤드라인은 전체 활성 태스크(진행 중이거나 검증 대기 중인 Task) 중 그려진
  목표에 연결된 태스크 수 비율을 표시하고, 아직 일이 진행 중인 단계(`Executing`·
  `Verifying`·`Awaiting_confirmation`)의 Goal마다 우선순위(낮은 숫자 우선) 및 마감일
  순으로 한 줄씩 그린다(#38386).
  - 각 행: 목표 제목, 연결 태스크 대비 완료 태스크 바(`done/linked task bar`), 정체
    시간(`stagnation_seconds` 기준 idle 기간), 운영자의 로컬 캘린더 날짜 기준 마감
    카운트다운(`D-N due countdown`).
  - 관측 권위: 목표가 자체 지표(`metric`·`target`)를 가지고 있어도 측정값이 보고되지
    않으면 지어내지 않고, 진행 바는 순수하게 연결된 태스크의 완료 수만 측정한다.
  - 빈 상태: 활성 목표가 없거나 읽기 실패 시 헤드라인이 그 상태를 명시적으로 표시하며,
    표시 예산(`rows`)을 초과하면 하단부터 생략하고 헤드라인에 그려진 목표 수를 남긴다.
  → [Masc_tui_overview_goals](../../bin/masc_tui_overview_goals.mli)

**Team 블록 (Overview Team)**
: TUI Overview 에서 Keeper 한 명당 한 줄로 "누가 무엇을 하고 누가 막혔나" 를 보여주는
  자리. briefing 의 `keeper_briefs` 와 backlog 를 합쳐 그린다. 줄은 네 무리로 나뉜다 —
  막힘(Failing·Crashed, 또는 phase 없이 info 가 아닌 Attention 이 가리키는 Keeper),
  일하는 중(Running·Draining·Restarting 이고 Claimed·InProgress Task 를 잡음), 쉬는 중,
  멈춤(brief 의 `paused` 가 true 이거나 Paused·Stopped·Offline, 한 줄로 모음). 순서는
  점수가 아니라 이 무리와 이름이다. 막힌 줄의 설명은 그 Keeper 를 `Attention_keeper` 로
  가리키는 info 가 아닌 첫 Attention 문장을 그대로 싣는다. Keeper 가 아닌
  담당자(MCP client 등)가 잡은 Task 는 "held outside the fleet" 한 줄로 센다.
  → [Masc_tui_overview_team](../../bin/masc_tui_overview_team.mli), RFC-0464

**Attention (Overview Attention 패널)**
: briefing 의 `incidents` 와 `attention_queue` 를 합친 목록. 운영자가 봐야 할 조건 하나가
  한 줄이다. 화면에 그려진 Team 줄이 문장으로 싣는 항목(막힌 Keeper 줄 하나에 항목 하나)은
  Team 줄에만 두고, 나머지는 모두 Attention 패널에 남긴다. 살아 있는 Keeper 에 관한 항목,
  같은 Keeper 의 둘째 항목, 화면이 짧아 잘린 Team 줄의 항목, parked 줄의 Keeper 항목이
  여기에 든다. 패널 제목은 Team 줄로 옮긴 수를 `+N on Team` 으로 적는다. Task 소유권
  문제만 모은 Operator Attention 과는 다른 목록이다.

**닫힌 quota 창 (Shut Quota Window)**
: provider 계정이나 자격 증명 하나가 사용 한도에 걸려 요청을 받지 않는 상태. 런타임
  카탈로그(`/api/v1/runtime/resolved`)는 런타임마다 `quota_exhausted`·`quota_resets_at`·
  `quota_scope` 를 싣는데, 같은 계정을 쓰는 런타임은 같은 `quota_scope`(예:
  `provider:claude_code`)를 공유한다. Team 블록은 창을 scope 마다 한 번만, 그 뒤에 선
  런타임 수와 다시 열리는 시각으로 적는다. 남은 사용량은 provider 가 알려주지 않으므로
  퍼센트로 말하지 않는다.
  → [Runtime_quota_window](../../lib/runtime/runtime_quota_window.ml),
  [Masc_tui_overview_team](../../bin/masc_tui_overview_team.mli)

**Server Push (서버가 밀어 보내는 사건)**
: 서버가 클라이언트로 밀어 보내는 사건으로, Keeper가 한 일이 아니라 서버가 보고하는
  상태 변화. Activity 화면은 이런 사건을 `everything` scope 아래 조용한 회색 행으로
  그리고 `turns`·`actions`에는 세지 않는다. whole-projection 스냅숏(`composite`),
  `internal_agent_runs_changed`, `Fusion_run_status`, heartbeat, waiting-queue 변화가 그
  예다. 어느 사건이 어느 slice로 가는지는 `Dashboard_event_slices`의 한 표가 정하고,
  서버 라우팅과 터미널 분류가 그 표를 함께 읽는다. Keeper가 한 일(`action`)과 반대편이다.
  → [Dashboard_event_slices](../../lib/dashboard_event_slices.mli),
  [Activity scope](../../bin/masc_tui_acting.ml), [TUI 안내](../TUI-GUIDE.md)

**Harness (하네스)**
: 이 저장소에서 서로 다른 넷을 가리킨다. 문장에 어느 것인지 함께 적는다.
  (1) TUI Harness 화면: 평가자 판정을 읽는 TUI 표면. 코드의 화면 이름은 `Harness`지만
  키 표가 운영자에게 보이는 이름은 "Planning / Task Verdicts"이고
  ([`masc_tui_keys.ml`](../../bin/masc_tui_keys.ml)의 판 이름 표), 상세에서 `y`(agree)·`x`(overrule)로 그 판정에 답한다
  (`render_harness_detail`). (2) Eval Harness: Keeper 에이전트의 시나리오 기반 행동
  평가(`lib/eval_harness.mli`). scenario·grader·metric 타입과 runner·summary 를
  정의하고 eval CLI 와 dashboard 가 소비한다. (3) Lab Safety Harness: Dashboard Lab
  표면의 안전 판독(`#lab?section=harness`,
  `lib/dashboard/dashboard_harness_health.ml`) — 평가자 보정 통계와 최근 runtime 안전
  신호를 한 화면에 모은다. (4) Harness First: "측정 없이 AI 에이전트 코드를 진행하지
  않는다"는 프로젝트 원칙. RFC 들이 이 이름으로 인용한다.
  → [masc_tui_keys](../../bin/masc_tui_keys.ml), [Eval_harness](../../lib/eval_harness.mli),
  [Dashboard_harness_health](../../lib/dashboard/dashboard_harness_health.ml)

**Exit Reason (세션 종료 사유)**
: TUI 세션이 왜 끝났는지 자기 stderr 로그(`.masc/logs/masc-tui-<pid>.log`)에 남기는 한 줄.
  `Masc_tui_exit_reason.t`가 닫힌 어휘를 소유한다 — `Quit_key`(q·Q·Ctrl-Q),
  `Interrupt`(첫 Ctrl-C가 아직 살아 있는 동안의 두 번째 Ctrl-C), `Terminate of string`
  (SIGTERM·SIGHUP·SIGQUIT), `Exception of string`(루프를 빠져나온 잡히지 않은 예외),
  `Unrecorded`(사유를 적지 않고 루프를 떠난 경우). 마지막 것이 `Exception`과 따로 있는
  까닭은 아무도 예외를 관측하지 않았기 때문이다 — 없던 실패를 지어내면 읽는 쪽이 그것을
  찾아 나선다.
  `is_normal`이 정상/비정상을 가른다: 정상은 운영자나 세션 주인이 의도해 끝낸 것
  (`Quit_key`·`Interrupt`·`Terminate`), 비정상은 요청 없이 표면이 떠난 것
  (`Exception`·`Unrecorded`)이다.
  줄은 `[masc-tui] exit: normal (quit key)` 꼴이다 — 접두까지 넣어 grep해야 이 줄만
  모인다. detail에 제어 바이트가 있으면 먼저 한 줄로 평탄화하고, 200바이트를 넘는 사유는
  UTF-8 문자 경계에서 자른 뒤 `[+N bytes]`로 버린 양을 적는다 — 로그를 한 줄씩 읽는
  데다, 백트레이스 하나가 한 줄을 킬로바이트로 만들면 이 줄의 목적이 사라지기 때문이다.
  세션이 끝난 사유는 이 줄에만 남는다. **Terminal Reason**과 다른 축이다 —
  Terminal Reason은 끝난 Keeper turn의 영수증 필드이고, Exit Reason은 TUI 프로세스
  세션이 끝난 까닭이다.
  → [Masc_tui_exit_reason](../../bin/masc_tui_exit_reason.mli), [TUI 안내](../TUI-GUIDE.md)

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

**Keeper Prompt (Keeper 시스템 프롬프트)**
: 한 Keeper turn의 모델 호출에 실리는 system prompt. `Keeper_prompt.build_keeper_system_prompt`가
  `config/prompts/keeper.md`의 슬롯을 정해진 순서로 조립한다. 순서는 공유 접두를 최대로
  남기기 위한 것이다(KV 캐시 재사용): `<system>` 공유 본문(keeper.md 첫 마커 앞, 모든
  Keeper가 글자 그대로 공유) → `keeper.worldview` → `keeper.constitution` →
  `keeper.identity` → `keeper.workspace` → `<role>`.
  `keeper.worldview`는 이 세계가 무엇을 잘한 일로 치는가다. 운영자가 덮어쓰며, 배포
  기본값은 "따로 정한 가치관이 없다 — 각 Keeper의 역할이 정한다"이다. 슬롯은 항상 렌더된다.
  `keeper.constitution`은 세계가 쓴 규범(RFC-0442)이다. 원장 파일이 아직 없는 세계(`Missing`)는
  조항 없이 통째로 빠진다. 반면 원장 파일이 실재하는데 읽을 수 없는 상태(`Unreadable`)는
  조항 없는 프롬프트로 턴을 돌리지 않고 `prepare_run_context` 단계에서 `prepare_error`
  (`Constitution_unreadable`)로 즉시 거절(`not-dispatched`)한다. 규범 없이 임의 실행되는
  것을 막고, 프롬프트 해시 변경으로 인한 벤더 세션 불필요 소모·재시작을 방지하기 위함이다(#38354·#38427).
  프롬프트 단일 권위(Single Authority): 직접(direct) 턴과 자율(autonomous) 턴 모두
  `Keeper_run_context.prepare_run_context`가 조립한 단일 `base_system_prompt`만 모델로 보낸다.
  `Keeper_unified_prompt.build_prompt`는 관찰 프레임과 사용자 메시지만 만들며(`turn_prompt_parts`),
  별도 시스템 프롬프트를 렌더하지 않는다(`turn_prompt`의 `system_prompt` 필드는 제거됨).
  대시보드 및 TUI 설정 표면에서는 `prompt.system_prompt`가 닫힌 세 상태
  (`available`·`unavailable: constitution_unreadable`·`decode_failed`)로 투영되어
  오류 사유와 파일 경로를 직접 드러낸다.
  `<role>`은 그 Keeper의 `instructions`(Keeper TOML)를 적힌 그대로 감싸며 앞에 제목을
  붙이지 않는다.
  `keeper.identity`·`keeper.workspace`는 각각 Keeper 이름과 샌드박스 루트를 받는다.
  전체 지도는 [Prompt Map](../PROMPT-MAP.md)을 따른다.
  Claude Code 레인은 이어 붙이기(resume) 때 세션을 처음 열 때 기록한 system prompt를
  대화를 압축할 때까지 그대로 다시 보낸다. 그래서 턴마다 바뀌는 내용(턴 컨텍스트와
  Librarian Working State)은 resume 사용자 프롬프트 앞에 붙여 보내고, 대화 기록은
  보내지 않는다. 그래서 resume 턴의 세션 기록 `context_frontier.delivery`는
  `held_by_vendor_session`이고, 세션을 처음 여는 턴은 `prepared_start_context`다.
  → [Keeper_official_client_host.resume_prompt](../../lib/keeper/keeper_official_client_host.mli)
  경계: 여기의 "role"은 Message의 role(`System`·`User`·`Assistant`·`Tool`)도, Board
  Interest 판정의 `keeper_role {name, board_interests}`도, Fusion 심판의 `judge_role`
  (Fusion Judge Role)도 아니다.
  → [Keeper_run_context.prepare_run_context](../../lib/keeper/keeper_run_context.mli),
  [Keeper_unified_prompt](../../lib/keeper/keeper_unified_prompt.mli),
  [Keeper_prompt](../../lib/keeper/keeper_prompt.mli)

**Ask (질문)**
: Keeper가 운영자에게 묻는 durable 질문 묶음. `masc_ask`가 만들고,
  `masc_ask_status`·`masc_ask_withdraw`가 조회·철회하며, 답변은 별도 wake로
  Keeper에게 돌아간다. 한 ask는 질문 여러 개를 담고, 각 질문은 선택지·자유 텍스트
  또는 둘 다를 받는다. 질문 id(`q1`, `q2`, ...)와 선택지 id(`c1`, `c2`, ...)는
  모델이 이름 짓지 않고 위치로 붙는다 — 한 ask 안에서만 유일하면 되고, 나중에
  어떤 도구도 그 id를 다시 받지 않는다(#38585). 답이 Keeper에게 도달할 때는
  각 id가 이미 헤더와 라벨로 되돌아가 있고, `masc_ask_status`는 id를 그 옆에
  함께 적는다. TUI의 자유 텍스트 편집은 같은 q1이 두 ask에 있을 수 있어 ask id로
  묶는다. **Board Interest**와 달리 사람의 답을 기다리는 일방향 요청이고,
  **Schedule**의 미래 실행 예약과도 다르다.
  → [mcp_tool_runtime_ask](../../lib/mcp_tool_runtime_ask.ml),
  [Keeper_ask](../../lib/keeper/keeper_ask.mli)

**Latched Reason (durable latch 까닭)**
: Keeper가 durable pause에 들어간 typed 까닭
  (`Keeper_latched_reason.t`). 현재는 `Operator_paused of { operator_actor }` 하나뿐이고,
  `operator_actor`는 `Grpc_directive`·`Keeper_down` 둘 중 하나다. 일반적인 turn·
  provider·task 실패는 관측으로만 남고 이 latch를 만들지 못한다 — 실패는 스케줄링
  게이트가 아니라 증거다. 폐기되거나 알 수 없는 latch 문자열은 명시적으로 거절한다.
  **Turn Configuration Error**처럼 registry가 기록하는 실행 실패 원인과는 다른
  층이다 — 이쪽은 typed lifecycle latch이고, 저쪽은 turn이 typed 구성 오류로
  끝난 실패 관측이다.
  → [Keeper_latched_reason](../../lib/keeper_runtime/keeper_latched_reason.mli)

**Board Interest**
: Keeper가 직접 지목되지 않은 Board post와 comment를
  의미 판정 대상으로 받을 수 있는 주제 선언. `board_interests = []`이면 이
  targetless discovery를 끈다. 정확한 Keeper 지목과 broadcast, 게시글 작성자 및 해당 댓글의 부모 댓글
  작성자에게 보내는 전달에는 영향을 주지 않으며 Task 할당이나 실행 권한도 아니다.
  `mention_targets`는 정확한 주소 토큰이고 `board_interests`는 의미 판정의 입력이므로
  서로 fallback하지 않는다. 판정 입력은 typed signal과
  `keeper_role {name, board_interests}`뿐이다. 과거 post/comment thread,
  instructions, runtime/task identity, mention 목록은 저장하거나 보내지 않는다.

**Board Attention Candidate (Board 판정 후보)**
: Board_attention lane이 판정할 게시물 하나. 어떤 모델 호출보다 먼저 durable하게
  저장되고, 생애가 `Pending → Judged → Consumed`다. exact-flow 실패가 확정되면 먼저
  격리(`Quarantine`, 상태값 `Quarantined`) 상태가 되고, 운영자 소유의 복구가 이전 도메인 상태를 잃지
  않고 `Requeue_requested`를 거쳐 `Requeued`로 올린다. 판정은 소유 lane이 그 후보
  판정을 durable하게 적용·소비할 때만 넘어가고, 전달 실패는 마지막 실패 증거를 남길
  뿐 후보를 소비하지 않는다. 대기 작업에는 벽시계 만료가 없다. **`Runtime` 항목과
  다른 뜻이다** — 코드가 `candidate`라는 한 단어를 두 곳에 쓴다. 여기서는 판정 대상
  게시물이고, 런타임 쪽(`Runtime_candidate_backpressure.candidate`)은 runtime 후보
  순서가 시도할 실행 후보다.
  → [Keeper_board_attention_candidate](../../lib/keeper/keeper_board_attention_candidate.mli)

**Board Attention Partition (Board 판정 구역)**
: Board-attention 판정을 실행하고 추적하기 위한 durable 상태 머신 단위
  (`Keeper_board_attention_partition`). 아직 할당되지 않은 비종단 Candidate마다 하나의
  singleton 루트를 받는다. MASC가 Candidate 소유권과 이 상태 머신을 통제하고,
  AGENT_CORE는 승인·디스패치·전진을 맡는다. 런타임 전이는 cursor-fenced 행을 추가하며
  허용된 전이마다 `generation`이 정확히 한 번 증가한다.
  - 상태는 `Ready`·`Running`·`Completed`·`Settled`·`Abandoned`·`Blocked`다.
  - `Completed`: 판정 결과(`item : completed_item`)를 확보한 상태.
  - `Settled`: **판정이 원장에 기록된 끝 상태**. `Settled`를 떠나는 전이는 없다.
    판정 기록 없이는 이 상태에 올 수 없다.
  - `Abandoned`: **판정 없이 끝난 상태**. `settle`로는 오지 않는다. 원장에서 사라진
    후보를 가진 `Blocked` 루트를 `reconcile_quarantines`가 포기할 때 이 상태가 된다.
    일치하는 후보가 아직 `Resumable_pending`이면 `ensure_roots`가 같은 결정론적 식별자의
    다음 `generation`으로 `Ready`를 다시 연다. 후보가 `Resumable_judged`나
    `Requeued_resumable`이면 `ensure_roots`는 이 루트를 건드리지 않는다.
  - 경계: 이 상태 머신은 Candidate 생애주기(`Pending → Judged → Consumed`,
    `Quarantined`)와 다른 층위다.
  → [Keeper_board_attention_partition](../../lib/keeper/keeper_board_attention_partition.mli)

**Board Attention Quarantine (Board 판정 격리)**
: Board attention 판정 워커가 정상적으로 완료할 수 없는 후보(`candidate`)와 파티션을
  격리 보관하는 상태 및 그 인벤토리. 워커는 격리된 항목을 스스로 재시도하지 않으며,
  오직 운영자의 재투입(`requeue`) 요청으로만 풀려난다(#38260·#38262).
  - 격리 원인 카테고리(`quarantine_failure_category`): 닫힌 12개 값이다.
    `Candidate_membership_conflict`·`Durable_partition_invariant`·`Exact_setup_unavailable`·`Exact_flow_replayed`·`Exact_lane_exhausted`(모든
    HTTP 슬롯 및 CLI tail 거부로 모델 슬롯 소진)·`Exact_flow_bookkeeping_failed`(장부
    기록 실패)·`Exact_completion_failed`(완료 단계 실패)·`Domain_output_invalid`·`Execution_provenance_mismatch`·`Unexpected_worker_failure`·`Exact_execution_quarantined`(호출
    단계 미기록)·`Exact_execution_interrupted`(프로세스 재시작으로 바인딩된 실행이
    끊김. 읽기 전용 모델 호출이라 토큰 외 부작용 없이 재투입 가능).
  - TUI 표시 및 복구:
    - Keeper Info 탭에 원인 카테고리별로 집계(건수, 최장 경과 시간, 파티션 ID, 재투입
      대기 수)되어 표시된다. 수백 건의 슬롯 소진 행이 화면을 덮지 않도록 카테고리당 한 줄로 묶는다.
    - `Q` 키를 누르면 가장 오래 대기 중인 항목(`oldest_waiting`)부터 원장의
      `Requeue_requested`로 전이시키며 재투입을 요청한다.
    - 재투입 요청은 읽을 때의 `quarantine_id`로 펜싱되어, 같은 파티션의 더 새로운 격리 상태를
      낡은 식별자로 덮어쓰지 않는다.
    - 서버가 새로 추가한 알 수 없는 카테고리는 떨어뜨리지 않고 `Unreadable_row`로 보존·계수하여
      격리 수가 화면에서 축소 왜곡되지 않게 한다.
  → [Keeper_board_attention_candidate](../../lib/keeper/keeper_board_attention_candidate.mli) · [Keeper_board_attention_quarantine_command](../../lib/keeper/keeper_board_attention_quarantine_command.mli) · [Masc_tui_board_quarantine](../../bin/masc_tui_board_quarantine.mli)

**Keeper Cycle**
: 현재 상태와 event를 관찰하고 Keeper turn 실행 여부를 결정하는 서버 loop의
  한 회차. 모든 cycle이 모델 호출을 실행하지는 않는다.

**Turn**
: "turn"만 쓰면 아래 넷 가운데 무엇인지 알 수 없다. 앞의 셋은 단위나 기록이고, 마지막
  하나는 실패 원인이다. 문맥 없이 쓰지 않는다.
  - **Keeper Turn** — MASC가 하나의 Keeper 작업을 시도하는 단위. (아래 항목)
  - **agent core Turn** — 하나의 agent core Agent run 내부의 한 단계. Keeper turn과
    동일한 단위가 아니다. (아래 항목)
  - **Turn Boundary** — 끝난 Keeper turn이 `turn-boundaries.jsonl`에 남기는 한 줄.
    History 안에는 turn의 경계가 없다. (아래 항목)
  - **Turn Configuration Error** — Keeper turn이 typed Agent Core 구성 오류로 끝난
    latch된 실패 원인. (아래 항목)

**Keeper Turn**
: MASC가 하나의 Keeper 작업을 시도하는 단위. 선택한 runtime에 따라 AGENT_CORE
  Agent run 또는 공식 클라이언트의 모델·도구 실행을 사용한다
  ([`Runtime_execution.t`](../../lib/runtime/runtime_execution.mli)). MASC는 해당 레인의 결과를
  조율·기록한다.

**Keeper Fleet Blocker (Keeper fleet 차단 사유)**
: Keeper fleet가 설정된 만큼 돌지 못하는 첫 번째 까닭. fleet scan이 `blocker`로 보고한다.
  `Keeper_fleet_blocker.t`가 닫힌 일곱 이름을 소유한다 — `Keeper_bootstrap_disabled`(Keeper
  boot가 꺼져 아무 Keeper도 turn을 못 잡음), `No_executable_keeper_fibers`(turn을 돌릴
  Keeper fiber가 없음), `Turn_configuration_error`(Keeper의 turn 설정이 무효라 재시도해도
  안 바뀜), `Official_client_recovery_required`(공식 클라이언트 Keeper 세션이 명시적 복구를
  기다림), `Reaction_capacity_below_target`(fleet가 설정된 수보다 적은 Keeper가 반응함),
  `Active_task_owner_without_executable_fiber`(활성 task를 쥔 Keeper에 그 task를 돌릴 fiber가
  없음), `Durable_paused_autoboot_enabled`(스스로 boot하도록 둔 Keeper가 durable pause에
  걸림). scan은 이 타입의 순서대로 검사해 처음 성립하는 하나만 이름 붙인다 — 여럿이 동시에
  성립해도 하나만 말한다. 서버가 wire 이름을 쓰고 터미널 클라이언트가 `of_wire_name`으로
  되읽으므로 양쪽이 제 사본을 두지 않는다. 이 build가 모르는 이름은 `None`이고, TUI 헤더는
  그 이름을 서버가 쓴 그대로 그린다(`Masc_tui_fleet_line.blocker_text`) — 더 새 서버의 사유도
  사유다. 아는 이름은 아래 counts 줄이 같은 Keeper 무리에 쓰는 말로 그린다(예: "autoboot
  keepers paused"). 이 줄은 까닭만 말하고 수는 아래 줄이 나른다.
  → [Keeper_fleet_blocker](../../lib/keeper/keeper_fleet_blocker.mli),
  [Masc_tui_fleet_line](../../bin/masc_tui_fleet_line.mli)

**Terminal Reason**
: 끝난 Keeper turn의 이유를 담은 영수증 필드(`terminal_reason_code`).
  `Keeper_terminal_reason.of_wire`가 이 wire 문자열을 닫힌 합타입으로 한 번 파싱하고,
  `to_wire (of_wire s) = s`가 바이트 단위로 성립한다. 분류는 canonical producer
  바이트만 받고, 나머지는 `Unknown` escape로 간다.
  → [Keeper_terminal_reason](../../lib/keeper_runtime/keeper_terminal_reason.mli)

**Operator Disposition**
: 끝난 turn을 운영자 관점에서 분류한 (kind, reason) 쌍. `Keeper_execution_receipt.operator_disposition`이
  영수증 필드에서 파생한다. kind는 아홉이고 `keeper_execution_receipt.mli`의 `operator_disposition_kind`가
  전부다 — `Disp_pass`·`Disp_fail_open_next_runtime`·`Disp_retry_later`·`Disp_pass_next_model`·
  `Disp_operator_action_required`·`Disp_effect_review_required`·`Disp_user_cancelled`·`Disp_skipped`·
  `Disp_unknown`. reason도 닫힌 집합이다. `Disp_effect_review_required`는 원인은 알지만 턴이 밖에
  남긴 효과가 있었는지 모르는 경우다. Keeper는 다음 턴을 돌고, 사람이 그 효과를 확인한다.
  `Disp_unknown`은 분류기가 이 turn을 분류하지 못했다는 뜻이고, `ReceiptUnmappedDisposition`을 올리는
  마지막 갈래만 이 값을 낸다. `Disp_operator_action_required`는 운영자만 고칠 수 있는 알려진 원인을
  가리키며 런타임 연속·폴백을 주장하지 않는다. 설정 거부와 권한 거절은 reason으로 갈린다 — `Reason_config_invalid`는
  런타임이 provider dispatch 전에 설정값을 거부한 경우(`Keeper_terminal_reason.Config_invalid`)로
  운영자가 runtime toml을 고치고, `Reason_authorization_refused`는 provider가 권한 사유로 요청을
  거절한 경우(`Keeper_terminal_reason.Authorization_refused`)로 wire에 주간·5시간 사용량 한도가 실려
  운영자가 슬롯을 옮긴다.
  → [Keeper_execution_receipt](../../lib/keeper/keeper_execution_receipt.mli),
  [Keeper_terminal_reason](../../lib/keeper_runtime/keeper_terminal_reason.mli)

**Stop Reason (제공자 발화 중단 사유)**
: 모델 제공자(LLM Provider)가 wire 스트림(`KEEPER_STREAM_MESSAGE_DELTA`)에 통보한 발화 중단 사유.
  MASC가 턴 전체를 어떻게 처리했는지를 분류하는 **Keeper Turn Outcome**(가시적 응답·체크포인트·게이트 대기 등)이나
  영수증 필드인 **Terminal Reason**과 다른 층위의 개념이다(#37723·#38508).
  - **Outcome과의 비일치**: 제공자의 12개 중단 사유 중 6개(`max_tokens`, `refusal`, `content_filter`,
    `repetition_truncation`, `model_context_window_exceeded`, `unmatched_tool_calls`)는 대응하는 Turn Outcome이 없다.
    예컨대 `max_tokens`로 출력이 잘려나간 응답도 MASC 관점에서는 정상적인 가시적 응답 턴(`Reply`)이므로,
    Turn Outcome만으로는 제공자가 토큰 한도에 부딪혀 답변을 다 쓰지 못했는지 알 수 없다.
  - **표면 투영**: TUI 채팅 헤더는 실시간 스트리밍 중 제공자가 작성을 멈춘 이유를 `stopped: <reason>`(예: `stopped: max_tokens`)으로
    명시해 완성된 응답으로 오인되는 것을 방지하며, 행 폭이 좁으면 줄임표 대신 통째로 생략한다. 대시보드는 세션 트레이스 엔트리의
    `종료:` 필드에 이를 그린다. wire 이벤트 하나가 토큰 사용량(`usage`)과 중단 사유(`stop_reason`)를 함께 나른다(`Stream_details`).
  → [Keeper_chat_events](../../lib/keeper/keeper_chat_events.mli), [TUI Guide](../TUI-GUIDE.md)

**Keeper Chat Operation**
: Keeper 대화에 접수한 메시지 실행의 durable 기록. `operation_id`로 식별하며
  `state`가 대기·실행·성공·실패·취소를 구분한다. Board 맥락 추론이나 다른 Keeper(`masc_keeper_msg`·
  `masc_keeper_delegate`)도 이 operation을 제출하고, 응답의 `keeper_name`은 제출 경로가 해석한 실제 대상
  Keeper다. 소스 스키마는 `masc.keeper_chat_operation.source.v2`이며 `sender_keeper` 키를
  반드시 싣는다. 값은 다른 Keeper가 보낸 경우 그 Keeper 식별자이고, 운영자·커넥터 화자면 `null`이다
  (RFC-0468 §3.2). 접수 응답은 실행 완료를 뜻하지 않는다.
  → [Keeper_chat_operation_payload](../../lib/keeper/keeper_chat_operation_payload.mli)

**Speaker Authority (화자 권한)**
: Keeper 대화 turn을 연 발화자(human 또는 agent)의 권한 분류. 메시지 내용(content)에서
  추측하지 않고 진입 경로와 Keeper 레지스트리 대조로 구조적으로 결정한다(RFC-0223 §3,
  RFC-0468 §3.2). 닫힌 세 변형이다 — `Owner` (인증된 대시보드/운영자 경로), `External`
  (Discord·Slack 등 커넥터 문맥을 나르는 외부 화자), `Keeper` (제출 지점이 Keeper
  레지스트리와 일치시킨 등록된 다른 Keeper). wire 값은 각각 `"owner"`·`"external"`·
  `"keeper"`다. `Keeper`인 경우 `speaker_id`와 `speaker_name`에 해당 Keeper 식별자가 실린다
  (Keeper는 정확히 하나의 이름을 갖는다, RFC-0393).
  Librarian의 대화 상대방 관측(`Keeper_counterpart_observation`)에서도 같은 닫힌 세
  변형(`Owner`·`External`·`Keeper`)으로 전달되어, 호스트 참조가 부족해도 운영자,
  등록된 Keeper, 외부 화자를 안전하게 분리한다.
  → [Keeper_chat_store](../../lib/keeper/keeper_chat_store.mli),
  [Keeper_counterpart_observation](../../lib/keeper/keeper_counterpart_observation.mli)

**Turn Row Source (턴 행 출처)**
: 채팅 transcript가 한 turn의 행을 그리는 출처. 코드의 타입 이름이 아니라 이 문서와
  [pane 해부도](../diagrams/tui-chat-pane-anatomy.html)가 쓰는 라벨이다. 한 turn의 행은
  한 번에 한 출처에서만 나온다. 넷이다 — `live`(이 pane이 연 요청의 SSE stream),
  `observed`(이 pane이 열지 않았거나, 열었다가 stream을 잃은 turn: operation journal을
  읽어 따라간다), `settled`(stream이나 journal이 끝을 전한 held log), `committed only`(그
  turn을 대신하는 log가 없어 transcript page의 행을 그대로 그린다 — log 없음 · reply 없이
  끝난 취소 turn · 끝날 수 없게 된 Working log). log가 그 turn을 대신하면
  (`turn_log_holds_the_turn`: log가 committed이고 stream이 실패를 전했거나 기록된 reply와
  함께 끝났을 때) 그 log가 스스로 그리는 committed 행은 timeline에서 빠지고
  (`rows_the_logs_do_not_draw`), 끝날 수 없게 된 Working log(journal을 못 읽거나
  reply·failure가 기록됨)는 observed 집합에서 빠져 committed 행이 그 turn을 대신한다.
  `live`는 `log_projection ~committed:false`, `observed`는 `held_projection
  ~committed:false`, `settled`는 `held_projection ~committed:true`로 그린다.
  → [Masc_tui_types](../../bin/masc_tui_types.ml),
  [Masc_tui_render_chat](../../bin/masc_tui_render_chat.ml)

**Fold (접기)**
: TUI가 넘치는 내용을 줄여 그리는 두 가지 방식. 코드의 타입 이름이 아니라 이 문서와
  [TUI 안내](../TUI-GUIDE.md)가 쓰는 라벨이다. (A) **블록 접기** — 한 블록을 한 줄로
  접어 감추는 표시 상태. 추론 블록은 `Ctrl-R`로 숨김·접힘·전체를 돈다. 접힌 도구 행은
  결과 수를 그대로 지니고(`Tools 4 · read_file 2 · … · 4 details folded`), 펼친 도구
  fold도 operational kind(`Skill`·`Keeper`·`Fusion`)를 지닌다. (B) **셀 글자 접기** —
  셀 글자가 열 폭보다 넓을 때 어느 쪽이 양보하는지(`Table.fold`). `Fold_middle`은 양끝을
  남긴다 — 식별자를 머리에서 자르면 다른 식별자로 읽히고, 수를 어느 끝에서 자르면 틀린
  수가 되기 때문이다. `Fold_tail`은 머리를 남긴다 — 문장을 읽는 방식이다. 기본값은
  `Fold_middle`이고, 문장을 담은 열은 `Fold_tail`을 쓴다.
  → [Masc_tui_table](../../bin/masc_tui_table.ml),
  [Masc_tui_message_layout](../../bin/masc_tui_message_layout.ml)

**Checkpoint Load**
: 저장된 Keeper 이력을 읽는 단계. 파일 없음은 새 이력을 뜻하지만 읽기·파싱 오류는
  새 이력을 허용하지 않는다. 명시적인 checkpoint 버전 교체만 기존 파일을 남겨 두고
  새 이력을 시작하며, 첫 저장이 받아들여진 뒤 재시작을 기록한다. 이전 버전 체크포인트는
  턴 실행 시 저장된 이력 없음(`Saved_history_superseded`)으로 읽히며, 초기화 도구
  (`masc_keeper_clear`)에서도 읽기 오류로 거절하지 않고 부재한 것으로 취급해 공식
  클라이언트 세션과 함께 정상 비운다(#38223).
  → [Keeper_checkpoint_store](../../lib/keeper/keeper_checkpoint_store.mli),
  [Keeper_tool_surface](../../lib/keeper/keeper_tool_surface.ml)

**Prepare Error (준비 오류)**
: Keeper turn이 모델에 파견(dispatch)되기 전, 실행 컨텍스트를 구성하는 단계(`Keeper_run_context.prepare_run_context`)에서
  발생하는 닫힌 둘의 실패 사유(`type prepare_error = Checkpoint_unread of checkpoint_load_error | Constitution_unreadable of read_error`).
  `Checkpoint_unread`는 기존 이력 체크포인트를 불러오지 못한 경우이고, `Constitution_unreadable`은 세계의 헌법 원장
  파일이 실재하지만 권한·I/O 오류 등으로 읽지 못한 경우다.
  준비 오류가 발생하면 턴은 모델을 호출하지 않고 `not-dispatched` 실패 경로로 즉시 거절된다. 이 거절은 영수증(receipt)을
  남기지 않고 트랜스크립트에도 기록되지 않으므로, 다음 턴이 헌법 원장이나 체크포인트를 다시 읽어 정상 회복을 시도한다(#38354·#38427).
  → [Keeper_run_context.prepare_error](../../lib/keeper/keeper_run_context.mli)

**agent core Turn**
: 하나의 agent core Agent run 내부에서 provider response와 tool 실행이 진행되는 한
  단계. Keeper turn과 동일한 단위가 아니다.

**Agent run ID (Agent run 식별자)**
: observer event의 `task` 필드가 그 run 자신의 wire id(`evt-` 접두,
  `Event_envelope.fresh_id`)를 나르는 값 — `task` 필드가 run의 wire id를 나르는 event가
  그렇다(`agent_started`·…). MASC task id가 아니다. 같은 필드가 다른 event에서는 MASC
  task id를 나르므로, Activity는 run의 wire id를 나르는 event에서만 필드 이름을
  "Agent run ID"로 적고 그 밖에서는 "Task ID"로 적는다. 한 필드가 두 개념을 나르는
  자리라, run의 wire id를 task로 읽으면 `evt-…`가 행의 detail로 그대로 찍힌다.
  → [Observer event](../../bin/masc_tui_observer.mli), [Activity 라벨](../../bin/masc_tui_acting.ml)

**Runtime Attempt**
: Keeper turn에서 하나의 resolved runtime 후보를 실행하는 시도. 코드는 같은 것을
  provider attempt라고도 부른다(`Keeper_provider_attempt_effect`, `provider_attempt_outcomes`).

**Failure Route (실패 경로)**
: Keeper turn이 실패했을 때 그 실패를 타입으로 분류한 관측(`Keeper_runtime_failure_route.route`).
  모든 turn 실패 오류가 정확히 하나의 route로 매핑되고, `None` 갈래도 catch-all도 없다.
  세 갈래다 — `Retry_after_observed`(provider/infra 실패를 관측; provider의 `retry_after`
  힌트를 보존하되 지연을 지어내거나 강제하지 않음)·`Rotate_now`(다른 runtime이 즉시
  성공할 수 있음)·`Exhausted_visible_alive`(기계적 재시도·회전이 결과를 못 바꾸는 결정적
  실패; Keeper는 계속 살아 있고 두 번째 LLM 호출을 파견하지 않음). telemetry 라벨은
  `route_kind_label`(`retry_after_observed`·`rotate_now`·`exhausted_visible_alive`)과
  `route_class_label`(retry/rotate/terminal class)이다. 영수증·blocker에는
  `exhausted_visible_alive:deterministic_request`처럼 kind와 class를 붙여 적고, metric은
  `route`·`class` 라벨로 나눠 적는다. 이 route는 관측이지 스케줄링 권위가 아니다 — Keeper를
  멈추거나 다시 깨울 시각을 정하지 않는다. 같은 실패를 두 곳이 다르게 읽어서는 안 된다:
  route(영수증에 적히는 답)와 walk(`Runtime_attempt_fsm.should_try_next`가 실제로 다음
  후보로 넘어가는지)가 같은 답을 해야 한다(#38045). `retry_after` 힌트도 한 규칙으로 읽는다 —
  `usable_retry_after`가 없거나 0·음수·무한·NaN인 힌트는 "대기 시간을 말하지 않음"으로 답하고,
  후보 backpressure·경로 휴식·quota 재개·드라이버가 모두 이 한 규칙에서 답한다(#38065).
  `Retry_after_observed`의 retry class 중 공급자 자체 과부하(HTTP 529, CapacityExhausted 풀)는
  MASC 자체의 슬롯 대기가 아니라 시도한 런타임 후보의 실패(Server_error와 같은 층위)로 분류되며,
  클래스 라벨은 `provider_capacity`다(#38290). 이 실패는 다음 런타임 후보로 walk하며 503 과 같이
  다음 후보로 넘기고 이 후보를 뒤로 미룬다.
  `ECONNRESET`은 요청을 보낸 뒤(`sent`) 발생한 연결 단절로, 연결 수립 전 거부(`connection_refused`)와
  구분되는 `connection_reset`으로 기록된다(#38518). 재시도 가능 여부·Librarian 크기 판정 제외 등
  처리 정책은 `connection_refused`와 같으나 wire 및 운영자 요약 라벨이 분리된다.
  `Exact-output route`·`Fusion Route`
  (실행 경로 이름)와 이름이 겹치지만 다른 축이다.
  → [keeper_runtime_failure_route](../../lib/keeper_runtime/keeper_runtime_failure_route.mli)

**Candidate Fault (후보 사정 판정)**
: 한 후보(provider·모델·자격 증명·계정을 묶은 바인딩)가 실패했을 때, 그 실패가 이 후보의
  사정인지 답하는 닫힌 판정(`Candidate_fault.t`). exact 걸음(Librarian·`verifier_exact`·HITL
  판정·Board attention)과 Keeper 걸음이 같은 오류에 같은 답을 하도록 둘 다 이 판정 하나를
  읽는다(#38913). 값은 셋이다.
  - `Binding of binding_fact`: 이 바인딩의 사정이라, 다음 후보가 같은 입력을 받아도 된다.
    사정은 열둘이다 — `Credential`(401·403), `Account`(402), `Model_absent`(404), `Rate_limit`(429), `Capacity`(529),
    `Server`(5xx), `Window`(창 초과, 또는 창에서 멈춘 빈 답), `Body_limit`(413),
    `Admission`(보내기 전에 이 바인딩이 준비된 요청을 받지 않음: 선언된 입력 용량 초과,
    입력을 잴 수 없음, 준비된 요청 거절), `Deadline`(보낸 뒤 헤더·전체 기한 초과),
    `Output_dialect`(답이 content 밖 필드에 옴), `Refusal_unread`(거절 상태는 왔지만 거절
    본문이 기한 안에 오지 않음).
  - `Unattributed`: 거절은 왔지만, 누구의 사정인지 응답이 기계가 읽는 꼴로 말하지 않는다.
    기록에도 모른다고 남긴다.
  - `Unknown_after_dispatch`: 결과를 모르거나 이 바인딩의 사정으로 가를 수 없다. 이름과 달리
    보냈는지 모르는 전송 오류(`NetworkError`, #38931)와 보내기 전 배선 실패(`Not_dispatched`
    타임아웃·`AcceptRejected`·`ProviderTerminal`·`ProviderFailure`)도 이 값이다. 다시 보내도
    되는지는 이 판정이 아니라 걸음의 효과 규칙이 정한다.
  판정은 누구의 사정인지만 답하고, 다음 후보로 넘길지는 걸음이 정한다 — exact 걸음은
  Exact-output route의 슬롯 전진 조건이, Keeper 걸음은 `lane_should_retry`의 predicate가
  정한다. 공식 클라이언트가 만드는 provider 오류(`Llm_provider.Error.provider_error`)는 이
  판정 밖이다(#38776). 영수증에 적히는 Failure Route는 이 판정을 읽지 않고 따로 분류한다 —
  #38913은 `InputCapacity`·`Json_parse_error`를 route의 `admission` 회전으로 옮겨 걸음과
  답을 맞췄다. `Window`는 이 바인딩의 context window이고, Provider Usage Window(사용량 한도
  창)와 다른 창이다. 한국어 이름의 "사정"은 탓이 아니다 — 429·529는 누구의 잘못도 아니고
  그 후보의 형편이다.
  → [Candidate_fault](../../packages/agent_core/lib/llm_provider/candidate_fault.mli) ·
  [RFC-one-slot-fault-judgment-for-every-walk](../rfc/RFC-one-slot-fault-judgment-for-every-walk.md)

**Demotion (강등)**
: 어떤 항목을 제거하지 않고 우선순위·가시성·전송 여부만 낮추는 처분. 세 곳이 같은
  불변식을 지킨다 — 강등된 것은 사라지지 않는다.
  - 도구 결과 강등: 전송 사본에서만 blob 마커로 바뀌고 History 원본은 남는다
    (`Keeper_model_input_demotion`, RFC-0363).
  - 후보 강등: 쉬는 중이거나 실패한 runtime 후보를 세 무리(`Not_demoted` ·
    `Failed_without_rest` · `Told_to_rest`)로 나눠 뒤로 보낸다. 배제가 아니라 순서다 —
    쉬라는 말을 들은 후보는 뒤로 가므로, 앞에 쉬지 않는 후보가 있으면 그 후보부터
    보낸다. 강등한 뒤에도 맨 앞 후보가 쉬는 중이면 그 walk는 기다린다 — 맨 앞 후보가
    풀리는 때와, 뒤 후보 가운데 풀리는 순간 앞으로 올라오는 후보가 더 일찍 풀리는 때
    중 빠른 쪽까지다(`walk_rest`). 실패만 한 후보는 기다리게 하지 않는다
    (`Keeper_turn_driver.demote_unavailable_candidates`, RFC-0458 §3.4).
    실패 증거를 적은 Keeper(recorder)는 다음 사이클에 자기가 표시한 후보를
    강등하지 않고 선언 자리에서 다시 부른다(RFC-0458 §3.4 rule 5, #38327).
  - 차단 강등: 낡은 blocker를 "이전 차단"으로 낮춰 보여준다. 감추지 않는다
    (`agent-roster.ts`).
  → [Keeper_turn_driver.demote_unavailable_candidates](../../lib/keeper/keeper_turn_driver.ml)

**Official-client Session Recovery**
: 공식 클라이언트 세션에 기록된 `Input_rejected` 때문에 같은 runtime의 새 실행
  요청을 거절하는 상태. `bootstrap_floor_exceeded`는 줄일 수 있는 이력을 제거한
  입력도 용량을 넘은 경우이고, `effect_fenced`는 앞선 응답이나 도구 실행이 관측되어
  입력을 줄여 재실행할 수 없는 경우다. 현재 거절은 provider 호출 전에 일어나며, 앞선
  시도가 남긴 효과와는 별개다. 상태 표시는 원인·runtime ID·recovery ID를
  기존 session에서 전달하며, 복구 승인이나 fence 해제를 수행하지 않는다.
  Fleet는 일시정지되지 않은 `Failing` Keeper의 이 원인을 `recovering`과 구분해
  `official_client_recovery_required_keeper_count/names`로 표시한다. 이는 운영자
  조치가 필요한 fleet health 저하 사유이며, 다른 차단 사유가 없으면 `degraded`로
  표시한다. 실행 fiber의 생존·실행 가능 여부를 바꾸거나 세션 복구를 승인하지 않는다.
  경계: `vendor_session_full_no_activity`·`vendor_session_full_after_activity`는 이
  상태가 아니다. Gate 이어가기가 원래 세션을 resume 했는데 세션이 가득 찼다고 거절된
  기록이고, 뒤쪽은 거절 전에 응답이나 도구 실행이 관측된 경우다. 그 Gate는 다른
  세션에서 이어갈 수 없어서 operation이 `Gate_session_full` 원인으로 실패하고, 다음
  일반 턴은 이 기록을 넘기고 새 세션을 연다. `Retry_previous`는 같은 세션에 다시
  보내게 되므로 쓸 수 없다. Codex는 도구 실행 뒤 넘친 경우에만 이 기록을 쓴다.
  도구 실행 전이면 같은 thread에서 줄여 다시 보내는 재시도가 아직 가능하다.
  → [Keeper_direct_gate_continuation.session_full](../../lib/keeper/keeper_direct_gate_continuation.mli)

**Turn Configuration Error (턴 구성 오류)**
: Keeper turn이 typed Agent Core 구성 오류로 끝나 latch된 실패 원인
  (`Keeper_registry.Turn_configuration_error { code; field; detail }`). 현재 프로세스는
  운영자가 설정이나 환경을 바꾸지 않고는 이 실패를 고칠 수 없다. `code`는 닫힌
  타입이 아니라 문자열이고, 그 값을 만드는 생산 지점은
  `keeper_unified_turn_types.ml`이다. `field`는 관련 설정 키다. Fleet는 일시정지되지
  않은 `Failing` Keeper의 이 원인을 `turn_configuration_error_keeper_count/names`로
  표시하고, 다른 차단 사유가 없으면 `degraded`로 표시하며 `operator_action_required`를
  참으로 만든다. autoboot 대상만 세는 `configuration_blocked_*`와 달리 이 값은 autoboot
  집합 밖의 수동 Keeper도 포함한다. `recovering`·`official_client_recovery_required`와
  함께 `Failing` 수를 정확히 분할한다.
  → [Keeper_registry.failure_reason](../../lib/keeper/keeper_registry_types_failure.mli),
  [blocker](../../lib/keeper/keeper_status_bridge_blocker.ml)

**Usage Scope**
: Runtime이 보고한 토큰 수의 집계 범위(`Runtime_usage_scope`). `per_request`는
  요청별, `turn_total`은 공식 클라이언트 턴 안의 여러 provider 요청 합계,
  `conversation_cumulative`는 대화 누적, `unavailable`은 범위 미상이다.
  합계·누적·범위 미상인 값으로 단일 요청의 컨텍스트 점유율이나 비용을 계산하지
  않는다. 클라이언트 턴 합계도 runtime 후보 순서를 포함한 Keeper turn 전체 합계는 아니다.

**Provider Usage Window (제공자 사용량 창)**
: Claude Code(`rate_limit_event`의 `unifiedWindows`)나 Codex app-server
  (`account/rateLimits/updated`)가 턴 도중 wire로 통보한 제공자 자체의 사용량 한도 창
  (`Runtime_provider_usage_window.t`). (quota scope, limit, window)별 최신 관측값과
  수신 시각을 기록하며, `GET /api/v1/runtime/resolved`에 읽기 전용으로 노출된다(#38380).
  - **관측 권위**: 이것은 순수한 관측(observation)이다. codex-cli 규약에 따라 클라이언트는
    소진율(utilization)이나 리셋 시각(`resets_at`)으로 복구 시점을 추론해서는 안 되므로,
    MASC의 라우팅·후보 순서(candidate ordering)·승인(admission)·재시도(retry) 판단은 이 숫자를
    일절 읽지 않는다. 제공자가 알려준 사실 그대로를 기록하고 보여줄 뿐이다.
  - **비영속·프로세스 로컬**: 프로세스 메모리에만 존재하며 저장소에 남지 않는다. 프로세스
    기동 후 통보가 한 번도 없었던 scope는 0이나 빈 창으로 꾸며내지 않고
    `Not_reported_since_start`로 명시한다.
  - **TTL 부재**: `resets_at` 시각이 지나도 자동으로 삭제되거나 만료되지 않으며, 더 새로운
    보고가 올 때까지 마지막 수신 기록을 유지한다.
  - **Usage Scope와의 구분**: 위의 Usage Scope(MASC가 집계하는 토큰 수의 범위)와 다른 축이다 —
    이쪽은 모델 제공자가 wire로 알려준 자기 계정의 5시간·7일 한도 창이다.
  → [Runtime_provider_usage_window](../../lib/runtime/runtime_provider_usage_window.mli)

**Caller Scope**
: 이벤트를 발행하는 코드가 bus handle에 실어 봉투에 붙는 불투명한 값
  (`Caller_scope.t`, `Event_envelope.caller_scope`). Agent Core는 그대로 나르기만 하고
  내용을 읽지 않으며, 빈 값은 scope가 아니고 거부된다. 무엇을 뜻하는지는 handle을 만든
  쪽만 정한다. Keeper는 이 scope에 자기 Keeper turn id를 실어, 한 turn이 낸 여러 provider
  호출의 event를 그 turn에 귀속시킨다(`Keeper_turn_scope`). 위의 Usage Scope(토큰 집계
  범위)와 이름이 겹치지만 다른 축이다.
  → [Caller_scope](../../packages/agent_core/lib/caller_scope.mli),
  [Keeper_turn_scope](../../lib/keeper/keeper_turn_scope.mli)

**Tool**
: 이름·입력 schema·handler로 노출되는 호출 단위. MASC가 제공하는 Tool의
  descriptor와 권한 검사는 MASC가 소유한다. → [Tool boundary](13-agent-core.md#tool-boundary)

**Tool Input Validation (도구 입력 검증)**
: 도구 핸들러로 전달하기 전에 인자 스키마를 사전 검사하는 경계(`Tool_input_validation.validate_input`).
  도구 선언의 `required`·`type`·`enum`·`const`를 중첩 객체(`properties`)와 배열 항목(`items`)까지
  재귀적으로 검사하며, 위반된 모든 경로(`JSON path`)와 원인을 한 번에 보고한다(#38391).
  스키마 위반은 도구 실행이 아니라 사전 거절(`pre-dispatch refusal`)이며, `oneOf`는 루트에서만 검사한다.
  → [Tool_input_validation](../../packages/agent_core/lib/tool_input_validation.mli)

**Deferred Tool Loading (도구 스키마 지연 로딩)**
: 도구 스키마를 요청마다 싣지 않고, `keeper_tool_search` 목록에 이름과 요약만 올려 두는
  선언(`Tool_definition_toml.loading` = `Always_loaded`·`Deferrable`). 모델이 그 이름을
  넘기면 그 턴에 스키마가 붙고, 한 번 부른 도구는 그 대화의 나머지 턴에도 스키마가
  실린다(`Keeper_identity_tool_search`의 `already_used`). 그래서 이 선언이 줄이는 바이트는
  그 대화가 아직 부르지 않은 도구의 스키마다. 선언 자리는 둘이다 — 도구 파일
  `config/tools/<name>.toml`의 `defer_loading = true`, Skill composition 블록의
  `defer_loading`(#38567). composition의 선언은 Skill 블록에만 두고, 같은 이름의
  `config/tools/` 파일은 composition에 읽히지 않는다. 선언이 없으면 `Always_loaded`이고,
  TOML 파일 없이 OCaml로 만든 도구는 지연을 선언할 수 없다. 목록은 description 첫 줄
  (80바이트까지)로 도구를 소개한다. Agent Core lane에만 적용된다 — codex·antigravity·
  claude_code runtime은 도구 배열 전체를 받는다. Execution Disposition의 `Deferred`(도구
  호출의 결말)와 이름이 겹치지만 다른 개념이다. 이쪽은 스키마를 언제 싣느냐다.
  → [Tool_loading_declarations](../../lib/tool_surface/tool_loading_declarations.mli)

**Tool-host failure report**
: 클라이언트가 관측한 도구 연결 실패 기록. HTTP 인증 결과의 보고자는 감사
  이벤트의 `actor`가 된다. 본문의 `agent_name`은 실패가 보고된 Agent이며,
  감사 상세의 `reported_agent`와 실패 envelope에 보존한다. 허용된 tokenless
  요청의 보고자는 기존 로컬 attribution 정책을 따른다.

**Tool Call Outcome**
: MCP/AGENT_CORE wire 응답에 대한 가벼운 관측(`Tool_result.tool_call_outcome` =
  `Ok`·`Error`·`Unknown`). 외부 투영이라 `Deferred`를 표현하지 못하며, MASC 내부 실행
  결과의 권위가 아니다. 투영 관측이 없으면 필드를 생략하지 않고 `Unknown`으로 기록한다.
  이 관측은 `Keeper_tool_call_log.wire_outcome` 필드로 기록된다(결과 전달이 나중에
  실패하면 실행이 완료·지연됐어도 `error`가 될 수 있다). 권위 있는 값은 Execution
  Disposition이다.
  → [Tool_result](../../lib/tool_types/tool_result.mli)

**Execution Disposition**
: 한 번의 도구 호출이 실제로 어떤 결말을 냈는지에 대한 MASC의 권위 있는 분류
  (`Tool_result.disposition` = `Completed`·`Deferred`·`Failed`). Tool Call Outcome과
  별개이며, wire outcome이 이를 대체하지 않는다. 판정을 내리는 자리는 세 갈래를
  그대로 받는다 — 레지스트리와 직렬화기가 그렇다. 반대로 "실패였나" 한 가지만
  묻는 자리는 boolean 투영을 쓴다(`mcp_server_eio_call_tool.ml`의 `success`는
  `Deferred`를 `true`로 접는다; 지연은 실패가 아니다). 그 투영은 `Deferred`를
  표현하지 못하므로(`tool_result.mli`) 원장의 `success` 하나만 보고 결말을
  되돌릴 수는 없다. turn 수준의 Operator Disposition과 이름이 겹치지만 다른
  단위를 분류한다. `Failed`는 실패 등급(`Tool_result.tool_failure_class`) 다섯 가운데
  하나를 나르고, 도구 응답의 `failure_class`에 소문자로 실린다 —
  `dependency_unavailable`(필요한 외부 의존이 없음), `policy_rejection`(인증·권한·경계
  또는 호출 인자 검증에서 거절; 같은 요청은 계속 거절되지만 인자를 고치면 통할 수 있음),
  `runtime_failure`(내부 오류·결함), `workflow_rejection`(업무 규칙 위반; 지금 상태가 이
  행동을 받지 않음), `operator_cancelled`(운영자가 멈춤). 등급은 실패를 만드는 쪽이
  정한다 — `Keeper_tool_execution.failure`는 등급을 필수 인자로 받고 기본값이 없다
  (#38689·#38703). 등급을 모르는 채 `runtime_failure`("인자 탓이 아니다")로 내보내면,
  모델은 인자를 고치면 통할 호출을 고치지 않기 때문이다. 로그는 `runtime_failure`만
  ERROR, 나머지는 WARN이다(`log_level_of_failure_class`).
  → [Tool_result](../../lib/tool_types/tool_result.mli)

**Recorded Call Outcome (기록된 호출 결말)**
: 영속된 tool-call 레코드(JSONL 원장)가 그 호출이 어떻게 끝났다고 말하는지를 읽는
  셋째 닫힌 분류(`Tool_result.recorded_call_outcome` = `Recorded_succeeded`·
  `Recorded_deferred`·`Recorded_failed`·`Recorded_unsettled`·`Recorded_malformed`).
  원장을 읽는 모든 자리는 이 분류를 거친다 — 대시보드 tool 품질, Keeper 최근 행동,
  런타임 신뢰 타임라인, 도구 호출 파일 변경(`dashboard_http_tool_quality`·
  `keeper_own_recent_actions`·`keeper_runtime_trust_timeline`·
  `keeper_tool_call_file_change`). 레코드의 Execution Disposition이 권위이고,
  disposition이 없는 레코드에서만 Tool Call Outcome(`wire_outcome`)을 읽는다 —
  typed dispatch 경로를 거치지 않은 호출은 응답 관측만 남긴다. 커밋된 효과의 결과가
  모델에 닿기 전 실패한 레코드는 `Recorded_succeeded`다 — 효과는 일어났다.
  `Recorded_deferred`는 독자적인 경우로 남는다: 호출은 받아들여졌으나 효과가 아직
  일어나지 않았으므로 성공도 실패도 아니다. `Recorded_unsettled`는 `wire_outcome`이
  `unknown`이거나 disposition·wire_outcome 어느 쪽도 적지 않은 레코드 — 아직 결말이
  없다는 뜻이며, 실패도 malformed도 아니다(bench의 `tool_outcomes.sh`가 이 경우를
  실패 대신 '미정'으로 세는 근거, #38721). `Recorded_malformed`는 JSON 타입이
  틀렸거나 엄격 디코더가 거절하는 철자, 또는 객체가 아닌 레코드 — 생산자와 읽는 쪽의
  스키마 불일치다. Tool Call Outcome(외부 wire 투영)·Execution Disposition(실행의
  권위 분류)과 다른 단위다: 이 둘이 호출의 실행을 말할 때, 이 분류는 그 실행이
  원장에 **남긴 기록**을 말한다.
  → [Tool_result](../../lib/tool_types/tool_result.mli)

**Execution ID (실행 식별자)**
: 이름이 같은 서로 다른 정체성이 여럿이다. 문장에 어느 것인지 함께 적는다.
  (1) **Tool execution id** — `Ids.Execution_id.t` (RFC-0233). 도구 실행마다 dispatch
  경계에서 정확히 한 번 발급되고, 그 실행을 기록하는 모든 store(tool_calls JSONL,
  trajectory)에 찍혀 하나의 물리적 실행이 관측한 store 수와 무관하게 한 논리 행으로
  그려진다. `exec-<ms>-<seq>` 타임스탬프 접두사이고, 한 프로세스 안에서 사전순이 발급
  순서를 따른다. `turn_record.execution_ids`는 그 turn의 도구 호출들이다. TUI는 파일
  변경을 이 id로만 도구 행에 붙인다 — provider call id·경로·시각·목록 위치는 붙일
  근거가 아니다([TUI 안내](../TUI-GUIDE.md)).
  (2) **Batch execution id** — `Keeper_chat_operation.batch_membership.execution_id`는
  타입이 `Operation_id.t`이고, TUI transcript의 `execution_id`는 `batch_execution_id`가
  있으면 그것, 없으면 `request_id`다. (1)과 다른 값을 나른다.
  (3) **Execution scope id** — `Keeper_execution_scope_id.t`. durable queue와 repetition
  증거가 공유하는 producer-supplied invocation 정체성. `direct_operation`(Direct의 검증된
  request ID)과 `autonomous_admission`(Auto의 admission UUID) 둘로 만들고, prompt 텍스트나
  시각에서 추론하지 않는다. 그 canonical JSON이 `semantic_executions.scope_key`라 다른
  origin의 같은 scalar 텍스트가 충돌하지 않는다. (1)·(2)와 다른 단위다.
  → [Ids.Execution_id](../../lib/types/ids.mli),
  [Keeper_execution_scope_id](../../lib/keeper_execution_scope/keeper_execution_scope_id.mli),
  [Keeper_chat_operation](../../lib/keeper_chat_operations/keeper_chat_operation.mli)

**Provider**
: 모델에 접속하는 protocol·transport·credential을 소유하는 설정 항목.
  → [Runtime_schema.provider](../../lib/runtime/runtime_schema.mli)

**Runtime**
: Provider·Model·Binding을 해석해 얻은 실행 후보 하나. 코드가 이 후보를 `candidate`라
  부르는 자리가 있다(`Runtime_candidate_backpressure.candidate` — 시도한 런타임과 그
  process-local 관측). Board Attention Candidate와 다른 뜻이다.
  → [Runtime.t](../../lib/runtime/runtime.mli)

**media_failover**
: vision 도구가 이미지를 읽을 때 호출하는 runtime의 순서(`[runtime].media_failover`,
  "vision read fleet"). 이미지를 받지 못하는 runtime을 대신해 읽는 경우까지 포함한다.
  Keeper turn은 여기로 파견하지 않고, turn의 이미지 재라우팅은 자기 lane 안에 머문다.
  Keeper turn이 실패했을 때 다음 runtime을 고르는 **Runtime Candidate Order**와는 다른
  장치다.
  → [Runtime.media_failover](../../lib/runtime/runtime.mli) · [keeper_vision_tool](../../lib/keeper/keeper_vision_tool.mli)

**Lane**
: 모델이 도는 exact-output 작업을 위한 고정 실행 경로. 다섯
  (`Librarian`·`Hitl_auto_judge`·`Board_attention`·`Workspace_curator`·`Verifier`)은
  닫힌 타입 `Standalone_lane.t` 하나다. `Standalone_lane.all`이 열거하고 `to_id`가
  이름을 적는다. `Runtime.exact_lane`은 이 타입을 그대로 쓴다. 실행 기록의
  `Exact_lane_run_registry.lane`은 `Verifier`를 뺀 넷이고, `standalone_lane`·
  `lane_of_standalone`으로 이 타입과 오간다. Verifier 검토는 Task·Goal 검증 기록에
  남는다. 그 경로를 선언하는 설정은 `Exact-output route`이고,
  Keeper turn이 runtime 후보를 시도하는 순서(`Runtime Candidate Order`)와 다른 층이다.
  경계: 코드와 문서가 lane이라는 말을 네 곳에 더 쓴다. 뜻이 모두 다르다.
  `[runtime.lanes.<이름>]` 표와 `Runtime_lane.t`는 **Runtime Candidate Order**다.
  공식 클라이언트가 turn을 도는 경로는 **Official Client Lane**이다.
  `Keeper_memory_lane`은 Keeper 하나의 Librarian 작업을 줄 세우는 **Memory queue**다.
  `Keeper_lane.t`는 Keeper 하나가 turn을 도는 fiber다. 넷 다 이름만 같고 이 항목의
  Lane과는 다른 개념이다. Keeper 레인은 turn이나 request보다 오래 살아야 하는 서버
  소유(server-owned) 자원으로, 호출자의 switch가 아니라 서버 root switch에만 매달린다
  (`fork_server_owned`). 서버 root switch가 없거나 종료 중일 때는 turn switch로
  fallback하지 않고 typed 시작 오류 `Server_root_switch_unavailable`로 거절된다(#38426).
  Memory queue에서 기다리던 일은 나중에 `Librarian` lane에서 돈다.
  → [Standalone_lane](../../lib/runtime/standalone_lane.mli) · [Exact_lane_run_registry](../../lib/exact_lane_run_registry.mli)

**Runtime Candidate Order (런타임 후보 순서)**
: Keeper turn이 배정된 runtime이 실패했을 때 시도할 runtime 후보의 순서 있는 목록.
  `[runtime.lanes.<이름>]` 표가 이름을 붙이고 `Runtime_lane.t`(`{id; candidates}`)가
  그 값이다. TUI 화면은 "runtime candidate order"로 읽는다. RFC-0457부터 Keeper를
  특정 lane에 배정할 수 있고, 배정된 Keeper는 그 lane의 후보 순서를 따른다.
  `[runtime].media_failover`(vision fleet)와
  exact-output lane의 slot 우선순위 failover(`docs/spec/05-keeper-agent.md:394`)는
  런타임 후보 순서와 별개 축이다.
  → [Runtime_lane.t](../../lib/runtime/runtime_lane.mli)

**Max Prompt Bytes (최대 프롬프트 바이트)**
: MASC 가 클라이언트의 첫 턴에 심는 history(프롬프트)의 바이트 상한
  (`[models.<이름>].max-prompt-bytes`, `Runtime_schema.model.max_prompt_bytes`).
  클라이언트는 자기 컨텍스트 창을 스스로 소유하고, 상한을 넘는 seed는 typed
  terminal로 거절한다 — 이 상한이 없으면 keeper는 그 거절로 한도를 한 번에
  29분 걸리는 시도마다 하나씩 배워야 했다(2026-08-24). Codex 모델에 선언된
  10 MiB(10485760)는 MASC 추정이 아니라 app-server가 요구하는 벤더 자체 한도다
  (#38740). **닫힌 quota 창**(provider 가 매기는 사용량)과는 다른 층이다 — 이쪽은
  MASC 가 보내는 프롬프트 크기의 상한이고, 저쪽은 provider 측 사용량 제한이다.
  → [Runtime_schema.model](../../lib/runtime/runtime_schema.mli)

**Attempt Dispatch (시도 파견 여부)**
: Keeper turn 실행 중 후보 순서(`Runtime Candidate Order`)의 각 런타임 후보를 시도할 때,
  해당 시도가 실제 제공자 또는 클라이언트로 파견되어 실행되었는지를 구분하는 닫힌 두 값
  (`Keeper_attempt_dispatch.t` = `Runtime_attempt_dispatch.t`: `Dispatched` ·
  `Rejected_before_dispatch`). 로그 및 이벤트 wire 문자열은 각각 `"dispatched"`,
  `"rejected_before_dispatch"`다.
  - `Dispatched`: 후보 런타임의 공급자(provider) 또는 클라이언트가 실제로 호출됨.
    발생한 오류나 반환값은 해당 런타임 후보가 직접 낸 응답이다.
  - `Rejected_before_dispatch`: 파이프라인이 런타임을 호출하지 않고 사전에 거절함.
    요청을 어떤 공급자도 본 적이 없으므로 해당 런타임의 실행 실패가 아니다.
  - **파견 판단 및 실행 런타임 귀속 불변식 (#38562)**: 런타임 후보 시도 중 어떤 요청도
    실제 provider로 직렬화되어 전송(`request_serialized = true`)되지 않고 agent_core
    파이프라인의 사전 검증 단계(`Attempt_rejected`, `InputCapacity`, `ContextOverflow`,
    `InvalidConfig`)에서 거절된 경우, 해당 런타임은 요청을 본 적이 없으므로
    `Rejected_before_dispatch`로 기록되며 '실행한 런타임(the one that ran)'으로
    귀속되지 않는다. 반면, 한 시도 내에서 선행 요청이 provider에 도달한 후 후속 요청이
    사전 거절된 경우에는 이미 해당 런타임이 파견되어 실행된 것이므로 `Dispatched`로
    유지된다.
  → [Keeper_attempt_dispatch](../../lib/keeper/keeper_attempt_dispatch.mli),
  [keeper_turn_driver](../../lib/keeper/keeper_turn_driver.mli)

**Standalone Lane**
: TUI의 `MASC Lanes · Standalone` 표가 그리는 읽기 전용 LLM lane 관찰. 기존
  admission·run registry를 서술할 뿐 제어 동작을 싣지 않는다. 위의 Lane
  (고정 실행 경로) 다섯을 그린다 — Lane은 그 작업이 무엇을 실행할 수 있는지의 고정
  경로이고, Standalone Lane은 그 lane이 무엇을 실행할 수 있고 무엇을
  실행했는지의 관찰이다. 두 축을 함께 갖는다:
  - `sl_status`(상태): `Standalone_running`·`Standalone_idle`·
    `Standalone_degraded`·`Standalone_no_retained_observation`·
    `Standalone_unavailable`.
  - `sl_configuration_state`(구성): `Lane_ready`·`Lane_slotless`·
    `Lane_unconfigured`·`Lane_registry_unavailable`.
  서버는 구성 축의 마지막 둘을 `sl_status`에서 "unavailable" 한 단어로
  합치지만, 아무도 구성하지 않은 lane과 registry를 읽지 못한 lane은 다른
  문제이고 다른 처방을 갖기에 여기서는 나눈다. `Lane_slotless`는 서버가
  "degraded"라 부르는 것 — 구성됐으나 catalog slot도 CLI slot도 admit되지
  않은 상태다. 행은 `Standalone_lane.t`의 lane마다 하나다.
  `server_standalone_lane_projection.ml`의 `lane_spec`이 lane마다 이름·목적·필수
  여부를 적고, 표는 필수 lane 둘(`Board_attention`·`Hitl_auto_judge`)을 먼저
  그린다. 고른 lane의 상세 맨 아래 두 줄(Output meaning·Evidence)은
  `Tui_decode.standalone_lane_answer`가 lane마다 따로 적는다.
  → [tui_decode.mli](../../lib/tui_decode.mli)

**Keeper Health Reading (Keeper 건강 판독)**
: Keepers 명단이 한 Keeper의 상태를 읽는 닫힌 네 값(`Tui_decode.keeper_health_reading`).
  `Health_running`(Phase Running이고 turn이 하나 이상 기록됨)·`Health_idle`(Phase
  Running, 아직 turn 없음)·`Health_failing`(Phase Failing — keepalive는 turn을 계속
  돌리지만 그 turn들이 실패한다)·`Health_offline`(keepalive가 돌지 않아 turn을 받지
  못함). 좁은 칸은 글자 대신 mark 하나로 그린다 — `●` healthy·`!` failing·`·` idle·
  `×` offline, 그리고 사람이 멈춘 `○` paused와 명단을 읽지 못한 `-` unread. mark는
  health label 문자열이 아니라 이 variant를 match해 고르므로, 새 health 어휘가
  생기면 조용히 healthy로 읽히는 대신 컴파일 오류가 난다.
  → [masc_tui_keeper_mark.mli](../../bin/masc_tui_keeper_mark.mli),
  [tui_decode.mli](../../lib/tui_decode.mli)

**Reasoning Effort (추론 노력)**
: OpenAI 호환 wire가 싣는 추론 노력의 정규 typed 값. `Reasoning_effort.t`가
  유일한 SSOT이고 일곱 단계다 — `None_`·`Minimal`·`Low`·`Medium`·`High`·
  `XHigh`·`Max`. 토큰 예산은 다른 provider wire이고, 이 모듈은 숫자 예산에서
  노력 등급을 절대 추측하지 않는다. provider별 별칭은 `Reasoning_dialect`가
  맡는다.
  → [Reasoning_effort](../../packages/agent_core/lib/llm_provider/reasoning_effort.mli)

**Effort Ladder (노력 사다리)**
: 일곱 노력의 서열 — `None_`=0 … `Max`=6. `rank`가 자리, `compare`가 순서다.
  catalog가 요청한 노력을 모델이 받는 집합으로 깎을 때(clamping) 이 사다리로
  요청보다 아래인 가장 가까운 받는 노력을 고른다.
  → [Reasoning_effort.rank](../../packages/agent_core/lib/llm_provider/reasoning_effort.mli)

**Accepted Reasoning Efforts (받는 노력 집합)**
: 한 provider·모델이 받는 노력의 부분집합. `Capabilities.t`의
  `accepted_reasoning_efforts`가 싣는다. 기본은 모델 행이 자기 집합을 선언하지
  않으면 provider base의 집합을 물려받는 것이다(`None` → base). provider가
  사다리를 모델별로 문서화하면 모델 행이 자기 집합을 선언해 base를 덮는다 —
  xAI가 그렇다(PR #37868). 요청한 노력이 집합 밖이면 거절이 아니라 아래 단계로
  내려서(Effort Ladder) 처리한다. 해석된 집합이 없으면(`None`) 닫힌 실패다.
  → [Capabilities.accepted_reasoning_efforts](../../packages/agent_core/lib/llm_provider/capabilities.mli)

**Reasoning Effort Rejection (노력 거절)**
: 요청을 wire에 싣기 전 `validate_reasoning_effort_request_typed`가 내는 typed
  거절. `Unsupported_reasoning_effort`(집합 밖), `Undeclared_reasoning_effort_capability`
  (선언 없음), `Explicit_disable_outside_ladder`(명시 끄기가 사다리 밖),
  `Reasoning_undeclared_on_auto_enabling_wire`(스스로 켜는 wire인데 노력도
  `reasoning_uncontrolled`도 안 밝힘). 검사하는 값은 wire가 실을 값이다 — 명시
  `enable_thinking = Some false`는 노력 `none`으로 가므로, `none`이 없는 사다리는
  그 끄기를 `Explicit_disable_outside_ladder`로 거절한다.
  이 거절은 깎기(Effort Ladder)와 나란한 대안이 아니라 그 뒤의 문지기다 — 공식
  클라이언트 호스트가 요청 전에 운영자가 선언한 노력을 먼저 깎고(로그 `reasoning
  effort clamped to catalog`), 문지기는 wire가 실을 값(명시 토글이 적용된 뒤)을 본다.
  그래서 집합 밖 선언 노력은 깎여 통과하고, 거절로 남는 것은 깎을 기준이 없는 선언
  없음과, 토글이 사다리 밖으로 만든 값이다.
  → [Provider_config.reasoning_effort_request_rejection](../../packages/agent_core/lib/llm_provider/provider_config.mli)

**DOS Lane**
: 서버 안에 사는 DOS 기계 하나. Keeper 는 `masc_dos_*` 도구로 같은 기계에 키를
  넣고 화면을 읽는다. 시간은 8086 명령 수로 흐르고, 도구를 불러야만 간다.
  `settled` 는 "프로그램이 키를 물었고 화면이 멈췄다" 이다. 게임 파일은
  `<.masc>/dos/programs/` 에 두고, 게임이 쓴 세이브는 `<.masc>/dos/saves/` 에
  남아 다음 로드에서 다시 쓰인다.
  → [Dos_lane](../../lib/dos_lane/dos_lane.mli)

**조종권 (Controller)**
: DOS Lane 기계의 시간을 움직일 수 있는 한 사람. 핫시트 게임에서 여러 Keeper
  가 한 키보드를 번갈아 쓰기 때문에 있다. 쥔 사람만 load·eject·step·press·click·
  type 을 하고, 다른 사람은 거절되지만 화면은 볼 수 있다. `masc_dos_pass` 로
  넘기면 보드 글이 다음 사람을 @멘션해 깨운다. 쥔 Keeper 가 일시정지되거나 정지하면
  다음 Keeper 가 움직일 때 풀린다. 충돌 뒤 자동 재시작을 기다리거나 막 켜지는 중인
  Keeper 는 그대로 쥔다. 이름은 부르는 쪽이 스스로 대는 값이라
  권한 검사가 아니라 차례를 정하는 장치다.
  → [Dos_lane.pass](../../lib/dos_lane/dos_lane.mli)

**MSX Lane**
: 서버 안에 사는 MSX 기계 하나. Keeper 는 `masc_msx_*` 도구로 같은 기계에 키를
  넣고 화면을 읽는다. DOS Lane과 같은 축의 공유 머신으로, Lane Add-on의
  `msx_capture` 원천이 이 머신을 관측한다.
  → [Msx_lane](../../lib/msx_lane/msx_lane.mli)

**Browser Lane**
: 서버가 관리하는 브라우저 세션. Keeper 는 `masc_browser_*` 도구로 탭을 읽고
  조작한다. Lane Add-on의 `browser_document` 원천이 이 세션을 관측한다.
  → [Browser_lane](../../lib/browser_lane/browser_lane.ml)

**Lane Add-on**
: 기존 MASC 원장과 실행 환경 위에 붙는 선택적 관측·관계 레이어. MSX Lane의 머신,
  DOS Lane의 머신, Browser Lane의 세션, Keeper의 도구와 턴 소유권을 재사용한다. 패키지 하나가 여러
  Lane 행을 제공할 수 있다. 패키지는 `lane.toml`의 `contributions`로 observe·derive·act
  기여를 선언하며, act 기여 패키지(예: `dos-world`·`quiz-grader`)는 `masc_lane_act` 도구로
  조치를 출하한다 — 즉 이 레이어는 관측뿐 아니라 조치(act)까지 포함한다. 패키지 worker는
  그 계산을 격리한다. attach·detach와 Add-on 장애는 기존 Keeper의 권한·도구·진행 중
  작업을 축소하지 않으며, 추가 근거는 활용·보류·무시할 수 있다. 원천 어댑터는
  `snapshot_file`·`msx_capture`·`dos_capture`·`lane_output`·`browser_document`이고,
  코어는 도메인 의미를 해석하지 않고 공통 row/coverage를 검사·표시한다.
  → [설계 계약](../design/lane-addon-v0.md),
  [Lane_addon_types](../../lib/lane_addon/lane_addon_types.mli),
  [Lane_addon_sources](../../lib/lane_addon/lane_addon_sources.ml)

**Quiz Lane (퀴즈 레인)**
: 저장된 기록(Board·기억 OS·GitHub)에서 인용한 사실 묶음(`deck.json`, `snapshot_file`)을
  바탕으로 문제를 내고 답을 채점하는 Lane Add-on 패키지 쌍(`quiz-questions`·`quiz-grader`).
  출제와 채점의 권한을 엄격히 분리하고, 기록 인용과 완전 단어 일치를 강제한다(#38433, task-1688).
  - **출제·채점 분리**: 출제 패키지(`quiz-questions`, `derive` 기여)는 팩트 덱에서 문제를
    뽑아 `quiz/questions`로 내보낼 뿐 채점할 수 없다. 채점 패키지(`quiz-grader`, `derive`·
    `act` 기여)는 출제 결과(`lane_output`)와 같은 팩트 덱을 함께 받아, `masc_lane_act` 도구로
    들어온 응답을 대조해 `quiz/grades` 판정과 `quiz/score` 누적 점수를 발행한다.
  - **기록 인용 및 완전 단어 일치**: 문제는 임의의 요약이나 추정이 아니라 실제 저장된
    기록 파일에 글자 그대로 존재하는 인용문(`quote`)이어야 하며, 정답(`answer`)은 그 인용문
    안의 완전한 단어(whole-word)여야 한다(예: `"unmerged"` 속의 `"merged"` 매칭은 거절).
    질문 대상 필드는 닫힌 6종(`author`·`claimant`·`status`·`merged_commit`·`cause`·
    `decision`)이고, 필드마다 서로 다른 답을 가진 사실이 둘 이상 있어야 출제된다. 단 하나의
    사실이라도 기록 인용 규칙을 어기면 덱 빌드(`build_deck.py`)는 덱 생성을 통째로 거절한다.
  - **자칭 응답자 라벨 (Claimed Answerer)**: 채점 점수는 호스트가 인증한 호출자 정체성이
    아니라 응답자가 액션 payload에 스스로 적어 낸 라벨(`answerer_basis = self_claimed_label`)을
    기준으로 `by_claimed_label`에 집계한다. 호스트는 인증 요청자를 보존하되 워커에 넘기지
    않는다. 응답자 자신에 관한 질문은 `excluding_claimed_about_answerer`로 가려진다.
  - **덱 식별자 무효화**: 덱 빌드가 새 `deck-id`를 발급하면 이전 덱으로 출제된 질문들은
    의도적으로 채점 불가(`ungradable`)가 되어 낡은 문제와 새 정답의 혼선을 막는다.
  → [Quiz Deck Skill](../../addons/quiz-questions/skills/quiz-deck/SKILL.md),
  [quiz-questions](../../addons/quiz-questions/lane.toml),
  [quiz-grader](../../addons/quiz-grader/lane.toml)

**Runtime execution**
: 모델·도구·재개 상태를 Agent Core가 소유하는지 공식 클라이언트가 소유하는지의 구분.
  → [Runtime_execution.t](../../lib/runtime/runtime_execution.mli)

**Exact-output route**
: Librarian, Workspace memory curator, HITL auto judge, Board attention 같은 단독
  모델 작업의 목적별 실행 경로(`Agent_core.Exact_output`). 설정은 API slot과 후속 CLI
  후보 순서를 선언한다(`exact_output_lane_decl`). 대부분의 exact route는 도구를 쓰지
  않고 단일 완결 응답을 받아 도메인 검증기가 유효성을 판정하며, 일반 턴 failover인
  Runtime Candidate Order와 구분된다. 단 **verifier_exact은 예외로 도구를 호출한다** —
  판정(verdict)을 `report_review_verdict` 도구 호출 한 번으로 낸다
  (`lib/task/anti_rationalization.ml`: "The verdict channel is the
  report_review_verdict tool call, so every slot needs a tool-calling model"). 이 lane의
  모든 slot은 도구 호출이 가능한 모델이어야 한다.
  - **슬롯 전진 조건 (`execution_failure_may_advance`)**: 한 슬롯이 실패했을 때 패스를
    끝내거나 범위를 줄이지 않고 선언된 다음 후보 슬롯으로 넘어가는 경우는 둘이다.
    (1) 보내기 직전 단계(`Before_dispatch`)에서 실패했고 이 슬롯이 아무것도 보내지 않았다
    (`receipt_dispatch_count = 0`). (2) 한 번 보낸 뒤(`receipt_dispatch_count = 1`) 이
    바인딩의 사정으로 실패했다 — 헤더 기한(`connect_timeout_s`, `Http_operation`)이나 전체
    기한(`body_timeout_s`, `Wall_clock`) 안에 응답 헤더가 오지 않음(#38437); 2xx 헤더는
    왔지만 전체 기한 안에 본문이 끝나지 않음(`Response_body_deadline_exceeded`, 원문 응답과
    provider trace가 남지 않았을 때); 응답으로 온 제공자 거절 가운데 Candidate Fault가
    `Binding`이나 `Unattributed`로 읽는 것(413·429·402·529·5xx·창 초과(#38454)·401·403·
    404·이유를 기계가 읽을 수 없는 거절·본문이 기한 안에 오지 않은 거절, #38913); 답이 JSON으로 읽히지 않음(`Invalid_json_output`); content가 비었음(답을 content
    밖 필드에 둠, `Missing_output`). 그 밖에는 넘기지 않는다 — 보낸 뒤의 다른 기한 종류
    (`Queue`·`First_token`·`Capacity_backpressure`·`Non_streaming_body`·`Stream_body`·
    `Stream_idle`·`Provider_step`·`Cli_stdout_idle`·`Unknown_timeout`)와 보낸 뒤 결과를
    모르는 실패가 그렇다. 바인딩의 기한·창·키·quota·출력 방언은 그 슬롯의 성질이라, 다음
    후보는 자기 것을 들고 같은 입력을 받을 수 있다(예: 더 큰 창의 Claude CLI).
  - **생성 발송 관측 권위 (`flow_evidence_generation_dispatch`)**: 걸음(walk)에 속한 어느
    후보라도 외부 완료 생성 요청(`generation dispatch`)을 시작했는지 여부를 불변
    증거(`Started`·`Not_started`)로 기록한다. 앞선 슬롯이 생성 요청을 보낸 뒤(예: 5xx
    수신) 후속 슬롯으로 넘어가 최종 슬롯이 발송 전 실패하더라도, 걸음 전체의 영수증에는
    `outward_effect=started`로 보존된다(마지막 실패 슬롯의 상태만 보고
    `outward_effect=none`으로 오기록하지 않는다). 단, 사전 토큰 수 측정
    (`token-count measurement`)은 별개 외부 호출이며 생성 발송 사실로 계수하지
    않는다(#38525).
  - **Exact-output registry와 설정 저장**: exact 요청이 쓰는 target 목록
    (`Runtime_exact_output_registry`). target 출처는 둘이다(`exact_output_target_source`) —
    `Runtime_binding_targets`(이 파일의 HTTP 바인딩에서 만들고, 슬롯의 전체 기한은 그
    provider의 `exact-body-timeout-s`), `Replacement_catalog_targets`
    (`AGENT_CORE_MODEL_CATALOG`가 교체 카탈로그를 가리키면 그 `[[targets]]` 행이 target
    전부이고 각자 `body_timeout_s`를 가진다. runtime.toml의 바인딩 필드는 닿지 않는다).
    registry는 부팅 때 만들고, 서버를 거친 설정 저장마다 같은 커밋에서 다시 만든다
    (#38850). 저장 응답의 `application.exact_output_registry`는 셋 가운데 하나다 —
    `applied`(`Exact_output_registry_replaced`, `targets`는 `runtime_bindings`·
    `replacement_catalog`), `unpublished`(돌고 있는 registry가 없고 저장은 첫 registry를
    만들지 않는다. 재시작이 필요하다), `kept`(저장한 글도, 그 글이 대신한 파일도 registry를
    만들지 못한다. 옛 registry가 계속 쓰이지만 파일과 맞지 않고, 다음 부팅은 registry를
    만들지 않는다. startup report에 `exact_output_registry_stale`로 남는다). 저장한 글이
    registry를 만들지 못하면 쓰기 전에 거절하되, 디스크의 파일도 못 만드는 경우는 통과시킨다
    — 이미 있던 결함이 keeper 배정 같은 저장을 막지 않게 하려는 것이다.
  - **슬롯 본문 기한 빈칸 (`exact_slot_body_deadline_gap`)**: `slots`가 가리키는 HTTP
    runtime의 provider가 `exact-body-timeout-s`를 선언하지 않은 슬롯. 부팅은 막지 않고
    degrade한다 — 그 슬롯을 lane에서 빼고, 슬롯마다 WARN 한 줄을 남기고, startup report
    (`/health`의 `runtime_startup_degradation`)에 `exact_slot_body_deadline_gaps`로 올린다.
    HTTP 슬롯이 모두 빠진 lane은 `cli_slots`로 걷고, 아무것도 남지 않은 lane만 unavailable
    (`exact_lanes_emptied_by_body_deadline_gaps`)이며 다른 lane은 그대로 뜬다. 저장이 새
    빈칸을 더하면 쓰기 전에 거절하고(`Exact_slot_body_deadlines_absent`), 파일에 이미 있던
    빈칸은 막지 않는다. `cli_slots`와 `Replacement_catalog_targets`에는 해당하지 않는다
    (#38849).
  → [Exact_output](../../packages/agent_core/lib/llm_provider/exact_output.mli),
  [Exact_lane_run_registry](../../lib/exact_lane_run_registry.mli)

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

**Identity Row State (Identity 행 상태)**
: Identity 탭이 서비스 하나에 대해 말하는 닫힌 다섯 값(`Masc_tui_types.identity_row_state`).
  `Identity_not_attached`(선언이 없거나 도구 목록이 `None` — 한 번도 붙지 않음)·
  `Identity_attached_without_tools`(붙었으나 제공하는 도구가 빈 목록)·
  `Identity_switch_unreadable`(스위치 저장소를 읽지 못함)·`Identity_switched_off`(운영자가
  껐음)·`Identity_attached of int`(붙었고 도구 n개). 우선순위가 있다 — 아무것도 제공하지
  않는 서비스는 스위치가 무엇이라 말하든 그렇게 말하고, 읽지 못한 스위치는 스위치 값보다,
  스위치 값은 도구 수보다 앞선다. 운영자가 꺼 둔 서비스는 catalog가 도구를 아무리 많이
  이름 대도 이 Keeper에게 아무것도 주지 않는다. 행과 그 위 요약 줄이 이 한 함수를 읽으므로
  둘이 어긋날 수 없다. 요약 줄은 `attached`·`switched off`·`attached with no tools`·
  `with an unreadable switch`를 센다.
  → [masc_tui_types.ml](../../bin/masc_tui_types.ml)

**Detail State (상세 상태)**
: 상세를 가진 판의 바인딩이 어느 상태에서 응답하는지의 닫힌 세 값
  (`Masc_tui_keys.detail_state`). `Either`(두 상태 모두 — 기본)·`List_only`(상세가 닫혀
  있을 때만)·`Detail_only`(상세가 열려 있을 때만). 상세를 가진 판은 한 푸터로 두 상태를
  그리므로, 이 축이 없으면 동작하지 않는 키를 푸터에 하나 보여준다 — 상세가 열린 뒤의
  `Right / Enter`, 닫힌 동안의 `[ / ]`. 푸터는 `~detail_open`으로 자기 상태를 말하고,
  그 인자가 없으면 모든 바인딩을 광고한다. `has_detail_scoped_keys`가 그런 판을 잡는다.
  → [masc_tui_keys.mli](../../bin/masc_tui_keys.mli)

**Connector Connection (커넥터 연결)**
: Channels 판이 한 transport의 연결에 대해 그리는 닫힌 다섯 값
  (`Masc.Tui_decode.connector_connection`) — `Connector_connected`·
  `Connector_connected_unavailable`·`Connector_disconnected`·`Connector_offline`·
  `Connector_stale`. 배지가 철자하는 단어는 `CONNECTED`·`CONNECTED / UNAVAILABLE`·
  `DISCONNECTED`·`UNAVAILABLE`·`STALE`(`Masc_tui_connector_state.badge_word`). 같은 판이
  gateway 상태(`connector_gateway_state`, 닫힌 일곱 값)나 poll 상태
  (`connector_poll_state`, 닫힌 세 값)를 따로 그린다. 서버가 모르는 값을 보내면 그 커넥터
  행만 읽지 못한 행(`connector_refusal`)으로 남고, 판은 그 행을 이름과 이유 한 줄로 그린다.
  나머지 행은 그대로 읽힌다. 배지가 이미 말한 상태는 그리지 않는다. 그 판정은 문자열 비교가 아니라 생성자
  짝으로 한다: `Connector_connected` 아래 `Connector_gateway_connected`,
  `Connector_disconnected` 아래 `Connector_gateway_disconnected` 두 짝뿐이다 — Discord 행이
  `Connection ● CONNECTED` 위에 `Runtime state connected`를 겹쳐 읽던 자리다. 연결은 한
  번만 그린다.
  → [Masc_tui_connector_state.mli](../../bin/masc_tui_connector_state.mli),
  [Tui_decode.connector_connection](../../lib/tui_decode.mli)

## Collaboration State

**Board**
: 에이전트와 사람이 발견·질문·답변·의견·결정을 올리는 게시판. 글마다 보는 범위가 있다. 올린 글은
  재시작해도 남는다.
  글의 `content_updated_at`은 생성 또는 제목·본문·작성자가 실제로 바뀐 시각이다.
  댓글·투표·고정 등 일반 활동이 갱신하는 `updated_at`과 구분한다.
  같은 내용으로 다시 저장하면 `content_updated_at`은 유지한다.
  `Board_post_updated`는 실제 편집 저장이 성공한 뒤 발행한다. 게시글 ID와
  `content_updated_at`이 같은 편집은 한 사건이며, 뒤의 편집은 새 사건이다.

**Karma**
: 다른 에이전트가 내 글이나 댓글에 준 upvote 한 번마다 생기는 `karma_event`의 합.
  Board 안의 개념이고 별도 도메인이 아니다. 자기 upvote, downvote, 지워진 대상에 준
  투표는 이벤트를 만들지 않는다. 이벤트는 `delta`를 직접 적어 두고, 원장은 vote log에서
  다시 만든다([board_types.mli](../../lib/board_types/board_types.mli)의 `karma_event`,
  [board_votes.ml](../../lib/board/board_votes.ml)).

**Flair (표시 태그)**
: 글쓴이가 본문에 `[flair:<name>]` 꼴로 적는 표시 태그. 이름은 소문자이고
  (`[a-z]+`), 고정 카탈로그 `Board_votes.available_flairs`에 있는 이름만 붙는다 —
  모르는 이름은 아무 표시도 붙지 않는다(`extract_flair`). 카탈로그 항목은
  `(name, emoji, label)` 셋이고 `GET /api/v1/board/flairs`가 내보내며,
  `flair_to_yojson`이 한 항목을 `{name, emoji, label}`로 직렬화한다. 대시보드는
  이 값을 배지(`bd-badge`)로 그린다. 표시만 하고 아무것도 정하지 않는다 — 순위·권한·분류에
  쓰이지 않는다. **Hearth**와 다른 축이다 — hearth는 글을 주제로 가르는 필드이고,
  flair는 글쓴이가 본문에 적는 표시다.
  → [board_votes.mli](../../lib/board/board_votes.mli)

**Hearth (토픽 카테고리)**
: Board 글을 주제로 가르는 축. 글은 선택적으로 `hearth` 필드를 갖고 lowercase로
  정규화한다. `list_hearths`가 hearth별 글 수를 내림차순으로 돌려주고,
  `list_posts ?hearth`가 한 hearth로 좁힌다. TUI Board 목록은 `f`/`F`로 hearth를
  돌리고 `H`로 chooser를 연다. hearth별 글 수 목록을 **census**라 부르고, Board
  제목이 목록이 실은 수와 게시판이 가진 수를 함께 말할 때 쓴다(`(50 of 109)`).
  hearth 슬러그가 어떤 SubBoard의 slug와 같으면 그 글은 그 SubBoard에 묶여 접근 정책을
  따르고, SubBoard가 지워지면 소속 글의 hearth는 orphan 정책으로 지워진다
  (`11-board.md` §11).
  → [11-board.md §8](11-board.md),
  [board_types](../../lib/board_types/board_types.mli),
  [board_votes](../../lib/board/board_votes.mli)

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
  판정하는 쪽은 authority로, 일을 낸 쪽은 판정 payload의 `producer`로 적는다. 그 작업
  관계와 실행 구간은 `producer`의 것이다.
  `AwaitingVerification`인 Task에 claim하면 `Held_pending_verdict`로 거절되므로
  판정 전에는 Keeper가 다시 맡을 수 없다. 완료·취소 판정은 Keeper가 내리지 못하고,
  서버 안의 판정 에이전트나 인증된 운영자만 내린다(**Completion Authority**).

**Goal**
: 장기 의도와 Task 연결을 기록하는 단위. phase는 `Executing`, `Verifying`,
  `Awaiting_confirmation`, `Completed`, `Dropped`다. 완료를 요청하면
  `Verifying`으로 들어가고, verifier가 증명을 통과시킨 뒤 사람이 확인해야
  `Completed`가 된다(`lib/goal/goal_phase.mli`). `Verifying` 중에도 연결된
  Task는 계속 진행할 수 있다. verifier가 답하지 않으면 운영자가 `Verifying`에서
  `drop`으로 `Dropped`로, `reopen`으로 `Executing`으로 옮길 수 있다. 그 뒤에
  도착한 verdict는 거절된다. 완료 verdict는 verifier가 기록하고, 사람의
  확인이 `Completed` 전이를 확정한다. `goal_phase.mli`의
  `admits_self_directed_progress`가 이 경계를 정의한다. TUI Overview 투영은
  `Goals 블록 (Overview Goals)`를 따른다.

**Schedule (예약)**
: 정한 시각에 Keeper를 깨우라는 요청. 저장되므로 서버를 다시 켜도 남는다. 만들기·조회·
  수정·취소와 기록(노트) 추가·조회 도구가 있다. Keeper를 깨울 뿐이고, 깨어난 Keeper가
  하려는 바깥 작업을 대신 허락하지 않는다. 그 허락은 payload를 처리하는 쪽의 gate가 정한다.
  - 두 식별자: `schedule_id`는 정의를 교체해도 살아남는 안정 id이고,
    `schedule_instance_id`는 정의 하나의 인스턴스마다 새로 발급된다. 그래서 이전 정의의
    wake는 교체된 정의의 증거가 되지 않는다.
  - 두 행위자: 행은 `requested_by`(요청한 쪽)와 `scheduled_by`(예약한 쪽)를 가진다.
    기록되는 actor는 인자가 아니라 경계가 인증한 호출자이고, 만들기(`create`)는 호출자를
    두 칸에 똑같이 적는다. 도구 스키마에는 actor 인자가 없다. 호출이
    `requested_by_*`·`scheduled_by_*`에 호출자와 다른 값을 적으면 `actor_mismatch`로
    거절되고, 호출자와 같은 값은 아무것도 바꾸지 않는다. 이름 없는 호출자(`Unnamed_caller`)는
    거절된다. 수정(`update`)은 기존 행에 저장된 두 행위자를 보존하며, named caller는
    자신이 소유한 예약(`owner=self`: 자신이 예약했거나 자신을 깨우는 행)만 수정·취소할
    수 있고 다른 예약은 `not_schedule_owner`로 거절된다(운영자 자격만 임의 변경 가능).
  - `wake_record`는 scheduler가 남기는 일반 wake 시도(`Wake_running`·`Wake_succeeded`·
    `Wake_failed`)이고, Keeper turn 결과는 Keeper 원장에 산다 — 같은 것이 아니다.
  - 미기동·정지 대상 수락: 대상 Keeper가 등록되어 있으나 fiber가 돌지 않는 상태
    (`offline`·`crashed`·`restarting`·`draining`)이거나 일시정지(`paused`) 상태일 때의
    due 발화는 재시도 실패로 튕기지 않고 단 1회 수락(`accepted`)되어 해당 Keeper의
    durable 큐에 대기한다(#38523). 다음 턴이 깨어날 때 stimulus로 읽히며, 새 발화가
    이전 대기를 대체하여 큐에는 스케줄당 최대 1건만 유지된다.
  - 노트는 `schedule_id`에 매이고 append-only다. terminal 전이 뒤에도 남는다 —
    상태가 아니라 이력이다.
  - 상태는 `Scheduled`·`Due`·`Running`·`Succeeded`·`Failed`·`Cancelled`·`Expired`,
    반복은 `One_shot`·`Interval`·`Daily`·`Cron`이다.
  → [Schedule_domain](../../lib/schedule/schedule_domain.mli) · [Schedule_store](../../lib/schedule/schedule_store.mli)

**Fusion**
: 여러 독립 판단을 비동기로 수집하고 하나의 결론으로 합성하는 실행. 패널 구성원
  (panelist)들이 각자 답하고, 심판(judge)이 하나의 종합을 낸다. 실행 단위는 preset이며,
  검증을 통과한 `Validated_preset`만 게이트와 orchestrator로 흐른다. 패널 정체성은
  `panelist_id` — 라벨이 있으면 `label (model)`, 없으면 `model`이고, 같은 model이라도
  라벨이 다르면 다른 패널이다. JOJ(judge-of-judges)는 1차 심판 여럿과 meta 심판을 둔다.
  → [Fusion_policy](../../lib/fusion_core/fusion_policy.mli)

**Fusion Seat (자리)**
: Fusion 실행에서 답을 내는 한 자리. panel 한 명과 judge 하나가 각각 한 자리다
  (`Panel_seat`·`Judge_seat`). 자리마다 경로 이름 하나를 받고, 그 이름을 후보 목록으로
  풀어 적힌 순서로 시도한다. 실행마다 명단(Fusion Roster)을 바꿀 수 있다.
  → [Fusion_types.seat](../../lib/fusion_core/fusion_types.ml)

**Fusion Judge Role (심판 역할)**
: Fusion 심판 자리(`Judge_seat`)의 정체성 중 위상 종류. `Fusion_types.judge_role`의 닫힌
  합타입이고, 정체성(panelist_id·stage 번호)을 뺀 종류 라벨이 board meta_json의 `role`
  필드와 TUI 디코드가 공유하는 어휘다(`judge_role_kind_label`): `single`(simple 위상 단일
  심판)·`refine`(refine/conditional 2차)·`first`(JOJ 1차, panelist_id 보존)·`meta`(JOJ
  reconcile)·`stage_meta`(staged JOJ stage reducer, `stage-N`)·`final_meta`(staged JOJ 최종
  reducer). 한쪽만 아는 종류는 그쪽에서 실패하지 다른 것으로 그려지지 않는다.
  TUI의 seat 표기는 `judge/<role>/<identity>`이고, panel 자리는 `panel/<id>`다.
  경계: 이 "role"은 프롬프트 `<role>` 블록(Keeper Prompt)도, Message의 role도, Board
  Interest 판정의 `keeper_role`도 아니다 — Fusion 심판의 위상 종류다.
  → [Fusion_types.judge_role](../../lib/fusion_core/fusion_types.mli)

**Fusion Route (경로 이름)**
: Fusion 자리에 적히는 값. Keeper 배정과 같은 규칙(`Runtime.resolve_assignment`)으로
  푼다 — `[runtime.lanes.<이름>]`이 있으면 그 lane 의 후보 목록, 없고 런타임 id 이면 그
  런타임 하나짜리 후보 목록. 한 자리는 후보를 적힌 순서로 시도하고 처음 쓸 수 있는
  답에서 멈춘다(panel 은 비어 있지 않은 글, judge 는 파싱을 통과한 종합). 적힌 이름이
  로드된 lane 도 런타임도 아니면 `Unknown_route`, 런타임의 카탈로그 행이 없으면
  `Route_unavailable` typed 실패다. 배포 preset 의 자리 이름은 같은 파일이 선언한 lane
  이나 `[provider.model]` 바인딩이어야 하며, 아니면 첫 실행이 아니라 빌드에서 잡힌다.
  용어집 `Exact-output route`(Librarian 같은 단독 모델 작업의 목적별 실행 경로)와 다른
  층이다 — 이쪽은 Fusion 자리의 runtime 후보 순서를 지목한다.
  → [Fusion_seat](../../lib/fusion/fusion_seat.mli)

**Fusion Roster (명단)**
: 한 Fusion 실행만 preset 의 자리 대신 쓰는 경로 이름 목록. `judge_route` 는 심판 자리
  하나를, `panel_routes` 는 패널 명단을 바꾼다. `None` 인 칸은 preset 값을 그대로 쓴다.
  명단을 preset 에 얹는 규칙과 검사는 `Fusion_policy.with_roster` 한 곳에 있고, 검사를
  통과하지 못하면 `Roster_invalid` 로 거절한다. 바꾸지 않으면 `preset_roster`(두 칸 모두
  `None`)다. 명단에 적힌 이름은 `route_name` 으로 앞뒤 공백을 떼어 읽는다.
  → [Fusion_types.roster](../../lib/fusion_core/fusion_types.mli)

**Fusion Delivery Obligation (전달 의무)**
: Fusion 실행 하나가 접수됐다는 사실을 재시작 뒤에도 되살리려고 남기는 durable 기록.
  요청 수명주기와 종결의 유일한 진실은 여전히 `Keeper_msg_async`이고, 이 기록은 그
  일반 기록이 알 수 없는 것만 담는다 — 접수한 Fusion 요청과 종결을 되비출 원래
  continuation 채널. 워커가 시작되기 전에 `prepare` 로 접수를 남기고(같은 요청 id·같은
  payload 재생은 `Already_present`, 같은 id·다른 payload 는 `Identity_conflict`), 종결
  되비추기가 성공한 뒤에만 `remove_delivered` 로 그 기록을 지운다. `inventory` 는 깨진
  기록을 고치거나 버리지 않고 살릴 수 있는 이웃 옆에 보고한다. 되비추는 쪽은
  `Fusion_delivery_projector`다.
  → [Fusion_delivery_obligation](../../lib/fusion/fusion_delivery_obligation.mli)

**Fusion Run Failure Code (Fusion 실행 실패 코드)**
: Fusion 실행 목록의 STATE 칸이 실패한 실행에 그리는 코드. 서버가 실행을 `Failed` 로
  종결할 때 적는 `failure_code` 이고, 두 닫힌 집합 중 하나에서 온다 — 심판 종합이
  실패하면 `Fusion_core.Fusion_types.judge_failure_tag` 가 돌려주는 열 이름
  (`timeout`·`provider_error`·`empty_response`·`empty_result`·`build_error`·`parse_error`·
  `panels_unavailable`·`unknown_route`·`route_unavailable`·`internal_error`), 전달이
  실패하면 `Fusion_sink.delivery_failure_code` 가 닫힌 합 `delivery_failure`(생성자 여섯:
  `Computation_failed`·`Lost`·`Cancelled`·`Persistence_failed`·`Evidence_unavailable`·
  `Evidence_unreadable`)에서 파생해 돌려주는 문자열 여섯(`computation_failed`·`lost`·
  `cancelled`·`persistence_failed`·`evidence_unavailable`·`evidence_unreadable`)이다.
  코드는 문장이 아니라 tag 이고, 그중 가장 넓은 `evidence_unavailable` 이 STATE 칸
  스무 칸을 정확히 채운다. 칸을 채우는 것은 이 값만이 아니다 — 같은 칸이 그리는 진행
  단계 `recording(%d/%d)` 도 네 자리 수 둘이면 스무 칸이다. 세 어휘 전부와 칸 폭은
  `test/test_tui_fusion_state_width.ml` 이 소스에서 읽어 대조하므로, 여유가 얼마인지는
  그 테스트가 말한다. 전체 오류 문장은 고른 실행의 줄에 남는다.
  → [Fusion_core.Fusion_types.judge_failure_tag](../../lib/fusion_core/fusion_types.mli),
  [Fusion_sink.delivery_failure_code](../../lib/fusion/fusion_sink.mli)

**Gate**
: 외부 효과를 설정된 방식(`Keeper_gate_mode.t`: `Always_allow`·`Auto_judge`·`Manual`,
  `Manual`은 사람이 판정)으로 판정하는 경계. pending 판정은 다른 작업을 막지 않는다.
  **다른 것**: 채팅 창에서 도구 호출 하나를 두고 운영자에게 묻는 도구 승인
  (`Keeper_tool_approval_mode`: `Auto`·`Yolo`)은 Gate가 아니다. 그 대기는 턴을 멈추고
  답을 기다리며, `Yolo`로 꺼도 Gate로 가는 바깥 작업은 Gate가 따로 판정한다.
  도구 승인의 `Auto`와 Gate의 `Auto_judge`도 다른 값이다.
  → [Keeper_tool_approval_mode](../../lib/keeper/keeper_tool_approval_mode.mli)

**HITL Delivery Occasion (HITL 전달 계기)**
: 승인된 HITL 결정을 Keeper 에게 전달할 때, 그 전달이 왜 일어나는지를 가리키는 닫힌 세 값
  (`Keeper_approval_queue.delivery_occasion`). `First_commit` 은 운영자가 결정을 처음
  커밋한 경우, `Boot_replay` 는 아직 소비되지 않은 전달을 부팅 때 다시 하는 경우,
  `Same_request_resubmitted` 는 운영자가 같은 요청을 다시 낸 경우다.
  승인 원장의 `Resolved` 행과 SSE `resolved` 는 계기와 상관없이 결정이 저널에 적힐 때
  한 번 나간다. 전달보다 먼저라서 첫 전달이 실패해도 결정은 원장에 있다.
  계기는 전달만 가른다. `Boot_replay` 와 `Same_request_resubmitted` 는 wake 를 다시 보내고
  `hitl resolution redelivered approval=… occasion=…` 로그를 남길 뿐 행을 적지 않는다.
  채팅의 결정 행은 wake 가 살아 있는 Keeper 에게 닿을 때 한 번만 적힌다.
  → [Keeper_approval_queue.delivery_occasion](../../lib/keeper/keeper_approval_queue.ml)

**Approval Queue Phase (승인 큐 진행 단계)**
: Human-in-the-Loop (HITL) 승인 큐에서 각 승인 요청 항목이 거치고 있는 진행 단계를
  서버가 단일 wire 문자열로 투영한 닫힌 네 값(`approval_queue_phase`: `Phase_queued` ·
  `Phase_judging` · `Phase_human_required` · `Phase_blocked`). TUI와 웹 대시보드가
  개별적으로 수행하던 취약하고 중복된 4문자열 휴리스틱 매칭을 대체하고, 서버
  SSE/REST 엔드포인트(`pending_entry`, `hitl_rows`)가 직접 방출한다(#38404). wire 값은
  각각 `"queued"` · `"judging"` · `"human_required"` · `"blocked"`다.
  - `blocked`: 준비 단계 워커 부재(`Summary_attempt_pre_worker_unavailable`),
    식별자 언바운드(`Summary_attempt_identity_unbound`), 지속성 불확실
    (`Summary_attempt_persistence_uncertain`), 심판 실행 실패(`Summary_failed`)인 경우.
    특히 `Summary_pre_worker_start_reserved` 상태는 초기 폴링 중 대시보드와 서버가
    `judging`이 아닌 `blocked`로 투영하여 불필요한 대기 혼선을 막는다.
  - `judging`: 자동 심판 워커가 실행 중(`Summary_attempt_in_flight`)이거나 요약 대기
    (`Summary_pending`)인 경우.
  - `human_required`: 모델 심판 결과 명시적인 사람 개입이 필요하다고 판정된 경우
    (`advisory_judgment = Require_human`).
  - `queued`: 심판 전 대기 중(`Summary_attempt_ready`)이며 아직 심판이 요청되지
    않았거나(`Summary_not_requested`) 모델 판정(`Approve` | `Deny`)이 대기 중인 경우.
  - **비영속 투영 경계**: 승인 큐의 durable 저널 직렬화(`pending_entry_to_yojson` /
    `pending_entry_of_yojson`)에는 파생값인 `phase` 필드를 저장하지 않고, 오직
    클라이언트 관측을 위한 wire 프로젝션에서만 유지한다.
  → [keeper_approval_queue_rules_types](../../lib/keeper_contract/keeper_approval_queue_rules_types.mli),
  [Keeper_approval_queue](../../lib/keeper/keeper_approval_queue.mli)

**Late Tool Approval (늦은 도구 승인)**
: Human-in-the-Loop (HITL) 실시간 대기(`await`)가 만료(타임아웃, `keeper_tool_approval_timeout_sec`: 180초)된
  뒤 뒤늦게 도착한 운영자의 답변을 보존하는 인메모리 저장소(`Keeper_late_approval`). 키퍼가 다음 턴에 동일한
  호출을 재시도할 때 같은 질문을 두 번 묻지 않고 늦은 답변으로 1회 해결한다.
  - **동일 호출 엄격 매칭**: `(keeper_name, tool_name, canonical_args_fingerprint)`가 정확히 일치하는
    호출에만 매칭된다. 인자가 조금이라도 다르면 매칭되지 않고 다시 묻는다.
  - **1회성 소비(Single-use)**: 한 번 매칭(`take`)되면 메모리에서 즉시 제거된다. 운영자는 해당 단일 호출을
    승인한 것이지, 동일한 형태를 지닌 모든 후속 호출을 영구 승인한 것이 아니다.
  - **유효 시간 제한(TTL, 900초)**: 실시간 대기 창(180초)을 지나 도착한 결정은 최대 900초(15분) 동안만
    유효하며, 초과된 항목은 다음 조회 시 회수(`reap`)되어 부재(`None`) 처리된다. 인간의 결정이 영구적인
    호출 자격 증명으로 오남용되지 않도록 안전 상한을 둔다.
  - **인증된 행위자 기록**: HTTP 경계에서 인증된 호출자(`actor`)를 필수 인자로 받아 기록하며, 클라이언트가
    요청 본문으로 자체 보고하는 `actor_id`는 신뢰하지 않는다(#38038·#38230).
  - **거부 결정 대칭 보존**: 승인(`Approve`)뿐 아니라 거부(`Deny`) 결정도 동일하게 기억하여 불필요한 재질문을
    방지한다. 키퍼가 실제로 재시도하지 않은 호출은 자동 실행되지 않으며, 유효 시간 경과 시 안전하게 폐기된다.
  - **판정 결과 상태**: `remember_outcome`은 `Remembered of { tool_name : string }` 또는 `No_matching_ask`로
    나뉜다.
  - **Yolo 모드 안전 불변식**: 키퍼가 `Yolo` 스탠스로 전환된 동안에는 승인 게이트를 묻지도 소비하지도 않아
    항목이 쌓일 수 있으나, TTL 검사 덕분에 이전 결정이 스탠스 복귀 후 임의로 발화하지 않고 만료 폐기된다.
  → [Keeper_late_approval](../../lib/keeper/keeper_late_approval.mli)

## Task Lifecycle

**Created By**
: Task 를 만든 에이전트나 사람의 이름(`created_by`). 만들 때 한 번 적히고 바뀌지 않는다.
  Keeper 는 자기가 만든 `Todo` 를 자동 claim 대상에서 뺀다.

**Assignee**
: `Claimed`, `InProgress`, `AwaitingVerification` 에 적힌 에이전트 이름. 앞의 둘에서는
  지금 일을 맡은 쪽이고, `AwaitingVerification` 에서는 제출한 쪽이다.

**Producer**
: 판정 쪽 코드가 제출한 에이전트를 부르는 이름. Task 레코드에서는
  `AwaitingVerification.assignee`에 적힌다(→ Assignee). 반려 기록
  (`pending_completion_rejection`)에는 `producer`로 적힌다. verification 레코드의 외부
  스키마 키 `worker`는 Task 소유권이나 관계를 찾는 데 쓰지 않는다.
  → [Types_core](../../lib/types/types_core.mli)

**Claim**
: `Todo` 인 Task 를 맡는 전이. 한 에이전트는 `Claimed` 와 `InProgress` 를 합쳐 하나만
  가질 수 있고, 이 검사는 claim 할 때만 한다. Keeper 의 claim 은 곧바로 Start 를 이어
  보낸다.
  **다른 뜻**: Memory 쪽의 `claim`은 전이가 아니라 Fact의 문장 필드다(→ Fact).
  "새 claim"은 Librarian이 새로 적자고 낸 Fact를 말한다.

**Release**
: 맡은 쪽이 Task 를 `Todo` 로 돌려놓는 전이. Handoff Context 를 남긴다.

**Submission**
: 맡은 쪽이 증거와 함께 완료를 내는 전이(`Submit_for_verification`). 상태는
  `AwaitingVerification` 이 되고 새 Verification ID 를 받는다. 판정을 기다리는 Task 는
  claim 한도에 세지 않는다. Producer 는 기다리는 중에 다시 낼 수 있고 그때마다 id 가
  바뀐다.

**Verification Intent (검증 의도)**
: 제출이 판정자에게 요청하는 종류의 닫힌 두 값(`Types_core.verification_intent`). wire
  이름은 `complete`(`Complete_task`)와 `cancel`(`Cancel_task`)이고,
  `verification_intent_of_string`은 다른 이름을 어느 쪽으로도 기본값 처리하지 않고
  거절한다. 완료 제출과 취소 요청은 같은 대기열에서 같은 판정자를 기다리므로, 대시보드
  검증 대기열 행은 자기가 어느 쪽을 기다리는지 이 값으로 밝힌다. 어느 쪽이든 승인·반려는
  Verdict 가 정한다.
  → [Types_core](../../lib/types/types_core.mli)

**Verification ID**
: 제출 하나의 식별자. 판정은 자기가 읽은 id 가 지금 id 와 같을 때만 적용된다.
  운영자 판정(`POST /api/v1/verification/verdict`)은 읽은 `verification_id`를
  필수로 요구하며, 백로그 잠금 아래에서 지금 id와 다르면
  `Task_error.VerificationSuperseded`(HTTP 409)로 거절된다. 판정자가 증거를
  읽는 사이에 Producer가 재제출하거나 취소 요청으로 제출을 교체한 경우, 낡은
  판정이 새 제출에 붙는 것을 막는다.

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

**Evidence Reference (증거 참조)**
: 관찰·검증·제출·상태 전환에 다는 근거. `evidence_refs` 같은 필드로 나른다.
  검증 저장소가 읽는 형식은 `artifact:`, `note:`, `board:`, `fusion:` 넷이다.
  `note:<text>`는 허용된 서술형 근거다. Task 전이에 붙이는 `handoff_context.evidence_refs`는
  이 넷만 받고, 다른 형식이 하나라도 있으면 전이를 거절한다. Task 인계 요약과 완료 메모도
  이 형식으로 바뀌어 붙는다. `note:` 근거는 파일이나 Board 글, Fusion 실행이 실제로
  있다는 증명이 아니다. 다른 곳의 `evidence_refs`는 각자 규칙을 따른다. 예를 들어
  운영자 판정(`Operator_judgment`)은 앞뒤 공백을 자르고 빈 줄만 버릴 뿐 형식은 보지 않는다.
  → [Workspace_verification_store](../../lib/workspace/workspace_verification_store.ml),
  [Workspace_task_verification](../../lib/workspace/workspace_task_verification.ml),
  [Tool_task_completion_review](../../lib/task/tool_task_completion_review.mli)

**Operator Attention**
: 운영자만 풀 수 있는 Task 의 목록(`Operator_task_attention.item`). 종류는 `Cancel_claim`,
  `Held_without_actor`, `Producer_record_unreadable` 이다.
  **다른 뜻**: attention이라는 말은 세 곳이 더 쓴다. **Board Attention Candidate**는
  Keeper가 반응할지 판정할 게시물이다. Dashboard 브리핑의 attention 항목
  (`Dashboard_attention.attention_item`)과 TUI 개요 화면의 attention 항목
  (`attention_item`)은 운영자가 먼저 봐야 할 사고·경고 줄이다. 이 목록은 그 줄의
  재료 중 하나일 뿐이다.
  → [Operator_task_attention](../../lib/operator_task_attention.mli),
  [Dashboard_attention](../../lib/dashboard/dashboard_attention.mli)

**Current Task**
: 에이전트 기록의 `current_task`, Keeper meta 의 `current_task_id`, planning 의 current
  task. 기준은 backlog 이고 이 셋은 거기서 다시 계산되는 표시다.

## Skills

**Skill**
: 선언된 source의 `<package>/SKILL.md`로 발행하는 재사용 지식 또는 도구 합성.
  출처·패키지·이름·문서 revision으로 식별한다.
  Memory OS의 Fact와 별개다. `validated_approach`나 `lesson`을 기억했다고 Skill이
  생성되지는 않는다. 현재 발행·사용 경로는 [Skills](../SKILLS.md)를 따른다.
  `keeper_skill_validate`는 export한 문서를 정적 검증(`validation = "static"`)하며,
  실행 성공·안전성·발행을 뜻하지 않는다. 검증 판정은 정규화된 아티팩트 참조(`artifact`)가
  아니라 검증기가 읽은 실제 바이트에서 직접 계산한 다이제스트(`source {sha256, bytes, filename}`)로
  대상을 지칭한다 — 정규화된 아티팩트 참조가 결과에 실리면 durable result manifest 부재로
  인해 `tool output artifact storage failed`로 실패하거나 빈 미리보기 blob으로 치환되기
  때문이다(#37493·#38514). 입력과 발행 경계도 위 [Skills](../SKILLS.md) 문서를 따른다.
  `keeper_skill_publish`는 Keeper가 `project-agents` source에 새 Skill을 만들고
  바로 발행하는 도구다. 이미 있는 이름은 덮어쓰지 않고, 지우는 건 운영자가 한다.
  → [Keeper_skill_catalog](../../lib/keeper/keeper_skill_catalog.mli),
  [Skill_reference](../../lib/skill_reference/skill_reference.mli)

**Skill Source**
: `runtime.toml`의 `[[skills.sources]]`에 선언되어 Skill 패키지를 탐색·적재하는 디렉터리
  경로 SSOT(`Skill_source_config.t`). 각 소스는 고유 식별자(`id`), 기준점(`anchor` —
  `Base_path`·`User_home`·`Absolute`), 설정 경로(`configured_path`), 접근 권한
  (`access` — `Read_only`·`Read_write`)을 소유한다. 소스 탐색과 읽기 작업은
  `Skill_catalog_snapshot.source_operation`(`Inspect_source`·`Read_source_directory`)이
  관찰한다.
  - **준비 거절 사유 (`source_not_ready`)**: `keeper_skill_publish` 또는 Skill 에디터가
    소스 폴더 결함이나 미선언으로 요청을 수행할 수 없을 때 단순 오류 문자열이 아니라
    닫힌 열 가지 variant(`Server_skill_editor.source_not_ready`)와 해결된 경로를 구조화된
    `reason` 객체로 반환한다 —
    1. `Source_not_in_catalog` (`runtime.toml`에 소스 ID 미선언)
    2. `Source_index_out_of_range` (스냅샷 범위를 벗어난 소스 인덱스)
    3. `Source_root_missing` (해결된 디렉터리 경로 부재)
    4. `Source_root_not_directory` (해당 경로가 디렉터리가 아님)
    5. `Source_root_unavailable` (소스 디렉터리 검사/읽기 작업 실패)
    6. `Source_root_unresolved` (`Skill_source_config.resolution` — 앵커 가용 불가, 잘못된 앵커, 잘못된 경로로 인한 해석 실패)
    7. `Source_root_create_failed` (누락된 선언 폴더 자동 생성 실패)
    8. `Source_root_refresh_failed` (폴더 생성 후 카탈로그 갱신 실패)
    9. `Source_root_moved` (쓰기 락 획득 도중 소스 경로 변경)
    10. `Recovery_directory_missing` (복구 디렉터리 부재)
    누락된 폴더(`Source_root_missing`)로 인한 거절을 미선언(`Source_not_in_catalog`)으로
    오진하여 `runtime.toml` 설정을 의심하거나 운영자에게 불필요한 질의(`masc_ask`)를 남기지
    않아야 한다(#38381).
  → [Skill_source_config](../../lib/skill_config/skill_source_config.mli),
  [Server_skill_editor](../../lib/server/server_skill_editor.mli)

**Skill Deletion (Skill 삭제)**
: 선언된 소스에서 Skill 패키지를 제거하고 복구 격리소로 이동하는 절차(`Server_skill_editor.delete`).
  단순 파일 삭제가 아니라 격리 검증·패키지 폴더 처분·스냅샷 갱신(`delete_outcome`)의 세 단계를
  거치며, 발행 여부에 따라 `Deleted_and_published`와 `Deleted_but_unpublished`로 나뉜다.
  - **SKILL.md 격리 (`recovery_id`)**: 원본 `SKILL.md`는 삭제되지 않고 고유 복구 식별자(`recovery_id`)가
    부여된 격리 디렉터리로 이동(`recovery_disposition`)되어 비상 복구 가능성을 보존한다.
  - **패키지 폴더 처분 (`package_directory`)**: `SKILL.md` 이동 후 남겨진 패키지 폴더를 닫힌 네 가지
    상태로 판정하여 처리한다(#38594·#38616). 과거에는 빈 폴더를 방치하여 동일한 패키지 ID로
    재생성할 때 영구히 `Package_already_exists` 거절을 받는 결함이 있었다.
    1. `Package_directory_removed` (wire: `{"kind": "removed"}`): 빈 패키지 폴더가 `rmdir`로 완전히
       제거되어 동일한 ID로 새 Skill 생성이 즉시 가능함.
    2. `Package_directory_kept_non_empty` (wire: `{"kind": "kept_non_empty"}`): 폴더 내에 부속
       파일(예: `references/`, `scripts/` 등)이 남아 있어 패키지 폴더를 그대로 보존함.
    3. `Package_directory_removed_unsynced of string` (wire: `{"kind": "removed_unsynced", "detail": "..."}`):
       폴더는 지웠으나 상위 디렉터리 동기화(`fsync`)에 실패하여 비정상 종료 시 폴더가 복원될 수 있음.
    4. `Package_directory_remove_failed of string` (wire: `{"kind": "remove_failed", "detail": "..."}`):
       폴더 삭제(`rmdir`) 작업 자체가 시스템 오류로 실패함.
  → [Server_skill_editor](../../lib/server/server_skill_editor.mli)

**Instruction Skill**
: Keeper가 `keeper_skill`로 본문과 참조 파일을 읽고 적용할 방법을 판단하는 Skill.
  본문을 읽었다는 사실은 그 절차를 실행했거나 성공했다는 증거가 아니다.
  선택적으로 제공되는 JEV 적용 가능성 의견도 권한·실행·성공의 증거가 아니다.

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

**Skill State (Skill 상태)**
: 로그가 Skill 행 하나에 적는 닫힌 여덟 값(`Masc_tui_keeper_chat_transcript.skill_state`).
  `keeper_skill` 호출이 성공했다는 사실은 본문이 실렸다는 뜻일 뿐, 제공자가 그것을
  받았거나(delivered) 이후 도구가 그 Skill을 썼다는(used) 뜻이 아니다 — 그래서 상태가
  그 셋을 나눠 적는다. 생애 순서는 `Skill_calling` → `Skill_served_pending` →
  `Skill_served_only` → `Skill_delivered` → `Skill_used` 이고, 나머지 셋(`Skill_failed`·
  `Skill_evidence_missing`·`Skill_evidence_unavailable`)은 그 생애의 걸음이 아니라 증거가
  실패·부재·형식 불일치인 경우를 말한다. Instruction Skill 은 읽고 Composition Skill 은
  자기 이름의 도구로 실행하므로, 앞 세 상태의 문구가 "읽음"과 "실행됨"으로 갈린다.
  → [Masc_tui_keeper_chat_transcript](../../bin/masc_tui_keeper_chat_transcript.mli)

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

**Sandbox Target (샌드박스 실행 타깃)**
: Keeper의 `Execute` 도구가 명령을 격리 실행하는 환경 추상화(`Sandbox_target.t`).
  `Host`·`Docker`·`Micro_vm`·`Ssh`·`Delegated`의 닫힌 variant로 표현된다. 각 타깃은
  명령의 표준 입출력과 종료 상태를 `run_outcome`(`Ran`·`Transport_failed`)으로
  전달하여, 원격 런타임 전송 장애와 명령의 자체 실패를 명확히 분리한다.
  호출 페이로드는 `argv`(셸 없이 그대로 실행하는 프로세스 벡터)와 `command`(셸에
  넘기는 한 줄) 중 정확히 하나만 받는다.
  → [config/tools/tool_execute.toml](../../config/tools/tool_execute.toml)

**Endpoint Allowed Paths (엔드포인트 허용 경로)**
: SSH 샌드박스 타깃(`Sandbox_target.Ssh`, `Exec_ssh_endpoint.t`)에서 명령이 접근할 수 있는
  추가 루트 경로 목록(`allowed_paths`).
  - **격리 기본값**: 기본 실행 정책(`Exec_policy_paths.validate_path`)은 Keeper 작업
    디렉터리(`workdir`)와 `/tmp` 외의 경로 접근을 정적 스크립트 검사에서 엄격히 거절한다.
  - **추가 루트 선언**: Terminal-Bench 등 외부 벤치마크/엔드포인트 환경(예: `/app`)을
    지원하기 위해 `runtime.toml`의 `[exec.ssh.endpoints.<name>] allowed_paths = ["/app", ...]`로
    추가 허용 루트를 선언할 수 있다(#38603).
  - **설정 불변식**: 선언 경로는 반드시 절대 경로이자 정규화된(normalized) 경로여야 하며,
    루트(`/`)는 거절된다(`Exec_ssh_endpoint.parse_toml`).
  - **어휘 비교 경계**: 엔드포인트가 원격 머신일 수 있으므로 호스트 파일시스템의 심볼릭
    링크를 해석하지 않고 순수 어휘(lexical prefix)로만 비교한다. 그래서 추가 루트 아래에서
    밖을 가리키는 심볼릭 링크는 이 검사가 막지 못한다. 엔드포인트가 이 머신이면 추가 루트는 링크를
    풀어 보는 작업 디렉터리(`workdir`)보다 느슨하고, 실제 경계는 엔드포인트 계정의 권한이다. 기본값은 빈 목록(`[]`)이다.
  - **읽기 확장**: #38631 부터 `Read`와 읽기 전용 검색은 이 선언 루트를 Execute 가 이름 짓는
    방식과 같이 엔드포인트 자기 경로로 읽는다(`Keeper_sandbox_remote_lane.declared_endpoint_path`).
    판정 순서는 **자기 트리 먼저** — Keeper 작업 디렉터리 안 경로는 그 뜻을 그대로 두고, 그 밖에서
    거절된 절대 경로만 선언 루트와 대조한다. Docker·MicroVM Keeper는 루트를 선언하지 않으므로
    언제나 `None`이다. 엔드포인트 경로(`Declared_endpoint_file`)인데 이 Keeper 의 읽기가 원격 레인을
    타지 않으면 `declared_endpoint_path_needs_remote_lane: …` 오류 문장으로 거절한다. 쓰기는 여전히 Keeper 의
    playground 안에만 머문다.
  → [Sandbox_target](../../lib/exec/sandbox_target.mli),
  [Exec_policy_paths](../../lib/exec_policy/exec_policy_paths.mli),
  [Exec_ssh_endpoint](../../lib/runtime/exec_ssh_endpoint.mli),
  [Keeper_sandbox_remote_lane](../../lib/keeper/keeper_sandbox_remote_lane.mli)

**Worktree**
: 한 repository 안에서 branch 작업을 격리하는 Git worktree.

**Repository Status (저장소 상태)**
: Workspace가 추적하는 repository 하나의 상태. `Repo_manager_types.repository_status`가
  닫힌 어휘를 소유한다 — `Active`·`Paused`·`Cloning`·`Error of string`. wire 단어는
  `status_wire_name` 한 표가 정하고(`active`·`paused`·`cloning`·`error`), `Error`는
  사유 문자열을 함께 나른다(`status_error_message`). 읽는 쪽은
  `status_of_wire_name`으로 되돌리며, 이 빌드가 모르는 단어와 사유 없는 `error`는
  `None`이다(TUI는 `Unrecognised_repository_status`로 그대로 보존한다). Workspace
  표면은 상태 칸에 단어만 그리고, 사유는 선택 행의 context에 Path·Keepers 아래로
  그린다.
  → [Repo_manager_types](../../lib/repo_manager/repo_manager_types.mli),
  [Tui_decode](../../lib/tui_decode.mli)

**PR Reader (PR 읽기 Keeper)**
: 서버가 등록된 GitHub 저장소의 열린 PR 을 읽을 때 쓰는 GitHub 토큰의 주인 Keeper.
  runtime.toml `[repositories] pr_reader = "<keeper>"` 로 선언한다. 토큰은 그 Keeper 의
  `github-cli/hosts.yml` 에서 읽을 때마다 새로 읽고 복사해 두지 않는다. 선언이 없거나
  runtime.toml 을 못 읽거나 `pr_reader` 가 Keeper 이름이 아니거나 Keeper 가 없거나
  토큰이 없으면 서버는 그 이유(`Reader_not_declared`·`Reader_declaration_invalid`·
  `Reader_keeper_missing`·`Reader_token_unavailable`)를 말하고, 다른 자격으로 대신
  읽지 않는다. 결과는 메모리에만 두고 `GET /api/v1/repositories/pulls` 로 보인다
  (RFC-0465).
  → [Server_repository_pulls](../../lib/server/server_repository_pulls.mli)

**PR Attribution (PR 귀속)**
: 열린 GitHub Pull Request를 작업한 Keeper와 잇는 표시 규칙(RFC-0465).
  `GET /api/v1/repositories/pulls`가 PR의 `author`(머지 커밋을 건너뛴 최신 단일
  부모 커밋의 작성자 이름, #38277)와 저장된 Keeper 이름 목록(`Keepers_listed`)을 대조해
  일치하는 Keeper에게 귀속한다(`keeper`). 샌드박스 런타임은 실행 환경의
  `GIT_AUTHOR_NAME`과 `GIT_COMMITTER_NAME`에 그 Keeper 이름을 넣어 커밋에
  작성자가 남도록 보장한다(#38253). Keeper 목록 조회가 실패하면(`Keepers_list_failed`)
  PR을 일반(비-Keeper) PR로 오인하지 않고 목록 전체를 미결정으로 둔다. 이 귀속은
  TUI와 대시보드의 표시 전용(display only)이며, 커미터가 작성자 이름을 임의
  지정할 수 있으므로 권한(authority)이나 실행 증명으로 삼지 않는다.
  → [Server_repository_pulls](../../lib/server/server_repository_pulls.mli)

**Disposable Build Volume (일회용 빌드 볼륨)**
: Apple container 샌드박스에서 Keeper의 `_build` 출력이 놓이는, Keeper마다 하나씩
  할당되는 일회용(disposable) 볼륨(RFC-keeper-build-output-returns-to-a-disposable-volume,
  #38563 착지). 체크아웃이 놓이는 work volume(`work_volume_guest_root`)과 분리된
  `/masc-build`(`build_volume_guest_root`)에 마운트된다. 일회용이라는 말 그대로
  게스트를 재시작할 때마다 `recreate_apple_build_volume`가 지우고 새로 만들어 빈
  상태로 시작하므로, 매번 콜드 빌드 한 번을 치르는 대신 재시작 사이에 쌓인 빌드
  산출물이 다음 세션으로 새지 않는다. `container volume create`는 멱등이 아니므로
  존재 여부를 probe로 가리고, probe 결과가 애매하면 추측으로 지우지 않고 거절한다.
  → [Keeper_sandbox_microvm](../../lib/keeper/keeper_sandbox_microvm.mli)

## Continuity

**Autoboot Exclusion Reason (자동 부팅 제외 이유)**
: 설정상 부팅 가능한데도 `bootable_keeper_names`에서 의도적으로 빠진 Keeper의
  닫힌 이유. `Paused`·`Declarative_autoboot_disabled`·`Autoboot_disabled`·
  `Shutdown_admission_fence` 넷이다. 앞의 셋은 Keeper 설정에서 유도되지만
  `Shutdown_admission_fence`는 아니다 — durable shutdown operation이 아직 그
  Keeper의 admission을 소유하고 있어, autoboot 호출자가 boot-scan shutdown
  inventory(`blocked_keeper_names`)를 들고 표시한다. boot recovery가 회수
  가능한 operation을 같은 bootstrap에서 정산하면 supervisor의 주기 pass가 그
  Keeper를 등록한다. 배제된 Keeper는 이 이유와 함께 excluded list에 찍는다.
  → [keeper_runtime.mli](../../lib/keeper/keeper_runtime.mli)

**Shutdown Admission Fence (종료 진입 차단막)**
: 종료 작업 진행 중인 Keeper의 재부팅을 막아 원장 정합성을 지키는 진입 차단 술어(`Keeper_shutdown_types.requires_admission_fence`).
  - **단계별 차단막 해제 규칙 (#31738·#38569·#38859)**: 과거에는 `Blocked` 상태의 종료 작업에 대해 실패 단계와
    무관하게 차단막을 영구 유지하여, 영속 상태가 전혀 파괴되지 않은 Keeper도 수동 교체(`Superseded`) 없이는
    영구히 재부팅할 수 없는 결함이 있었다. 현재는 실패 단계(`failure_stage`)를 `failure_stage_boot_replay`로
    분류한다:
    1. **부팅 재실행 대상 (부팅 사이에는 차단막 없음)**: 메타데이터·세션·레지스트리를 건드리기 전의 단계.
       `Task_discovery`·`Record_persist`·`Meta_read`는 `Replay_unsettled_tasks`(이 작업의 반환 영수증이 있는
       태스크만 정산된 것으로 보고 나머지를 정산), `Meta_update`·`Pending_confirm_cleanup`은
       `Replay_settled_tasks`(태스크 정산이 끝난 뒤에만 나오므로 모든 소유 태스크를 정산된 것으로 보고 재개).
    2. **유지 대상 (`fenced`, 차단막 유지)**: 키퍼의 영속 상태(태스크 소유권, 레인, 메타데이터, 세션, 레지스트리)가
       반쯤 철거된 단계(`Turn_cancel`·`Lane_cancel`·`Turn_join`·`Lane_join`·`Record_update`·`Unhandled_worker`·
       `Task_settlement`·`Approval_summary_retirement`·`Meta_remove`·`Session_remove`·`Registry_unregister`).
  - **부팅 재실행**: 부팅 복구는 재실행 대상 `Blocked` 레코드가 그 Keeper의 가장 새 작업이고 차단막을 잡은 형제가
    없으면 차단막을 세우고 `Finalizing_tasks`에서 다시 실행해 운영자 의도(stop·purge 등)를 끝낸다. 더 새 작업이
    있거나(`Newer_operation`), Keeper trace가 바뀌었거나(`Keeper_trace_changed`), 스냅숏에 없는 태스크를
    잡았으면(`Keeper_claimed_new_tasks`) 재실행하지 않고 `Superseded (Boot_replay_abandoned _)`로 닫은 뒤 WARN을
    남기고 회수한다. 소유자·메타데이터·backlog를 지금 읽을 수 없거나 재실행이 다시 재실행 대상 단계에서 막히면
    새 증거로 `Blocked`에 남기고 WARN을 남긴 뒤 차단막을 풀어 Keeper가 부팅하게 하고, 다음 부팅에 다시 시도한다.
  → [Keeper_shutdown_types](../../lib/keeper/keeper_shutdown_types.mli)

**Boot Meta Failure Cause (부팅 메타 실패 사유)**
: Keeper 기동 및 구체화(materialization) 시점에 메타데이터 검증 실패를 표현하는 닫힌 구조화 사유(`Keeper_runtime.boot_meta_failure_cause`).
  - 닫힌 다섯 가지 variant:
    1. `Meta_read_error`: 메타데이터 파일 읽기 또는 디코딩 실패.
    2. `Config_invalid`: TOML 파싱 또는 유효성 검사 실패.
    3. `Sandbox_profile_required`: 선언형 키퍼 프로필에 필수 `sandbox_profile` 누락.
    4. `Sandbox_image_required`: 컨테이너 실행 프로필(`docker`·`microvm`)에 `sandbox_image` 누락 또는 공백(#37523·#38572). `remote_ssh`는 이미지를 쓰지 않으므로 요구되지 않음. 부팅 조정(`reconcile`)과 `keeper_up` 생성 파싱 양쪽에서 `Keeper_meta_contract.missing_required_sandbox_image_error` 공통 규칙으로 즉시 거절.
    5. `Materialization_failed`: 파일시스템 또는 디렉터리 구조 구체화 실패.
  → [keeper_runtime](../../lib/keeper/keeper_runtime.mli),
  [Keeper_meta_contract](../../lib/keeper/keeper_meta_contract.mli)

**Checkpoint**
: History와 설정을 담은 Agent Core의 durable 저장점. trace당 파일 하나
  (`<trace 디렉터리>/<trace id>.json`)다. 실행 중에는
  `Keeper_types.working_context`가 이 checkpoint 하나를 감싼다.
  공식 클라이언트의 대화 이력은 이 파일에 옮겨 저장하지 않는다. MASC는
  클라이언트 세션 식별자와 turn 진행 상태를 별도의
  [공식 클라이언트 세션 저장소](../../lib/keeper/keeper_official_client_session_store.mli)에
  기록한다.
  → [Keeper_types.working_context](../../lib/keeper_types/keeper_types.mli)
  이 저장점은 **Checkpoint Load**(위 Core 항목)가 읽고, **Checkpoint Purge**(아래
  항목)가 LLM 없이 재작성한다.

**Store Boot Policy (영속 store 부팅 정책)**
: durable per-keeper store가 이번 빌드로 디코딩되지 않을 때 부팅이 어떻게
  행동할지를 store 타입이 짊어지는 닫힌 분류
  (`Keeper_store_boot_reconcile`의 `refuse_boot`·`degrade_typed`,
  RFC-0420·RFC-0444 §2.4). `Refuse_boot`(keeper meta·current Memory OS snapshot):
  없으면 Keeper가 다른 Keeper로, 또는 빈 기억으로 뜨고 잃은 것을 덮어쓰므로
  부팅을 거절한다. `Degrade_typed`(goal store): 모든 쓰는 쪽이 못 읽는 store를
  거절하고 어떤 읽는 쪽도 빈 목록으로 바꾸지 않으므로, Keeper는 task·board·
  schedule로 돌고 파일은 아무것도 덮어쓰지 않는다 — `examine`이 읽고 못 읽으면
  INFO 한 줄만 남긴다. 절차는 `examine`(읽기만, 파일 생성·이름변경 없음) →
  `admit`(부팅 진행 여부) → `quarantine`(운영자가
  `--accept-store-quarantine`로 받아들인 뒤에만 옆으로 옮김) 순서다.
  새 store 생성자는 컴파일러가 정책을 묻게 한다. **경계**: Board 판정의
  `Quarantined`(Board Attention Quarantine)와 이름이 겹치지만 다른 층위다 —
  여기서 격리는 부팅 단계에서 store 파일을 옆으로 옮기는 운영자 결정이다.
  → [Keeper_store_boot_reconcile](../../lib/keeper/keeper_store_boot_reconcile.mli)

**Checkpoint Purge (체크포인트 청소)**
: 멈춘 Keeper의 canonical AGENT_CORE checkpoint를 LLM 없이 두 닫힌 규칙으로 줄이는
  운영자 작업(RFC-0351 S1). 둘 다 atom을 여는 message는 지우지 않는다. 추론 제거는
  assistant message의 서명 없는 `Thinking`·`ReasoningDetails` 블록을 지우되, 지우면
  빈 message가 되는 것은 그대로 둔다. tool 결과 비우기는 닫힌 tool cycle의 `ToolResult`
  내용을 고정 표시로 바꾸되, 실패한 결과(`Tool_failed`)는 예외로 바이트 그대로 남긴다 —
  그 payload가 다음 turn에 Keeper가 읽는 피드백이고 durable 이력이 가진 유일한 오류
  증거다. tool protocol cycle은 쪼개거나 순서를 바꾸지 않고, 마지막
  `keep_recent_messages`개와 구조적으로 보호된 꼬리는 바이트 그대로 남긴다. `messages`
  밖의 필드는 바뀌지 않아 같은 watermark 재저장으로 받아들여진다. Dashboard의
  "정리 미리보기"는 읽기 전용이고, "백업 후 청소"는 원본을 바이트 그대로 백업한 뒤
  저장하며 Keeper가 등록돼 있으면 쓸 수 없다. CLI `masc-checkpoint-purge`는 기본이
  dry-run이고 `--apply`가 백업 후 저장한다.

  atom을 여는 message를 지우지 않으므로 atom 번호는 그대로다. atom으로 자리를 세는
  저장소 넷(turn-boundary 로그, Librarian 위치, continuity 스냅숏, carried-front 씨앗)이
  같은 이력을 계속 가리키도록, 기록이 지목하는 message는 바이트 그대로 남긴다 — 마지막
  atom과 꼬리, 각 완료 turn이 끝난 atom의 여는 message(`Turn_ended` 줄이 지목), 이
  이력에 맞는 Librarian 작업 상태가 덮는 앞부분. `purge_messages`가 atom 수·남긴 여는
  message의 digest·작업 상태를 `Librarian_continuity_snapshot.restore`로 대조하고, 어긋나면
  이력을 돌려주지 않고 오류를 낸다. carried-front 씨앗은 남기지 않는다 — purge가 그
  atom의 여는 message를 다시 썼으면 씨앗이 안 맞아 요청은 마지막 완료 turn이 끝난 자리에서
  시작한다. 구조적으로 깨진 입력의 복구는 깨진 꼬리를 버리므로 끝이 옮겨지는 것이
  설계다. 복구가 Librarian 위치를 옮길 때는 `witness_line`이 확인한 마지막 turn
  끝에서 이력을 끝내고, 그런 줄이 없으면 `Recovery_end_unwitnessed`로 거절한다.
  위치가 없거나 rebase가 위치를 거절하면 깨진 곳에서 끝낸다.

  Librarian의 atom 위치(`librarian_rebase`)는 sound transcript면 그대로 돌려받고, 깨진
  transcript 복구에서만 새 끝으로 옮긴다. 어느 쪽이든 Librarian이 아직 읽을 atom을
  남겼으면 재작성을 거부한다. continuity 스냅숏(`librarian-continuity.json`)은 지우지
  않는다 — 스냅숏이 덮는 앞부분을 바이트 그대로 남겨 purge 뒤에도 맞는다. 복구가 그
  부분을 버리면 `Continuity_no_longer_fits`로 거절되고, 서버를 멈춘 채
  `librarian-continuity.json`을 지우면 통과한다. 서버의 dashboard 청소 동작은 그 전에
  Librarian lane을 취소하고 기다린다(`with_librarian_purge`).
  → [Keeper_checkpoint_purge](../../lib/keeper/keeper_checkpoint_purge.mli),
  [Runbook](../CHECKPOINT-PURGE-RUNBOOK.md)

**Transcript Tail Recovery (전사 꼬리 복구)**
: 프로세스가 죽어 열린 채 남은 tool cycle을 부팅 때 닫는 일
  (`Keeper_transcript_tail_recovery.recover_open_tails`). `Recovering_persistence` 부팅
  단계에서 Keeper loop가 시작되기 전에 돈다. checkpoint 저장이 진행 중이던 tool
  cycle을 일부러 남겨 두므로(어느 호출이 dispatch됐는지 복구가 알 수 있게), 아무도
  닫지 않으면 provider가 매 reload마다 history를 거절해 lane이 영영 resume되지
  못한다. Keeper마다 독립이라 하나가 실패해도 나머지 sweep을 멈추지 않는다.
  Keeper별 결과는 닫힌 여섯이다(`keeper_outcome`): `Already_dispatchable`(캐리어
  없음 — 실을 metadata도, 아직 canonical checkpoint도, 열린 꼬리도 없음),
  `Closed`(캐리어 `{tool_use_ids : string list}` — 닫은 호출 id), `Unparseable`
  (캐리어 `Keeper_transcript_unit.structural_error` — 진짜 손상, 열린 꼬리만 복구
  가능), `Meta_unavailable`(캐리어 `string`), `Checkpoint_unavailable`(캐리어
  `Keeper_checkpoint_store.checkpoint_ref_load_error`), `Commit_rejected`(캐리어
  `Keeper_checkpoint_store.checkpoint_cas_error`).
  **경계**: `Checkpoint_unavailable`은 이름이 "checkpoint 없음"으로 읽히지만 실제로는
  checkpoint ref를 **못 읽은** 것이다(load error). checkpoint가 아직 없는 정상 상태는
  `Already_dispatchable`이다 — checkpoint가 없는 것은 실패가 아니다. `Unparseable`도
  실패로 세지 않는다(정당한 거절). `failed`는 metadata·load·commit 실패만 센다.
  → [Keeper_transcript_tail_recovery](../../lib/keeper/keeper_transcript_tail_recovery.mli)

**Working Context (받은 일 정리)**
: Librarian이 Keeper가 아직 처리하지 않은 event·chat 요청을 묶어, 원본 요청에 맥락과
  다음 행동 제안을 붙여 둔 것. 실행 권한도 checkpoint 이력도 아니다. 정리 하나가
  pocket(`Keeper_librarian_context.pocket`)이고, 지금 저장된 pocket 묶음이
  `Keeper_librarian_context.snapshot`의 `pockets`다. Keeper 이름에 묶인다. cluster 사이에서
  무엇을 같이 쓰는지는 **Cluster** 항목에 적었다.
  **다른 뜻**: 코드의 `Keeper_types.working_context`는 이 묶음이 아니라 실행 중인
  Keeper가 쥔 Checkpoint 하나를 감싼 값이다(**Checkpoint** 항목). 이름만 같다.
  `[typesafeai] context_review = true`이면 새 정리 전체의 의미 보존을 JEV Choice로
  평가한다. 원본의 요청·제약·약속과 다음 행동 제안을 함께 보며, 합치는 이전 정리의
  참조 원문도 포함한다. `needs_revision`이면 새 정리의 게시만 보류한다. 미평가·실패·
  `insufficient_evidence`는 검증 통과가 아니며 기존 저장 검사를 유지한다.
  실행 상세의 `context_review`는 판정, `context_write`는 정리 저장 결과다.
  `outcome_unconfirmed`는 저장 도중 중단되어 저장 여부를 확인하지 못한 상태다.
  `answer_missing`·`answer_refused`는 기억 회차의 답이 정리를 빠뜨렸거나 검사에서
  거절돼 그 회차의 정리를 건너뛴 상태다. 같은 답의 Memory 변경은 그대로 저장한다.
  원본 요청 처리·Memory 변경·Checkpoint 저장 결과와 구분한다.
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

**History Fragment (히스토리 조각)**
: official-client turn이 자기 trace 디렉터리에 남긴 줄. 그 turn은 AGENT_CORE
  checkpoint를 저장하지 않으므로, 무슨 말을 했고 어떤 tool을 불렀는지는
  `<session_dir>/history.jsonl`과 `<session_dir>/history.internal.jsonl`에 남는다.
  각 줄은 자기를 쓴 turn(`Turn_ref`)과 종류(`message`|`tool_observation`)를 적는다.
  `Turn_ref` 없는 줄은 `Untagged`로 어느 turn에도 속하지
  않으며 reader는 지나간다. `Turn_ref`가 있는데 decoder가 거부하는 줄은 `Error`이며
  untagged로 읽지 않는다. main 파일을 먼저, internal 파일을 다음으로, 각각 파일 순서로
  읽는다. Checkpoint의 `messages`(History)와 달리 이 줄들은 자기 turn을 안다.
  → [Keeper_turn_fragments](../../lib/keeper/keeper_turn_fragments.mli)

**Message**
: History의 한 항목. role(`System`, `User`, `Assistant`, `Tool`) 하나와 content
  조각의 목록으로 이뤄진다. 조각은 아홉 가지다: `Text`, `Thinking`,
  `ReasoningDetails`, `RedactedThinking`, `ToolUse`, `ToolResult`, `Image`,
  `Document`, `Audio`. 정본은 `packages/agent_core/lib/llm_provider/types.mli`의
  `content_block`이다.

**Input Speaker (입력 화자)**
: Keeper 대화에서 각 `User` message를 누가 발화했는지를 나타내는 메타데이터
  (`agent_core.input_speaker.v1`, `Agent_core.Types.Input_speaker.key`). 메시지가 생성될
  때 고정 스탬프되며, 이후 메시지 본문에서 추론하거나 변경하지 않는다(RFC-0468 §3.2).
  닫힌 타입(`Keeper_input_speaker.t`)은 둘이다 — 외부 주체인 `Person`(`Owner`·`Keeper id`·
  `External {channel; user_id; user_name}`)과 호스트가 작성한 프롬프트인 `Host_prompt`
  (`Autonomous_wake {answered_asks}`·`Official_client_resume`). `Keeper`는 생성 지점에서
  레지스트리와 일치된 등록된 Keeper만 가리키며, 호스트 자율 기상(`Autonomous_wake`)의 답변된
  Ask들은 요청 형태 보존을 위해 단일 메시지에 인용되므로 `answered_asks`가 각 행에 답변한
  사람 목록을 순서대로 나열한다.
  Librarian은 대화 헤더에 `speaker=...`로 렌더링하며, 메타데이터 부재(`Absent`) 시
  `speaker=unknown`, 잘못된 형태(`Invalid`)면 `speaker=invalid(...)`, 중복(`Duplicate`)이면
  `speaker=duplicate`로 표기해 패스를 중단하지 않고 대화를 계속 읽는다.
  이 메타데이터는 LLM provider로 전송되지 않고(`Input_speaker.without`), 공식 클라이언트
  이력 봉투 및 스냅숏 해시에서 제외되며, 승인 입학 다이제스트(`Keeper_approval_input_admission.admission_digest`)
  에서도 제외된다.
  → [Keeper_input_speaker](../../lib/keeper/keeper_input_speaker.mli)

**Atom**
: History를 자를 때 쓰는 가장 작은 단위. `User` message 하나, 또는 `Assistant`
  message 하나와 그것에 답한 `Tool` message들이다. 따로 저장되지 않고 History를
  앞에서부터 세면 나온다(`Runtime_model_input_tail_window`). tool 호출과 결과가
  갈라지면 provider가 요청을 거절하므로 자르는 자리는 Atom 경계에만 온다. Atom의
  크기는 고르지 않아서 Atom 개수는 위치를 말할 뿐 요청 크기를 말하지 않는다.

**Seed (씨앗)**
: 요청에 실리는 범위가 어디서 시작하는지를 그 근거와 함께 적은 값
  (`Keeper_carried_front.seed`). 시작 Atom의 번호(`first_atom`)와 그 Atom을 여는
  Message의 digest(`front_digest`), 그리고 그 위치가 어디서 왔는지(`source`)로
  이뤄진다. `Carried Front`가 흡수 지점(가장 오래된 Atom)이라면 씨앗은 그 범위의
  시작을 정하는 값이다. 프로세스가 (Keeper, runtime) 쌍의 원장을 쥐고 있으면
  위치는 원장의 것이고(`Ledger`), 없으면 — 부팅 뒤 첫 turn이거나 이 runtime의
  첫 turn이면 — 가장 새 turn 기록이 실제 provider 응답과 이어진 범위가 위치가
  된다(`Turn_record`). 거절이 앞을 옮긴 뒤에는 그 이동을 이름으로 남긴다
  (`Halved_after_refusal`·`Evicted_after_refusal`). 씨앗으로 보낸 범위가 거절돼 이번
  턴의 시작부터 다시 보낼 때도 이름을 남긴다(`Turn_start_after_seed_refusal`).
  Seed와 이월된 앞머리를 포함한 범위 구성에서 거절이 앞을 옮기는 것은 크기 때문인 typed 거절
  (`ContextOverflow`·`Request_body_refused_by_provider`)뿐이다. 모델링되지 않은 400/422
  (`Unknown_invalid_request`, 도구 스키마 오류나 지원하지 않는 인자 등)는 오래된
  맥락을 자르거나(evict/halve) 강등하지 않고 받은 그대로 반환하여, 다음 턴이 좁혀진
  앞머리가 아니라 정상 수용된 전체 범위를 구성하게 한다(#38286).
  위치는 번호와 digest의 쌍이라, 손에 든 History가 같은 번호를 같은 Message로
  열 때만 쓴다(`for_history`). History의 Atom 개수는 비교하지 않는다.
  RFC 코퍼스는 이 자리를 **씨앗**이라 부른다.
  **다른 뜻**: `RFC-0457:85·150`의 "씨앗 설정"은 초기 예시 config를 가리키는 다른
  말이다 — 이 항목의 씨앗과 구분한다.
  → [Keeper_carried_front.seed](../../lib/keeper/keeper_carried_front.mli)

**Carried Front (실어 보낼 이력의 시작 위치)**
: 요청에 실리는 가장 오래된 Atom의 번호와 그 Atom을 여는 Message의 digest.
  후보별 usage 원장에서 읽되, 같은 Keeper turn의 거절이 더 뒤로 옮긴 위치가 있으면
  그 위치를 쓴다. 반 자르기와 묶음 비우기 모두 다음 후보로 이 위치를 전달한다.
  다른 History의 위치는 digest가 맞지 않으므로 쓰지 않는다.
  이 위치의 출처(`Keeper_carried_front.origin`)는 여섯이다 — `Carried`(seed에서 온
  위치: 원장, turn 기록, 거절 뒤 반 자르기·묶음 비우기, 씨앗 범위 거절 뒤 turn 경계),
  `Librarian_snapshot`(하던 일 저장본이 대신하는 경계),
  `Librarian_progress`(저장본이 이 History에 맞지 않을 때 Librarian의 durable Read
  Position), `Past_librarian_point`(Librarian 지점이 뒤처져 있고 provider가 수용한
  시작점이 앞서 있을 때 그 수용된 자리에서 시작하는 경계),
  `Turn_start`(앞머리도 맞는 저장본도 없음: 이 History에서 마지막으로
  끝난 turn이 끝난 자리에서 시작한다), `Turn_start_unknown`(그 경계마저 못 읽음:
  가장 새 Atom 하나에서 시작한다). Agent Core는 맞는 저장본 → Librarian이 읽은
  위치 → Librarian 지점 뒤 수용된 시작점 → 이 History에 맞는 원장·씨앗 → 마지막으로
  끝난 turn의 경계 순으로 고른다(`choose_range_start`).
  Librarian 지점이 있으면 원장·씨앗은 읽지 않는다. Librarian 지점이 있거나 그 뒤의
  수용된 시작점에서 열린 요청이 크기 때문에 거절되면, 도구 마커 재전송 전에 마지막으로
  완료된 turn 경계부터 동일 후보에 한 번 더 보낸다(`Turn_start_after_librarian_refusal`,
  RFC librarian-lifecycle §4.10, rule 1). 이 경계 재전송(`turn_boundary_resend_sequence`)은
  typed size 거절뿐 아니라 실시간 크기 거절 도착 형태인 `Unknown_invalid_request`에도
  동작한다(`boundary_resend_on`). 만약 재전송이 크기와 무관한 사유(도구 스키마 오류나
  미지원 파라미터 등)로 다시 거절되면 앞머리를 턴 경계로 계속 쥐고 있지 않고 직전 앞머리를
  되돌려준다 — 크기가 아닌 거절로 인해 다음 후보나 이후 턴의 앞머리가 영구히 잘려나가는 것을
  막는다(#38537). provider가 수용한 시작점(`accepted_start`)은 최신
  응답 관측 턴 기록에서 읽혀 다음 turn의 `choose_range_start`로 전달되며, Librarian
  지점이 뒤처져 있는 동안 요청은 그 자리에서 열리고(`Past_librarian_point`), 결코 이번
  turn의 경계를 넘지 않는다(`within_turn_boundary`). Librarian 지점이 없는 turn에서
  provider가 씨앗 범위를 크기 때문에 거절하면 turn 경계가 그 turn의 앞머리가 되고
  (`Turn_start_after_seed_refusal`), 같은 후보에 한 번 더 보낸다. 다음 후보와 공식
  클라이언트 레인도 그 경계부터 싣는다. 받아들여진 요청이 원장에 남으므로 다음
  turn의 씨앗은 그 경계가 된다. 공식 클라이언트 레인은 씨앗이
  레인 자체의 자르기와 같거나 그 뒤에 있으면 씨앗에서 시작한다(마지막으로 끝난 turn의
  경계보다 오래돼도 그렇다). 씨앗이 없으면 레인의 자르기와 turn 경계 중 뒤쪽에서
  시작한다 (`RFC-keeper-context-window-in-tokens` §13.4·§13.6).
  `Librarian_progress`는 그 위치가 이 trace를 지목하고 그 앞 Atom이 위치가 기록한
  Message로 열릴 때만 채택하며, 그때 요청은 읽지 않은 Atom부터 실리고 그 앞을
  요약하지 않는다. `Past_librarian_point`는 Librarian 지점부터 수용된 시작점
  직전까지의 Atom을 요청에 싣지 않으며, 이 중 요약도 안 되고 메모리에도 없는 Atom들의
  틈은 `librarian_gap`이 계산한다. `Turn_start`에서는 이 turn 자신의 Atom만 실리고 그 앞 Atom은
  Librarian의 다음 회차를 기다린다. `Turn_start`의 `end_atom`은 그 경계 자체를 적는다 —
  범위가 열린 Atom이 아니라 turn-boundary 저장소가 말하는 완료 경계다. 그래서 경계가
  가장 새 Atom과 같거나 그보다 뒤여도(옛 번호로 남은 경계) 그 값을 그대로 적고, 범위가
  어디서 열릴지는 clamp가 정한다. `end_atom`이 0인 경우는 하나다 — 끝난 turn이 없는 새
  Keeper의 짧은 History 전체다. 경계 저장소를 못 읽었거나 어떤 경계도 이 History와 맞지
  않으면 그 값은 `Turn_boundary_unknown`이고, 출처는 `Turn_start_unknown`이며 요청은
  가장 새 Atom 하나만 싣는다 — 모르는 시작을 0으로 접어 이력 전체를 보내지 않는다.

  저장된 응답 관측의 범위는 당시의 사실이다. 현재 카탈로그에서 그 runtime을
  지우거나 바꾸어도 이 사실을 취소하지 않으며, 현재 History의 같은 위치·digest로 검증한다.
  원장이 없으면 보관 중인 기록에서 같은 trace의 마지막 응답 관측까지 거슬러 찾는다.
  응답 없는 기록이 쌓여도 이 관측을 가리지 않는다. 재시도가 같은 turn 번호를 쓰면
  나중에 저장한 응답 관측을 선택한다. 다음 요청 예측도 같은 reader를 쓴다.
  RFC 코퍼스는 이 자리를 **앞머리**라 부른다.
  → [Keeper_carried_front](../../lib/keeper/keeper_carried_front.mli)

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
  (`fresh`/`continued`)도 같이 적는다. 이어지는 History로 시작한 turn은 자기 시작
  위치(`continued_from`, 시작 Atom 수와 그 Atom을 여는 메시지의 digest)도 적는다.
  그래야 못 읽는 줄 하나가 회차를 영구히 세우지 않는다 — 뒤따르는 줄이 자기 시작
  상태를 실어 그 줄의 정체를 가른다. Checkpoint 파일이 있었는지가 아니라 Atom이
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

**Turn Boundary Position (턴 경계 위치)**
: `turn-boundaries.jsonl`의 `turn_ended` 줄이 적는, 그 turn이 끝났을 때 History의
  끝이 어디인가. 닫힌 넷이고 wire `kind`가 이름이다 — `Atom_history { end_atom;
  last_atom_digest }`(`atom_history`), `Empty_atom_history`(`empty_atom_history`),
  `No_atom_history`(`no_atom_history`), `Stale_noop`(`stale_noop`). 위치(Atom 수와
  마지막 Atom의 digest)를 갖는 것은 `Atom_history` 하나다. 저장이 Checkpoint를
  돌려주면 그 messages에서 위치를 세고, Atom이 하나도 없으면 `Empty_atom_history`다.
  돌려줄 Checkpoint가 없으면 소유자로 갈린다 — 공식 클라이언트 turn은 Agent Core
  Checkpoint를 저장하지 않으므로 `No_atom_history`, Agent Core turn은 저장 결과가
  `Stale_noop`일 때만 Checkpoint가 없으므로 `Stale_noop`이다. 저장이 `Error`면 줄을
  쓰지 않는다
  (`keeper_agent_run_finalize_response.ml`의 `turn_boundary_position`). 그래서
  `No_atom_history` 줄은 공식 클라이언트 turn을 가리킨다. 실패로 끝난 turn은 이 저장에
  닿지 않지만, 마지막으로 파견한 후보가 공식 클라이언트였으면 `No_atom_history` 끝 줄을
  따로 남긴다. 입력은 이미 그 turn의 History Fragment이고 부른 도구는 이미 행동했을 수
  있으므로, Librarian 회차가 입력과 도구 관측을 읽어야 하기 때문이다
  (`record_errored_official_turn_boundary`, #38809). 실패한 Agent Core turn은 stage 저장이
  Atom을 갖고 있어 다음 끝 줄이 덮고, 어떤 후보도 파견하지 못한 turn은 줄을 남기지 않는다.
  `Stale_noop`은
  `Keeper_checkpoint_store`의 저장 결과 `Stale_noop`(더 새 writer가 앞서 canonical
  Checkpoint를 그대로 둔 성공적 no-op)과 이름을 공유하지만 다른 값이다 — 하나는
  저장 결과, 하나는 turn 경계 위치다.
  → [Keeper_turn_boundaries](../../lib/keeper/keeper_turn_boundaries.ml)

**Turn Start (턴 시작 위치)**
: 씨앗도 흡수 지점도 없을 때 이번 요청이 어디서 시작하는가를 정한 값
  (`Keeper_carried_front.turn_start`). 닫힌 둘이다 — `Turn_boundary { end_atom }`,
  `Turn_boundary_unknown { reason }`. `Turn_boundary`는 이 History에서 마지막으로 끝난 turn의
  경계이고, 그 경계를 지금 History와 digest로 맞춰 본 값만 쓴다. 끝난 turn이 없는
  History에서는 0이라 갖고 있는 전부를 싣는다(새 Keeper의 짧은 History). 경계
  저장소를 못 읽었거나 어떤 경계도 지금 History와 맞지 않으면
  `Turn_boundary_unknown`이고, 요청은 가장 새 Atom 하나만 싣는다 — 모르는 시작을
  0으로 접어 History 전체를 보내지 않는다. 요청이 어디서 시작했는지는 `origin`이
  따로 적는다(`Turn_start`·`Turn_start_unknown`).
  - **경고 발생 경계**: `turn_start` 조회나 다음 요청 예측(`next-request forecast`) 단계에서
    무조건 경고를 남기지 않는다. 씨앗이나 앞머리 거절 폴백을 거쳐 실제로 알 수 없는
    턴 시작으로 범위를 열어 wire로 전송한 요청에서만
    `warn_range_opens_on_newest_atom` 경고를 낸다(#38365).
  **경고**: `turn_start`의 `Turn_boundary`·`Turn_boundary_unknown`과 `origin`의
  `Turn_start`·`Turn_start_unknown`은 `Turn Boundary Position`의 닫힌 넷
  (`Atom_history`·`Empty_atom_history`·`No_atom_history`·`Stale_noop`)과 **다른
  타입**이다. 이름이 겹쳐 보여도 하나는 요청이 시작한 자리, 하나는 turn이 끝난
  History의 끝 위치다.
  → [Keeper_carried_front.turn_start](../../lib/keeper/keeper_carried_front.mli)

**Read Position**
: Librarian이 History를 어디까지 읽었는지 적은 값(`keepers/<keeper>/librarian-progress.json`).
  Turn Boundary와 같은 cluster의 Keeper runtime 디렉터리에 저장한다.
  Turn Boundary 파일의 줄 번호가 아니라 값이다: trace, 읽은 Atom 수, 마지막으로
  읽은 Atom을 여는 Message의 digest. 그 파일에는 지난 History의 줄도 남아 있어서
  줄 번호로는 지금 History 안의 자리를 말할 수 없다. 공식 클라이언트 턴은 Atom을 남기지
  않으므로 그 위치만은 turn-boundary 파일의 줄 번호로 따로 적는다
  (`librarian-official-progress.json`의 `boundary_line`,
  [Keeper_librarian_official_progress](../../lib/keeper/keeper_librarian_official_progress.mli)).
  turn-boundary 파일은 줄을 뒤에 붙이기만 하고 고쳐 쓰지 않으므로 이 번호는 커지기만 한다.
  위치 파일은 둘 다, 없으면 아직 읽은 적이 없다는 뜻이다. 못
  읽는 파일은 "읽은 적 없음"으로 치지 않고 오류로 다룬다. 그렇게 치면 History
  전체가 안 읽은 것으로 보인다.
  이 값도 선택한 cluster의 Turn Boundary와 History에만 의미가 있으며, 다른
  cluster의 같은 이름 Keeper가 이어서 쓰는 공유 진행도가 아니다.
  Librarian이 이 값을 언제부터 읽고 쓰는지는 `RFC-librarian-lifecycle` §8을 본다.

**Librarian Range Receipt (완료 범위 영수증)**
: Memory snapshot을 바꾸기 전에 쓰는 영수증 원장
  (`<config keepers_dir>/<keeper>.librarian-range-commit.json`). 파일은 `receipts`
  배열이고, 각 영수증은 `prepared` → `committed` 두 상태를 갖는다. `prepared`는
  곧 쓸 snapshot의 revision과 전체 바이트 SHA256을 적고, 저장이 끝나면 같은 영수증을
  `committed`로 바꾼다. 모든 Memory writer는 snapshot을 바꾸기 전에 기존 `prepared`를
  먼저 판정한다 — SHA256이 현재 snapshot과 같으면 이미 저장된 범위라 `committed`로
  복구하고, 다르면 저장 전 실패라 영수증을 지운다. 그래서 범위를 저장한 뒤 다른
  write가 먼저 와도 완료 증거를 덮어쓰지 않는다. Read Position(진행 파일)과 다른
  파일이고, Keeper purge는 snapshot·journal·진행 파일과 함께 이 원장도 지운다.
  배포 preflight가 이 원장을 읽어 새 빌드가 못 읽는 원장을 배포 전에 잡는다.
  끝난 turn의 `Keeper_execution_receipt`(Terminal Reason·Operator Disposition)와
  다른 영수증이다.
  → [Keeper_memory_os_current](../../lib/keeper/keeper_memory_os_current.mli),
  `RFC-librarian-lifecycle` §4.6

**Trace ID**
: Keeper를 만들 때 한 번 정하는 실행 식별자. Checkpoint의 `session_id` 필드와
  `Turn_ref`의 trace id가 이 값이다.

**Memory OS**
: Keeper 하나가 오래 들고 가는 기억(Fact)을 저장하고 다시 꺼내 주는 곳.
  operator config의 Keeper 이름에 묶인다. cluster 사이에서 무엇을 같이 쓰는지는
  **Cluster** 항목에 적었다.

**Continuity Snapshot (하던 일 저장본)**
: 이어서 할 일의 설명과, 그 설명이 대신하는 완료된 History 범위를 함께 담은
  한 파일. 설명 절반은 Working State이고, 범위 절반은 완료된 History 구간이다.
  전송을 시작할 위치는 보존한 범위의 끝(exclusive)이다.
  Librarian Read Position은 합성 없이 기준점을 설정할 때도 움직이므로 이
  저장본을 대신하지 않는다. 받은 요청을 묶는 Working Context와도 구분한다.
  완료 대화 합성 회차는 대기열 정리를 요청하거나 Working Context를 변경하지 않는다.
  대기열 정리 응답의 오류가 완료 대화의 기억·요약 저장을 막지 않도록 분리한다.
  Agent Core는 저장본을 검증한 뒤, 완료된 원문 구간 대신 하던 일을 다음
  요청에 전달한다. 원본 checkpoint는 보존한다. 저장 완료와 요청에 사용한
  상태는 별개이며, 둘 다 모델 생성 설명의 의미 보존을 증명하지는 않는다.
  저장본은 유도된 파생 상태(`derived state`)다. 롤백이나 판올림 후 포맷 불일치로 파일을
  디코딩할 수 없는 경우(`Undecodable { reason }`), 이전처럼 매 회차 `Source_unavailable`로
  멈춰 서지 않고 atom 0부터 재구축(`rebuilt from atom 0`)하여 다음 커밋 CAS에서 파일을
  대체한다(#38477). 이때 이전 작업 상태(`working_state`)는 하드컷 정책에 따라 폐기되며,
  재구축 중에도 `catch_up_end_atom`을 유지하여 턴 드라이버가 Librarian 위치에서 안정적으로
  시작하도록 보장한다. 파일 읽기 실패(`Sys_error`)는 영구 오류로 남는다.
  `masc-librarian-continuity capture/restore`는 같은 파일 경계를 검증한다.
  → [Librarian_continuity_snapshot](../../lib/librarian_continuity_snapshot.mli)

**Working State (대화 작업 상태)**
: Librarian이 완료된 대화와 이전 상태에서 정리한 작업·제약·결정·미해결 사항.
  연속성 회차의 답에만 있고, `Keeper_librarian.continuity_working_state_of_json_result`가
  비지 않은 글인지 보고 읽는다. 연속성이 없는 기억 회차는 이 칸을 읽지 않는다. Continuity Snapshot이 담는
  "이어서 할 일의 설명" 절반이며, 같은 파일에 저장된 정확한 대화 범위와 한 쌍이다.
  큐 원본을 정리한 Working Context(`working_contexts`)나 장기 Memory facts와 다르다.
  모델의 출력만으로 범위가 소비된 것은 아니며, pair 저장과 소비 시 이력 검증이
  필요하다. 연속성 회차가 만든 이 값은 `Keeper_librarian_continuity.commit`의
  `working_state` 인자이고 Continuity Snapshot 파일에 저장된다. 턴은 이 값이 덮는
  atom들을 보내는 대신 이 값을 보낸다. 저장본이 덮는 범위와 이 값이 대신하는 범위는
  같다.
  공식 클라이언트 lane에서 요약을 못 싣는 경우는 셋이다(`working_state_left_out`) — 요약이
  Atom을 밀어내는 경우, 실을 turn이 없는 경우, 요약이 창에 안 맞는 경우다. 관측 이름과
  카운터는 그 셋을 따른다([`keeper_official_client_host.ml`](../../lib/keeper/keeper_official_client_host.ml)).
  요약이 빠져도 turn은 거절하지 않고 WARN으로 알린다.
  → [Keeper_librarian.selection](../../lib/keeper/keeper_librarian.mli) · [keeper_librarian_continuity](../../lib/keeper/keeper_librarian_continuity.mli)

**Extra System Context (턴별 문맥)**
: Keeper hook이 매 turn 새로 조립해 provider 지시 표면에 얹는 `System` 메시지.
  `Agent_core.Types.Extra_system_context_provenance`를 달고, 그 태그가 `Invalid`나
  `Duplicate`여도 이 문맥이다(`is_extra_context`). 고정(Pinned)이라 atom으로 세지
  않고 어떤 자르기도 지우지 않는다 — 매 turn 다시 조립되므로 살아남아야 한다. 이
  문맥을 실은 요청은 실어 보낸 History 크기의 표본이 아니다.
  - **Working State와 다른 것**: Librarian working state도 같은 표면의 두 번째
    `System` 메시지지만 표식이 다르다 — `working_state_marker_key`(`working_state_metadata`)
    하나만 달고, 요약된 범위가 조립한다. 턴별 문맥은 AGENT_CORE가 덧붙이는 carrier이고,
    working state는 범위가 조립하는 것이다.
  - **Composed System Context**: 이 둘을 함께 부르는 이름(`is_composed_system_context`).
    공식 클라이언트 어댑터는 이 메시지들을 canonical history 스냅숏에서 빼고 resume 때
    다시 보낸다.
  - **입력 귀속 검사**: turn 기록의 입력 귀속(`input_components`)은 요청 하나에 carrier가
    하나라고 보고 푼다. carrier가 두 번 보이면 요청은 그대로 나가고, 입력 귀속만 비운 채
    `prompt_context_carrier_repeated`를 사유로 남긴다.
  → [Runtime_model_input_tail_window](../../lib/runtime/runtime_model_input_tail_window.mli) · [Keeper_official_client_host.is_composed_system_context](../../lib/keeper/keeper_official_client_host.mli) · [Keeper_agent_prompt_metrics](../../lib/keeper/keeper_agent_prompt_metrics.mli)

**Continuity Synthesis Observation (대화 요약 진행 관측)**
: 이번 서버 실행에서 Librarian이 마지막으로 선택한 Atom 구간, 그때 확인한
  완료 경계, 실행·저장·중단 상태. `context_cycle.synthesis`와 TUI Memory 화면에
  표시한다. 일반 Memory 소비자의 `drained`와 별개이며 다음 실행을 통제하지 않는다.
  `no_source`는 새로 읽을 완료 구간을 얻지 못했다는 뜻으로, 전체 요약 완료를
  증명하지 않는다. 구간이 없거나 관측 전이면 알 수 없음으로 표시한다.

**Continuity Request Observation (요청 입력 관측)**
: 직렬화된 요청 하나가 무엇을 실었는지에 대한 읽기 전용 관측
  (`Keeper_continuity_observation.input`). Agent Core 는 직렬화한 요청 본문을,
  공식 클라이언트 레인은 클라이언트에 넘긴 범위를 기록한다. 이 관측은 History 삭제를
  승인하지 않고 provider가 요청을 받아들였음을 증명하지도 않는다. 종류는 넷이다 —
  `Summarized of frontier`(하던 일 저장본이 대신하는 경계까지 요약; frontier는 trace·
  끝 Atom·경계 줄), `Absorbed of { trace_id; end_atom }`(Librarian의 durable Read
  Position에서 시작하고 그 앞을 요약하지 않음 — Agent Core 와 공식 클라이언트 레인
  모두에서 성립), `Without_snapshot`(turn이 Librarian 지점을 고르지 않아, 요청이
  씨앗·레인 자체의 자르기·turn 경계 중 한 곳에서 시작함),
  `Not_applied`(저장된 맥락을 적용하지 않음: turn 이 아무 선택도 안 했거나(추적 없음·
  복구 뷰), 공식 클라이언트 레인에서 씨앗이나 레인 자체의 자르기가 turn 이 고른 지점보다
  뒤에 있었음). `Absorbed`는 경계 줄이 없어 모양이
  trace와 Atom뿐이다. Dashboard의 `context_cycle.prepared.input.kind`가
  `summarized`·`absorbed`·`without_snapshot`·`not_applied`로, TUI Memory 화면이
  `summary …`·`absorbed to atom N · trace X · no summary`·`no snapshot: this turn only`·
  `saved context not applied`로 그린다. 같은 `context_cycle`의 `synthesis`를 담는
  Continuity Synthesis Observation과 다른 필드이고, 저장된 파일인 Continuity
  Snapshot과도 다르다.
  → [Keeper_continuity_observation](../../lib/keeper/keeper_continuity_observation.mli),
  [dashboard 투영](../../lib/server/server_dashboard_http_keeper_memory_health.ml)

**Librarian Round (Librarian 회차)**
: Librarian이 한 번 도는 일. Keeper마다 따로 돌고, 같은 신호(서버 기동·턴 끝·받은 일
  변경)에 깨어난다. 두 가지가 있다.
  - durable 회차(`Keeper_librarian_durable_consumer`): 끝난 턴을 읽어 Memory OS에 적고
    읽은 위치(Read Position)를 옮긴다. Agent Core 턴은 checkpoint의 atom으로, 공식
    클라이언트 턴은 그 trace의 history 파일에서 `turn_ref`가 가리키는 조각으로 읽는다.
    두 위치(atom 위치·공식 클라이언트 위치)는 각각 따로 옮기며, `commit`이 Memory OS snapshot
    커밋을 보고할 때만 옮긴다. 공식 클라이언트 턴 쪽이 읽을 수 없는 거절 경계선에서
    멈추더라도(`Keeper_librarian_range.Official_stop`), 이 정지는 공식 위치만 세우며 atom 쪽은
    독립적으로 읽어 atom 위치를 전진시킨다. atom 쪽에 더 읽을 것이 없을 때 비로소 회차가
    `Official_range_stopped`로 종료된다(#38475).
  - 연속성 회차(`Keeper_librarian_continuity`): 스냅숏이 덮은 앞부분을 다시 쓰는 회차.
    완료된 대화 구간을 요약해 Continuity Snapshot을 만든다. 커밋은 durable 회차의
    위치를 바꾸지 않는다.
  두 회차는 따로 밀리고(Continuity Lag), 실패 뒤 범위를 좁히는 방식도 다르다(RFC
  librarian-lifecycle §4.3). durable 회차는 실패 종류를 보지 않고, 실패 표식(wide-range
  failure marker)을 루프 메모리에 두고 가장 오래된 한 턴으로 좁힌다. 단, 공식 정지
  (`Official_range_stopped`)로 끝난 회차는 이 마커를 해제하여 이후 회차가 atom 백로그
  전체를 정상적으로 읽도록 보장한다(#38475). 연속성 회차는 실패 종류를 보고 크기
  때문인 실패에서만 좁히며, 좁힌 폭(Continuity Width)을 다음 회차로 넘긴다.
  → [keeper_librarian_durable_consumer](../../lib/keeper/keeper_librarian_durable_consumer.mli) · [keeper_librarian_range](../../lib/keeper/keeper_librarian_range.mli) · [keeper_librarian_continuity](../../lib/keeper/keeper_librarian_continuity.mli)

**Continuity Lag (요약이 밀린 정도)**
: 연속성 회차가 얼마나 뒤처졌나 — Librarian의 읽은 위치(Read Position)의 `end_atom`에서
  연속성 스냅숏이 덮은 끝(`Keeper_continuity_observation.frontier.end_atom`)을 뺀 atom 수.
  같은 trace를 가리킬 때만 세고, 스냅숏이 앞서면 세지 않는다. health JSON의
  `continuity_unread_atoms`이고 TUI는 `continuity behind <n>`으로 그린다. durable 회차의
  밀림(`Keeper_librarian_durable_consumer.unread`의 `atoms`·`official`, health의
  `unread_atom_turns`·`unread_official_turns`)과 다른 값이다 — 두 회차는 따로 밀리므로
  한 숫자가 둘을 대신하지 못한다(RFC librarian-lifecycle §4.9). 스냅숏이 없거나, 두 파일
  중 하나를 못 읽거나, 두 파일이 다른 trace를 가리키거나, 스냅숏이 앞서면 `null`
  ("말할 수 없음")이다. 그 넷은 따라잡은 Keeper가 아니므로 0으로 적지 않는다. fleet
  합계(`librarian_continuity_unread_atoms`)는 잴 수 있었던 Keeper만 더하고 못 잰 수를
  옆에 센다(`librarian_continuity_unmeasured`) — 한 Keeper 때문에 합계가 null이 되면
  잴 수 있는 Keeper가 다 가려진다.
  → [server_dashboard_http_keeper_memory_health](../../lib/server/server_dashboard_http_keeper_memory_health.ml)

**Librarian Stalled (Librarian 이 멈춰 건너뛴 구간)**
: Librarian 지점이 provider 가 마지막으로 받아들인 시작점보다 뒤에 있어서, 다음 요청이
  건너뛰는 atom 중 요청에도 기억에도 없는 구간. 시작은 스냅숏 컷과 durable 읽은 위치 중 늦은
  쪽, 끝은 받아들여진 시작점 바로 앞이다. 비면 gap 이 없다. 규칙은 순수 함수
  `Keeper_carried_front.librarian_gap` 하나이고, 경보는 Keeper 의 작은 파일(meta, 스냅숏,
  진행 파일, 턴 기록)만 읽어 그 함수를 부른다(`Keeper_next_request_forecast.librarian_gap`).
  health JSON 의 `librarian.stalled`(`kind: "gap"`, `gap_start_atom`, `gap_end_atom` — 끝은
  제외)이고, TUI 는 `Librarian stalled · atoms <a>-<b>` 로 그린다. 읽어야 할 파일을 못 읽으면
  gap 없음(`null`)도 gap 도 아닌 `kind: "unmeasured"` 와 못 읽은 파일(`cause`)로 보낸다.
  경보이지 Gate 가 아니다. Librarian 이 받아들여진 시작점에 닿으면 사라진다(RFC
  librarian-lifecycle §4.10).
  → [keeper_carried_front](../../lib/keeper/keeper_carried_front.mli) · [keeper_next_request_forecast](../../lib/keeper/keeper_next_request_forecast.mli)

**Continuity Width (연속성 회차의 폭)**
: 연속성 회차가 한 번에 읽을 수 있는 atom 수의 상한. 크기 때문에 거절당한 회차가 좁힌
  값을 다음 회차가 이어받는다. (keepers dir, keeper)별로 그 값을 잰 trace와 함께 루프
  메모리에 둔다(`keeper_librarian_queue_refresh.ml`의 `limited_widths`). trace가 바뀌면
  atom 번호가 다시 매겨지므로 비교하지 않고 새 값으로 바꾸고, 같은 trace 안에서는 더
  좁은 값만 남는다. 끝 atom이 아니라 폭을 남기므로 커밋한 회차 다음에는 같은 자리가
  아니라 그다음 자리를 읽는다. 좁히는 것은 작은 요청이 같은 벽을 피할 수 있는 실패뿐이고,
  그 판정은 `walk_shows_size`(`keeper_librarian_runtime.mli`의 `not_committed` 필드)가 들고, 원인별 판정
  규칙은 RFC-librarian-lifecycle §4.3이 정한다. 마지막 후보 하나가 아니라 후보를 차례로
  시도한 전체 결과로 판정한다. 폭은 backlog를 끝까지 읽었을 때(`Drained`)만 푼다. 좁힌 커밋 한 번은
  거절했던 범위가 이제 들어간다는 증거가 아니다. 루프
  메모리에만 있으므로 서버가 재시작하면 폭은 사라지고 다시 전부 읽기부터 시작한다(RFC
  librarian-lifecycle §4.3).
  → [keeper_librarian_queue_refresh](../../lib/keeper/keeper_librarian_queue_refresh.ml)

**Input Policy (입력 구성 방식)**
: Keeper의 `input_policy` 설정. `small`은 Agent Core에 보내는 완료된 과거 도구 결과를
  조회 가능한 원문 참조로 바꾸고, `wide`는 그 본문을 함께 보낸다. 둘 다 검증된
  하던 일 저장본을 사용하며, 아직 완료되지 않은 작업과 일반 대화는 유지한다.
  `small`은 새로 조립하는 작업 이력의 실패 호출 인자와 상세 오류도 원문 참조로 전달한다.
  이 새 briefing 구성은 실제 요청에 원문 조회 도구를 제공하는 모든 runtime에
  적용할 수 있다. 공식 클라이언트가 소유한 대화 History를 요약하는 것은 아니다.
  조회 도구가 없거나 저장에 실패하면 원문을 유지한다.
  조립 시점의 지문은 원문 기준이며, 실제 전송 내용은 요청별 capture와 block digest로 확인한다.
  원본 checkpoint나 Memory의 처리 위치를 바꾸지 않는다. 기본은 `small`이다.
  `max_context_override`는 별도의 토큰 상한이며, 이 설정이나 채워야 할 목표가 아니다.
  공식 클라이언트는 자체 문맥 처리를 사용하므로 선택값과 실제 적용 여부를 구분한다.

**Fact**
: Memory OS의 기억 하나. 문장(`claim`), `category`, 처음·마지막으로 본 시각,
  `origin`, `basis`로 이뤄진다. id 필드는 없고 Memory ID는 `claim` 글자의
  SHA-256이다. 글자가 하나라도 다르면 다른 Fact다. 처음·마지막으로 기록된 시각
  (`first_seen`, `last_seen`)은 둘 다 Fact가 기록된 시각(write time)이며, 상태가
  지속된 시각이나 신뢰도·강도(strength) 신호가 아니다. 같은 내용(동일 바이트)으로
  다시 쓰인 Fact는 최초의 `first_seen`을 보존하고 `last_seen`만 전진한다(#38056).
  → [Keeper_memory_os_current.insert_or_reobserve](../../lib/keeper/keeper_memory_os_current.ml)

**Origin**
: Fact를 누가 적었나. `authored`는 Keeper가 `keeper_memory_write`로 직접 적은 것,
  `injected`는 Librarian이 대화에서 뽑아 넣은 것이다. Keeper는 자신이 직접 적은
  현재 Fact만 `supersedes`로 대체할 수 있고, Librarian이 넣은 `injected` Fact는
  대체할 수 없다(#38122).

**Basis**
: Fact가 무엇에 근거하나. `observed`는 읽은 곳(자기 대화 또는 Board 글)을 갖고,
  `derived`는 유도(derivation)를 하나 이상 갖고, 유도마다 전제가 된 다른 Fact의
  Memory ID를 갖는다. 전제가 모두 살아 있는 유도가 하나라도 남아 있으면 `derived`
  Fact는 유지되고, 그런 유도가 하나도 없으면 무효가 된다.

**Dropped / Supersedes / Absorbs**
: 기억을 정리하거나 갱신하는 말.
  - Librarian 회차: `dropped`는 이유를 적고 버린다. `supersedes`는 옛 Fact 하나를
    새 claim 하나로 고쳐 쓰며(1:1) 옛 id는 `dropped`에도 있어야 한다. `absorbs`는
    Fact 여러 개를 새 claim 하나가 대신 말하며(N:1) 그 id들은 `dropped`에 없어야
    한다. 흡수된 원문은 `<keeper>.memory-absorbed.jsonl`에 남는다. Librarian이
    말하지 않은 Fact는 그대로 남고, 규칙을 어긴 답은 통째로 거절된다. 이미 있는
    Fact와 같은 글자를 다시 쓰는 것은 새 Fact가 아니라 그 Fact다 — 아무것도 더하지
    않고 저장된 Fact를 유지하며, 거절이 아니다. 같은 답이 그 Fact를 `dropped`로도
    적으면 "사라졌다"와 "남는다"를 함께 말한 모순이라 거절한다(`Dropped_memory_id_recreated`).
    Librarian 프롬프트의 지시(코드가 강제하지 않는다): 한 대상의 움직이는 상태를
    시점마다 적은 Fact가 여러 개면 claim에 적힌 시점(날짜·순번·프레임 번호)으로 먼저
    선후를 정하고, 그런 표시가 없으면 `last_seen`이 가장 늦은 것을 현재로 본다. 순서를
    정할 수 없거나 같은 대상인지 확실하지 않으면 지우지 않는다. 현재가 아닌 상태는
    `dropped`에 넣고, 현재 상태 claim의 `absorbs`에 넣지 않는다.
    코드 규칙: absorb gate는 판정 모델에게 흡수된 Fact의 문장마다 새 claim이 그 내용을
    말하는지 묻는다. 말하지 않는 문장이 하나라도 있으면 그 Fact는 흡수되지 않고 현재
    Fact로 남는다. 새 claim은 원칙적으로 적용되나, `absorbs`에 지정한 기억 중 어느 것도
    흡수되지 않은 claim이 기존 기억의 사본이면 역방향 사본 판정(Reverse Copy Judgment)을
    거쳐 저장하지 않고 버린다(#38056·#38243). 흡수 대상(`into`)이 잠근 시점의 스냅숏에도,
    이번 답의 새 claim에도 없으면(회차 도중 Keeper가 그 Fact를 철회하거나 `supersedes`로
    대체한 경우) 그 흡수는 적용하지 않는다. 원문은 현재 Fact로 남고 지워진 대상은
    되살아나지 않으며, 회차 도중 없어진 기억을 이어붙이는(supersedes 또는 absorbs) 새
    claim은 저장하지 않고 실행 기록(`run` 출력)에 `claims_not_applied`로 남긴다.
    원장의 `Revised` 이벤트는 커밋이 실제로 수행한 `supersedes`에만 기록되어 대체된
    기억은 Keeper가 직접 준 후계자 하나만 보존하며, 후계자 중 어느 것도 스냅숏에 남지
    않은 대체 대상 기억은 퇴역하지 않고 현재 Fact로 남는다(#38231·#38267·#38317).
  - Keeper 직접 갱신: `keeper_memory_write`는 선택 인자 `supersedes`로 자신이 직접
    적은 이전 Fact 하나를 새 claim으로 대체할 수 있다(#38122). 원자적(locked) 한 번의
    커밋으로 이전 Fact를 지우고 새 Fact를 적으며, 저널에 `superseded_by` 사유를 남기고
    원장에 `Revised` 이벤트를 기록한다. 철회와 마찬가지로 대체된 Fact를 전제로 삼던 유도
    Fact들도 함께 무효화되며 영수증의 `removed_memory_ids`와 `support_invalidations`로
    보고된다. 기억 저장소는 Keeper마다 따로라서, 이 Keeper의 현재 Fact가 아닌 id는
    알 수 없는 id든 이미 지난 id든 모두 non-current로 거절된다. 그 밖에 `injected` id,
    대체할 Fact와 글자까지 똑같은 claim(`supersedes_self`), `source_path`와의 동시 지정,
    대체될 Fact를 전제로 삼는 유도 claim(`supersedes_premise_of_successor`), 근거 경로가
    없는 유도 claim(`unsupported_derivation`)도 거절되며 아무것도 적지 않는다.
  → [Keeper_memory_os_current](../../lib/keeper/keeper_memory_os_current.ml) · [Keeper_librarian_absorb_gate](../../lib/keeper/keeper_librarian_absorb_gate.mli) · [librarian.md](../../config/prompts/librarian.md)

**Reverse Copy Judgment (역방향 사본 판정)**
: Librarian 회차가 내놓은 새 claim 중 `absorbs`에 기억을 적었으나 실제로는 그 중
  아무것도 흡수하지 못한 claim에 대해, 남겨진 기억들이 그 claim의 내용을 이미
  담고 있는지 묻는 역방향 판정. "새 claim은 항상 적용된다"는 기본 규칙의 단 하나의
  예외다(RFC-0463 §2.8·#38243).
  - 배경: Librarian이 매 회차 같은 주제를 조금씩 다른 문장으로 다시 써서 기존 Fact가
    흡수되지 않고 paraphrase 사본이 무한 축적되는 문제를 막는다.
  - 전이 및 판정:
    - 대상: `absorbs`에 기억을 나열했으나 absorb gate에서 0건만 흡수 승인된 새 claim.
      단, `supersedes`로 대체 대상이 지정된 claim은 제외한다(`Continues_a_dropped_memory` —
      버리면 대체 대상만 사라지고 빈자리가 남기 때문).
    - 절차: 남겨진 원본 기억들을 최대 `state_bytes_limit` 바이트 크기로 묶어 상태를
      구성하고, 새 claim을 문장 단위(`statements`)로 쪼개어 판정 모델에 묻는다.
    - 경계: 점수가 `conveyed_boundary`를 엄격히 넘을 때만 전달된 것으로 인정하며,
      동점(tie)은 claim을 버리지 않도록 미전달로 본다.
    - 결과: 모든 문장이 전달되었으면 `Copy`로 판정해 원장에 저장하지 않고
      탈락시킨다(`without_copies`). 전달되지 않은 문장이 하나라도 있으면
      `Carries_new_statement`로 정상 적용한다. 판정 실패나 크기 초과 등
      `Not_judged`(`Gate_judgment_failed`·`No_source_fits_the_state`·`Statement_too_large`·`No_statement`·`Request_failed`)인
      경우에도 기존처럼 정상 적용한다.
  - 저장 및 표면: 탈락된 claim은 원장에 쓰이지 않고 로그에 남으며, Librarian 회차
    실행 결과의 `copy_checks`에 각 판정 결과(`verdict`)와 호출 횟수가 기록된다.
  → [Keeper_librarian_absorb_gate](../../lib/keeper/keeper_librarian_absorb_gate.mli)

**Memory Event**
: Fact에 일어난 일의 기록(`<keeper>.memory-events.jsonl`). `retrieved`는
  `keeper_memory_search` 결과에 나온 것, `revised`는 Librarian의 `supersedes` 또는
  Keeper의 `keeper_memory_write ?supersedes`로 고쳐 써진 것이다(#38122).
  `retracted`는 Keeper가 `keeper_memory_retract`로 그 Fact를 id로 지목해
  철회한 것이다. 철회 뒤 같은 claim을 다시 저장하면 같은 Memory ID에 과거 기록이
  붙는다. TUI의 `History: Retracted`는 그 철회 횟수이며, 현재 Fact의 신뢰도나
  강화 정도를 뜻하지 않는다.
  - **교체된 흡수 기억 연쇄 추적**: `keeper_memory_search`는 흡수된(`absorbs`) 기억의
    대상 claim이 이후 `keeper_memory_write ~supersedes`로 대체된 경우, 버려진(dropped)
    claim에서 멈춰 `into_current=false`로 보고하지 않고 원장의 `Revised` 이벤트(`superseded_by`)를
    따라 현재 살아 있는 claim까지 연쇄 추적하여 `into_current=true`로 연결한다.
    매 검색마다 이벤트 사이드카를 읽는 부하를 막기 위해 평소에는 흡수 원장(`memory-absorbed.jsonl`)만으로
    해결하고, 체인의 끝이 non-current일 때만 사이드카(`.memory-events.jsonl`)를 읽는다. 손상된
    이벤트 줄은 `event_unreadable_lines`로 분리 보고된다(#38543·#38552).
  - **Keeper 삭제 시 사이드카 정리 및 캐시 무효화**: Keeper를 삭제(`purge_keeper_artifacts`)할 때 이
    사이드카 파일(`<keeper>.memory-events.jsonl`)도 함께 삭제(`Keeper_memory_events_artifact`)되고
    캐시된 파일 쓰기 핸들러(`Fs_compat.invalidate_cached_writer`)도 무효화된다. 따라서 동일 프로세스에서
    같은 이름으로 다시 생성된 후속 키퍼가 이전의 조회·철회·대체 이벤트를 상속하거나 삭제된 inode에 쓰기
    내용이 유실되는 결함을 원천 방지한다(#38235).
  → [Keeper_shutdown_types](../../lib/keeper/keeper_shutdown_types.mli),
  [Server_dashboard_http_delete_actions](../../lib/server/server_dashboard_http_delete_actions.ml)

**Library**
: `masc_library_add`로 수동 추가한 Markdown 문서를 읽는 지식 라이브러리.
  자동 수집 경로는 없고 Keeper에게는 검색·읽기 샤드만 있으므로, 설치에 문서가
  하나도 없는 상태도 정상이다. 알려진 문서가 있을 때만 검색한다.
  문서는 호출자가 해석한 workspace(`Workspace.config.base_path`) 아래
  `<base_path>/docs/library`에 저장되고, 도구는 환경 변수를 읽지 않는다.
  각 문서는 YAML frontmatter
  (`title`·`source`·`author`·`created`·`updated`·`tags`)를 갖는다. 한 층의 평평한
  디렉터리라 문서는 들어 있거나 없거나 둘 중 하나다. `source`는 닫힌 합타입
  (`Direct_experience`·`Research`·`Experiment`·`Observation`)이고, 생성자를 더하면
  `source_to_string`이 컴파일 오류로 강제된다. 쓰기에서 `source`가 없으면 `title`
  없을 때처럼 거부하고, 읽기에서 알 수 없는 `source`는 파일명과 이유로 표시한다.
  네 도구가 이걸 쓴다 —
  `masc_library_list`·`masc_library_read`·`masc_library_add`·`masc_library_search`.
  Keeper 쪽에는 read-only인 `keeper_library_search`·`keeper_library_read` 샤드
  투영만 있다.
  Librarian(기억 정리자)과 이름이 비슷하지만 다른 것이다 — Librarian은 Keeper의
  Memory OS를 정리하고, Library는 명시적으로 추가된 문서만 담는다.
  → [Tool_library](../../lib/tool_library.mli)

**Librarian**
: Keeper마다 따로 도는 기억 정리자. Keeper의 History와 현재 facts를 읽고 LLM을
  한 번 불러, 더할 fact와 버릴 fact와 합칠 fact를 정해 Memory OS에 적는다. 같은
  호출에서 미처리 요청을 묶고 다음 행동을 제안한다. Keeper의 판단을
  대신하지 않는다.
  Librarian은 자기가 누구를 위해 정리하는지 대상 Keeper의 식별자(`keeper_id`)를
  입력(`Keeper_librarian.input`)에 필수로 실어 보낸다(RFC-0468 §3.1).
  세 프롬프트(`librarian`·`librarian.continuity`·`librarian.working_context`)는 이를
  `keeper_instructions` 옆 호스트 데이터로 전달받아 그 Keeper의 자리에서 대화를
  읽으며, 안내문의 호칭(\"너\"·\"당신\")이 이 대상 Keeper를 가리킴을 안다.
  대상 Keeper 이름이 빈 문자열이면 기본값으로 채우지 않고 입력을 거절하거나 유닛을
  실패 처리한다.
  History를 읽는 경로의 구현 진척은 `RFC-librarian-lifecycle` §8을 본다.
  Agent Core의 읽은 위치가 저장되면 같은 wake에서 남은 이력을 계속 읽는다.
  읽을 것이 없거나 읽기·저장에 실패하면 멈추고, 실패한 범위는 다음 신호에서 다시 읽는다.
  매 회차 설정을 확인하므로 꺼진 동안에는 다음 범위를 읽지 않는다.
  이 이름은 프롬프트 category `librarian`(`config/prompts/librarian.md`,
  `workspace_memory_curator.md`)과 CLI `masc-librarian-replay`·`masc-librarian-continuity`가
  공유한다. 셋은 서로 다른 것이고, 어느 것도 Skill이 아니다.
  → [Keeper_librarian](../../lib/keeper/keeper_librarian.mli)

**Librarian Gap (Librarian 틈)**
: 요청(Request)에도 실리지 않고 Librarian 메모리에도 들어가지 않은 Atom들의 범위
  (`Keeper_carried_front.librarian_gap`). Librarian이 커버하는 끝은 지속성 스냅숏의
  자르기(`snapshot_cut`)와 내구성 읽은 위치(`read_position`) 중 나중(뒤쪽) 지점이다 —
  자르기 이전은 요약되었고, 읽은 위치 이전은 메모리에 있다. provider가 직전 요청에서
  수용한 시작점(`accepted_start`)이 그 끝보다 뒤쪽에 있을 때, 그 끝부터 `accepted_start`
  직전까지가 틈이 된다. `accepted_start`가 그 끝 이하이거나 두 위치를 모두 알 수 없으면
  틈은 없다(`None`). 현재 이력에 맞지 않는 스냅숏이 남아 있는 동안에는 읽은 위치 대신
  그 자르기부터 계산되어 틈이 짧게 산출될 수 있다 (RFC librarian-lifecycle §4.10, rule 3).
  → [Keeper_carried_front.librarian_gap](../../lib/keeper/keeper_carried_front.mli)

**Librarian Replay**
: `masc-librarian-replay` CLI. 라이브 워크스페이스의 turn-boundary 로그와 checkpoint에
  Librarian 읽기 규칙(`Keeper_librarian_range.select`/`slice`)을 오프라인으로 돌려,
  backlog가 몇 회차에 걸리는지·회차마다 몇 atom을 나르는지·중복 atom이 있는지를
  센다(RFC librarian-lifecycle §9). 메시지 본문은 출력하지 않고 count·atom 번호·digest만
  낸다. 아무것도 쓰지 않는다 — progress 파일·boundary line·checkpoint 모두 없다.
  서버의 Librarian 실행이 아니라 그 읽기 규칙의 측정 하네스다.
  → [masc_librarian_replay](../../bin/masc_librarian_replay.ml)

**Librarian Pass End (Librarian 회차 종결 상태)**
: Memory health HTTP API와 TUI Memory 화면이 그리는 Librarian durable 회차의 종결 상태.
  Memory health의 Librarian 행은 스냅숏의 source가 아니라 저널 최신 줄들을 역순으로 걸어
  (`server_dashboard_http_keeper_memory_health.ml`), Librarian이 마지막으로 커밋한
  성공과 그 뒤의 최신 실패를 독립적으로 읽는다. 따라서 키퍼가 `keeper_memory_write`나
  철회(`retraction`)로 Fact를 직접 기록해도 Librarian의 성공을 지우거나 직전 실패를
  가리지 않는다(#38049).
  TUI(`lib/tui_decode.mli`, `bin/masc_tui_render_memory.ml`)는 회차 종결 상태와 실패
  종류를 닫힌 타입으로 디코드하고 wire 단어 대신 일상 단어로 그린다:
  - 닫힌 여섯 종결 상태(`memory_librarian_pass_end`):
    `Pass_off`(\"switched off\"), `Pass_lane_unconfigured`(\"no model lane set up\"),
    `Pass_drained`(\"caught up\"), `Pass_not_committed`(\"last pass saved nothing\"),
    `Pass_stopped`(\"stopped on an error\"), `Pass_raised`(\"crashed\").
  - 닫힌 아홉 실패 종류(`memory_librarian_failure_kind`):
    `Failure_prompt_render`(\"prompt could not be built\"),
    `Failure_execution_clock_unavailable`(\"no clock to run on\"),
    `Failure_exact_setup`(\"model call could not be set up\"),
    `Failure_exact_execution`(\"model call failed\"),
    `Failure_domain_output_invalid`(\"model answer was not usable\"),
    `Failure_memory_snapshot_write`(\"Memory could not be saved\"),
    `Failure_runtime_context_unavailable`(\"no runtime context\"),
    `Failure_lane_cancelled`(\"cancelled before saving\"),
    `Failure_unhandled_exception`(\"unexpected crash\").
  - `Librarian cause`: `Pass_stopped` 또는 `Pass_raised`일 때 서버가 기록한 구체적 원인을
    별도 행에 그린다.
  - 행 격리: 서버가 보낸 값을 TUI가 알지 못하면 전체 Memory 화면을 깨뜨리지 않고 해당
    키퍼 행만 이름과 거절 사유 한 줄(`refusal`)로 격리하며 다른 행들은 정상 표시한다.
  → [server_dashboard_http_keeper_memory_health](../../lib/server/server_dashboard_http_keeper_memory_health.ml) · [tui_decode](../../lib/tui_decode.mli) · [masc_tui_render_memory](../../bin/masc_tui_render_memory.ml)

**JEV / Noul**
: JEV는 TypeSafe AI System One의 모델이다. Noul은 명시한 질문에 대한 답이
  참일 확률을 반환하는 응답 종류다. Noul 값은 기억 보존율이나 전체 기능의
  통과율이 아니다. Board의 Choice 판정과도 구분한다.
  Librarian에서는 새 claim이 흡수할 원문을 전달하는지 검사하며, 이 판정은
  Memory 저장 성공과 별개다. 실행의 `run.status`와 판정의 `absorb_gate.status`를 구분한다.
  `skipped`는 검사를 건너뛴 이유, `incomplete`는 중단 전에 완료된 응답만 담는다.
  `failed`는 검사 실패다. 모든 문장이 전달된다고 확인된 원문만 흡수하고,
  확인하지 못한 원문은 현재 Memory에 남긴다. 새 claim 저장은 계속한다.
  `judged`는 검사를 마친 결과다. 검사 비활성화 등 `skipped`일 때는 Librarian의 결정을 그대로 적용한다.
  취소된 실행에서 완료된 응답이 보여도 Memory가 바뀌었다는 뜻은 아니다.
  반대로 실행의 `cancelled`도 Memory를 되돌렸다는 뜻은 아니다. 저장 뒤 취소되면
  `output.after`에 저장된 snapshot과 revision을 남긴다. 저장 전 취소는 이 기록이 없다.
  이미 저장된 실행 완료 결과는 이후 화면 갱신 알림의 취소로 덮어쓰지 않는다.
  Board lane 상세의 `JEV OFF`·`JEV CONFIGURED · <model>`·`JEV unavailable: Board lane
  is CLI-only`·`JEV unavailable: Board lane is not ready`는 JEV 모델 자체의 상태가
  아니라 그 lane이 JEV를 쓸 수 있는지의 구성 상태다. decode는 `state` 값 `off`·
  `configured`(+`model`)·`cli_only`·`lane_unavailable`을 받는다.

**Continuity Measurement (의미 보존 측정)**
: 특정 턴에서 만든 질문에 이후의 facts와 unread만으로 답하고, 참조 턴과
  비교해 그 답을 평가하는 관측. CLI `masc-librarian-continuity`가 이 측정을
  돌리는 하네스이며, 명시한 합성 입력과 각 단계의 결과를 JSON 파일에 저장한다.
  TUI의 `/measurement SHA`는 게시한 결과 사본을 읽는다. 운영 Librarian 실행이나
  Memory 변경을 승인하는 Gate가 아니다. 실행 방법과 결과의 한계는
  [Benchmark Runbook](../BENCHMARK-RUNBOOK.md)을 본다.
  → [masc_librarian_continuity](../../bin/masc_librarian_continuity.ml)
