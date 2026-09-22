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

**Exit Reason (세션 종료 사유)**
: TUI 세션이 왜 끝났는지 자기 stderr 로그(`.masc/logs/masc-tui-<pid>.log`)에 남기는 한 줄.
  `Masc_tui_exit_reason.t`가 닫힌 어휘를 소유한다 — `Quit_key`(q·Q·Ctrl-Q),
  `Interrupt`(첫 Ctrl-C가 아직 살아 있는 동안의 두 번째 Ctrl-C), `Terminate of string`
  (SIGTERM·SIGHUP·SIGQUIT), `Exception of string`(루프를 빠져나온 잡히지 않은 예외).
  `is_normal`이 정상/비정상을 가른다: 정상은 운영자나 세션 주인이 의도해 끝낸 것
  (`Quit_key`·`Interrupt`·`Terminate`), 비정상은 요청 없이 표면이 떠난 것(`Exception`)이다.
  줄은 `exit: normal (quit key)` 꼴이고, detail에 제어 바이트가 있으면 먼저 한 줄로
  평탄화한다 — 로그를 한 줄씩 읽기 때문이다. 이 줄이 끝의 유일한 기록이다: 로그에는
  기동 줄만 있어, 끝난 세션은 사유를 남기지 않았다. **Terminal Reason**과 다른 축이다 —
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
  `keeper.constitution`은 세계가 쓴 규범(RFC-0442)이고, 조항이 없으면 통째로 빠진다.
  `<role>`은 그 Keeper의 `instructions`(Keeper TOML)를 적힌 그대로 감싸며 앞에 제목을
  붙이지 않는다.
  `keeper.identity`·`keeper.workspace`는 각각 Keeper 이름과 샌드박스 루트를 받는다.
  전체 지도는 [Prompt Map](../PROMPT-MAP.md)을 따른다.
  경계: 여기의 "role"은 Message의 role(`System`·`User`·`Assistant`·`Tool`)도, Board
  Interest 판정의 `keeper_role {name, board_interests}`도, Fusion 심판의 `judge_role`
  (Fusion Judge Role)도 아니다.
  → [Keeper_prompt](../../lib/keeper/keeper_prompt.mli)

**Board Interest**
: Keeper가 직접 지목되지 않은 Board post와 comment를
  의미 판정 대상으로 받을 수 있는 주제 선언. `board_interests = []`이면 이
  targetless discovery를 끈다. 정확한 Keeper 지목과 broadcast, 게시글 작성자 및 해당 댓글의 부모 댓글
  작성자에게 보내는 전달에는 영향을 주지 않으며 Task 할당이나 실행 권한도 아니다.
  `mention_targets`는 정확한 주소 토큰이고 `board_interests`는 의미 판정의 입력이므로
  서로 fallback하지 않는다. v7 판정 경계는 현재 typed signal과
  `keeper_role {name, board_interests}`만 사용한다. 과거 post/comment thread,
  instructions, runtime/task identity, mention 목록은 저장하거나 보내지 않는다.

**Board Attention Candidate (Board 판정 후보)**
: Board_attention lane이 판정할 게시물 하나. 어떤 모델 호출보다 먼저 durable하게
  저장되고, 생애가 `Pending → Judged → Consumed`다. exact-flow 실패가 확정되면 먼저
  `Quarantine Quarantined`로 투영되고, 운영자 소유의 복구가 이전 도메인 상태를 잃지
  않고 `Requeue_requested`를 거쳐 `Requeued`로 올린다. 판정은 소유 lane이 그 후보
  판정을 durable하게 적용·소비할 때만 넘어가고, 전달 실패는 마지막 실패 증거를 남길
  뿐 후보를 소비하지 않는다. 대기 작업에는 벽시계 만료가 없다. **`Runtime` 항목과
  다른 뜻이다** — 코드가 `candidate`라는 한 단어를 두 곳에 쓴다. 여기서는 판정 대상
  게시물이고, 런타임 쪽(`Runtime_candidate_backpressure.candidate`)은 runtime 후보
  순서가 시도할 실행 후보다.
  → [Keeper_board_attention_candidate](../../lib/keeper/keeper_board_attention_candidate.mli)

**Keeper Cycle**
: 현재 상태와 event를 관찰하고 Keeper turn 실행 여부를 결정하는 서버 loop의
  한 회차. 모든 cycle이 모델 호출을 실행하지는 않는다.

**Keeper Turn**
: MASC가 하나의 Keeper 작업을 시도하는 단위. 선택한 runtime에 따라 AGENT_CORE
  Agent run 또는 공식 클라이언트의 모델·도구 실행을 사용한다
  ([`Runtime_execution.t`](../../lib/runtime/runtime_execution.mli)). MASC는 해당 레인의 결과를
  조율·기록한다.

**Terminal Reason**
: 끝난 Keeper turn의 이유를 담은 영수증 필드(`terminal_reason_code`).
  `Keeper_terminal_reason.of_wire`가 이 wire 문자열을 닫힌 합타입으로 한 번 파싱하고,
  `to_wire (of_wire s) = s`가 바이트 단위로 성립한다. 분류는 canonical producer
  바이트만 받고, 나머지는 `Unknown` escape로 간다.
  → [Keeper_terminal_reason](../../lib/keeper_runtime/keeper_terminal_reason.mli)

**Operator Disposition**
: 끝난 turn을 운영자 관점에서 분류한 (kind, reason) 쌍. `Keeper_execution_receipt.operator_disposition`이
  영수증 필드에서 파생한다. kind는 여덟이고 `keeper_execution_receipt.mli`의 `operator_disposition_kind`가
  전부다 — `Disp_pass`·`Disp_fail_open_next_runtime`·`Disp_retry_later`·`Disp_pass_next_model`·
  `Disp_operator_action_required`·`Disp_user_cancelled`·`Disp_skipped`·`Disp_unknown`.
  reason도 닫힌 집합이다. `Disp_operator_action_required`는 운영자만 고칠 수 있는 알려진 원인을
  가리키며 런타임 연속·폴백을 주장하지 않는다. 그 원인은 둘로 갈린다 — `Reason_config_invalid`는
  런타임이 provider dispatch 전에 설정값을 거부한 경우(`Keeper_terminal_reason.Config_invalid`)로
  운영자가 runtime toml을 고치고, `Reason_authorization_refused`는 provider가 권한 사유로 요청을
  거절한 경우(`Keeper_terminal_reason.Authorization_refused`)로 wire에 주간·5시간 사용량 한도가 실려
  운영자가 슬롯을 옮긴다.
  → [Keeper_execution_receipt](../../lib/keeper/keeper_execution_receipt.mli),
  [Keeper_terminal_reason](../../lib/keeper_runtime/keeper_terminal_reason.mli)

**Keeper Chat Operation**
: Keeper Owner가 접수한 메시지 실행의 durable 기록. `operation_id`로 식별하며
  `state`가 대기·실행·성공·실패·취소를 구분한다. Board 맥락 추론도 이 operation을
  제출하고, 응답의 `keeper_name`은 제출 경로가 해석한 실제 대상 Keeper다.
  접수 응답은 실행 완료를 뜻하지 않는다.

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
  새 이력을 시작하며, 첫 저장이 받아들여진 뒤 재시작을 기록한다.

**agent core Turn**
: 하나의 agent core Agent run 내부에서 provider response와 tool 실행이 진행되는 한
  단계. Keeper turn과 동일한 단위가 아니다.

**Runtime Attempt**
: Keeper turn에서 하나의 resolved runtime 후보를 실행하는 시도.

**Demotion (강등)**
: 어떤 항목을 제거하지 않고 우선순위·가시성·전송 여부만 낮추는 처분. 세 곳이 같은
  불변식을 지킨다 — 강등된 것은 사라지지 않는다.
  - 도구 결과 강등: 전송 사본에서만 blob 마커로 바뀌고 History 원본은 남는다
    (`Keeper_model_input_demotion`, RFC-0363).
  - 후보 강등: 쉬는 중이거나 실패한 runtime 후보를 세 무리(`Not_demoted` ·
    `Failed_without_rest` · `Told_to_rest`)로 나눠 뒤로 보낸다. 배제가 아니라 순서다 —
    맨 앞 후보가 쉬는 중이면 그 walk는 그 후보가 풀릴 때까지 기다린다
    (`Keeper_turn_driver.demote_unavailable_candidates`, RFC-0458 §3.4).
  - 차단 강등: 낡은 blocker를 "이전 차단"으로 낮춰 보여준다. 감추지 않는다
    (`agent-roster.ts`).
  → [Keeper_turn_driver.demote_unavailable_candidates](../../lib/keeper/keeper_turn_driver.ml)

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
  않는다. 클라이언트 턴 합계도 runtime 후보 순서를 포함한 Keeper turn 전체 합계는 아니다.

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
  단위를 분류한다.
  → [Tool_result](../../lib/tool_types/tool_result.mli)

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
  이름의 "failover"는 런타임 후보 순서를 가리키던 옛 단어의 잔재이고, 이 키는 그와
  다른 메커니즘이다 — 키 이름에 옛 단어가 남는 유일한 곳이며, 운영자 설정 파일 호환을
  위해 동결되었다.
  → [Runtime.media_failover](../../lib/runtime/runtime.mli) · [keeper_vision_tool](../../lib/keeper/keeper_vision_tool.mli)

**Lane**
: 모델이 도는 Keeper의 exact-output 작업을 위한 고정 실행 경로. `Exact_lane_run_registry.lane`
  의 생성자 넷(`Librarian`·`Hitl_auto_judge`·`Board_attention`·`Workspace_curator`)이
  `all_lanes`로 열거된다. 그 경로를 선언하는 설정은 `Exact-output route`이고,
  Keeper turn이 runtime 후보를 시도하는 순서(`Runtime Candidate Order`)와 다른 층이다.
  → [Exact_lane_run_registry](../../lib/exact_lane_run_registry.mli)

**Runtime Candidate Order (런타임 후보 순서)**
: Keeper turn이 배정된 runtime이 실패했을 때 시도할 runtime 후보의 순서 있는 목록.
  `[runtime.lanes.<이름>]` 표가 이름을 붙이고 `Runtime_lane.t`(`{id; candidates}`)가
  그 값이다. TUI 화면은 "runtime candidate order"로 읽는다.
  `[runtime].media_failover`(vision fleet)와
  exact-output lane의 slot 우선순위 failover(`docs/spec/05-keeper-agent.md:394`)는
  런타임 후보 순서와 별개 축이다.
  → [Runtime_lane.t](../../lib/runtime/runtime_lane.mli)

**Standalone Lane**
: TUI의 `MASC Lanes · Standalone` 표가 그리는 읽기 전용 LLM lane 관찰. 기존
  admission·run registry를 서술할 뿐 제어 동작을 싣지 않는다. 위의 Lane
  (고정 실행 경로) 생성자 넷에 `Runtime.verifier_exact_lane_id`("Verifier")를
  더한 다섯 lane을 그린다 — Lane은 그 작업이 무엇을 실행할 수 있는지의 고정
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
  않은 상태다. lane은 다섯이고 `server_standalone_lane_projection.ml`의
  `lane_specs`가 전부다 — `Board_attention`(Board lane)·`Hitl_auto_judge`·
  `Librarian`·`Workspace_curator`·verifier exact lane. 앞의 넷은
  `Exact_lane_run_registry.lane`의 생성자 전부이고 `all_lanes`로 열거된다.
  → [tui_decode.mli](../../lib/tui_decode.mli)

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
  글의 `content_updated_at`은 생성 또는 제목·본문·작성자가 실제로 바뀐 시각이다.
  댓글·투표·고정 등 일반 활동이 갱신하는 `updated_at`과 구분한다.
  같은 내용으로 다시 저장하면 `content_updated_at`은 유지한다.
  `Board_post_updated`는 실제 편집 저장이 성공한 뒤 발행한다. 게시글 ID와
  `content_updated_at`이 같은 편집은 한 사건이며, 뒤의 편집은 새 사건이다.

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

**Autoboot Exclusion Reason (자동 부팅 제외 이유)**
: 설정상 부팅 가능한데도 `bootable_keeper_names`에서 의도적으로 빠진 Keeper의
  닫힌 이유. `Paused`·`Declarative_autoboot_disabled`·`Autoboot_disabled`·
  `Shutdown_admission_fence` 넷이다. 앞의 셋은 Keeper 설정에서 유도되지만
  `Shutdown_admission_fence`는 아니다 — durable shutdown operation이 아직 그
  Keeper의 admission을 소유하고 있어, autoboot 호출자가 boot-scan shutdown
  inventory(`blocked_keeper_names`)를 들고 표시한다. boot recovery가 회수
  가능한 operation을 같은 bootstrap에서 정산하면 supervisor의 주기 pass가 그
  Keeper를 등록한다. 배제된 Keeper는 excluded list에 찍는다 — 2026-07-21
  wedge에서는 한 Keeper가 boot set과 excluded list 양쪽에서 조용히 빠져
  장애가 autoboot 보고에서 보이지 않았다.
  → [keeper_runtime.mli](../../lib/keeper/keeper_runtime.mli)

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
  checkpoint 이력이 아니다. 코드 이름은 `Keeper_librarian_context`다. 정리 하나가
  pocket이고, 저장된 현재 pocket 묶음은 Working Context다.
  `[typesafeai] context_review = true`이면 새 정리 전체의 의미 보존을 JEV Choice로
  평가한다. 원본의 요청·제약·약속과 다음 행동 제안을 함께 보며, 합치는 이전 정리의
  참조 원문도 포함한다. `needs_revision`이면 새 정리의 게시만 보류한다. 미평가·실패·
  `insufficient_evidence`는 검증 통과가 아니며 기존 저장 검사를 유지한다.
  실행 상세의 `context_review`는 판정, `context_write`는 정리 저장 결과다.
  `outcome_unconfirmed`는 저장 도중 중단되어 저장 여부를 확인하지 못한 상태다.
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

**Message**
: History의 한 항목. role(`System`, `User`, `Assistant`, `Tool`) 하나와 content
  조각의 목록으로 이뤄진다. 조각은 아홉 가지다: `Text`, `Thinking`,
  `ReasoningDetails`, `RedactedThinking`, `ToolUse`, `ToolResult`, `Image`,
  `Document`, `Audio`. 정본은 `packages/agent_core/lib/llm_provider/types.mli`의
  `content_block`이다.

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
  (`Halved_after_refusal`·`Evicted_after_refusal`).
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

  저장된 응답 관측의 범위는 당시의 사실이다. 현재 카탈로그에서 그 runtime을
  지우거나 바꾸어도 이 사실을 취소하지 않으며, 현재 History의 같은 위치·digest로 검증한다.
  원장이 없으면 보관 중인 기록에서 같은 trace의 마지막 응답 관측까지 거슬러 찾는다.
  응답 없는 기록이 쌓여도 이 관측을 가리지 않는다. 재시도가 같은 turn 번호를 쓰면
  나중에 저장한 응답 관측을 선택한다. 다음 요청 예측도 같은 reader를 쓴다.
  RFC 코퍼스는 이 자리를 **앞머리**라 부른다.

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
  `No_atom_history` 줄은 공식 클라이언트 turn을 가리킨다. `Stale_noop`은
  `Keeper_checkpoint_store`의 저장 결과 `Stale_noop`(더 새 writer가 앞서 canonical
  Checkpoint를 그대로 둔 성공적 no-op)과 이름을 공유하지만 다른 값이다 — 하나는
  저장 결과, 하나는 turn 경계 위치다.
  → [Keeper_turn_boundaries](../../lib/keeper/keeper_turn_boundaries.ml)

**Turn Start (턴 시작 위치)**
: 씨앗도 흡수 지점도 없을 때 이번 요청이 어디서 시작하는가를 정한 값
  (`Keeper_carried_front.turn_start`). 닫힌 둘이고 wire `kind`가 이름이다 —
  `Turn_boundary { end_atom }`(`turn_boundary`), `Turn_boundary_unknown { reason }`
  (`turn_boundary_unknown`). `Turn_boundary`는 이 History에서 마지막으로 끝난 turn의
  경계이고, 그 경계를 지금 History와 digest로 맞춰 본 값만 쓴다. 끝난 turn이 없는
  History에서는 0이라 갖고 있는 전부를 싣는다(새 Keeper의 짧은 History). 경계
  저장소를 못 읽었거나 어떤 경계도 지금 History와 맞지 않으면
  `Turn_boundary_unknown`이고, 요청은 가장 새 Atom 하나만 싣는다 — 모르는 시작을
  0으로 접어 History 전체를 보내지 않는다. 요청이 어디서 시작했는지는 `origin`이
  따로 적는다(`Turn_start`·`Turn_start_unknown`).
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
  `masc-librarian-continuity capture/restore`는 같은 파일 경계를 검증한다.
  → [Librarian_continuity_snapshot](../../lib/librarian_continuity_snapshot.mli)

**Working State (대화 작업 상태)**
: Librarian이 완료된 대화와 이전 상태에서 정리한 작업·제약·결정·미해결 사항
  (`Keeper_librarian.selection.working_state`). Continuity Snapshot이 담는
  "이어서 할 일의 설명" 절반이며, 같은 파일에 저장된 정확한 대화 범위와 한 쌍이다.
  큐 원본을 정리한 Working Context(`working_contexts`)나 장기 Memory facts와 다르다.
  모델의 출력만으로 범위가 소비된 것은 아니며, pair 저장과 소비 시 이력 검증이
  필요하다. 연속성 회차가 만든 이 값은 `Keeper_librarian_continuity.commit`의
  `working_state` 인자이고 Continuity Snapshot 파일에 저장된다. 턴은 이 값이 덮는
  atom들을 보내는 대신 이 값을 보낸다. 저장본이 덮는 범위와 이 값이 대신하는 범위는
  같다.
  요약을 못 실은 띠는 닫힌 셋이다(`working_state_left_out`) — 요약이 Atom을
  밀어내는 경우, 실을 turn이 없는 경우, 요약이 창에 안 맞는 경우다. 관측 이름과
  카운터는 그 카탈로그를 따른다(`keeper_official_client_host.mli`). 요약이 빠져도
  turn은 거절하지 않고 WARN으로 알린다.
  → [Keeper_librarian.selection](../../lib/keeper/keeper_librarian.mli) · [keeper_librarian_continuity](../../lib/keeper/keeper_librarian_continuity.mli)

**Continuity Synthesis Observation (대화 요약 진행 관측)**
: 이번 서버 실행에서 Librarian이 마지막으로 선택한 Atom 구간, 그때 확인한
  완료 경계, 실행·저장·중단 상태. `context_cycle.synthesis`와 TUI Memory 화면에
  표시한다. 일반 Memory 소비자의 `drained`와 별개이며 다음 실행을 통제하지 않는다.
  `no_source`는 새로 읽을 완료 구간을 얻지 못했다는 뜻으로, 전체 요약 완료를
  증명하지 않는다. 구간이 없거나 관측 전이면 알 수 없음으로 표시한다.

**Librarian Round (Librarian 회차)**
: Librarian이 한 번 도는 일. Keeper마다 따로 돌고, 같은 신호(서버 기동·턴 끝·받은 일
  변경)에 깨어난다. 두 가지가 있다.
  - durable 회차(`Keeper_librarian_durable_consumer`): 끝난 턴을 읽어 Memory OS에 적고
    읽은 위치(Read Position)를 옮긴다. Agent Core 턴은 checkpoint의 atom으로, 공식
    클라이언트 턴은 그 trace의 history 파일에서 `turn_ref`가 가리키는 조각으로 읽는다.
    두 위치(atom 위치·공식 클라이언트 위치)를 각각 옮기며, `commit`이 Memory OS snapshot
    커밋을 보고할 때만 옮긴다.
  - 연속성 회차(`Keeper_librarian_continuity`): 스냅숏이 덮은 앞부분을 다시 쓰는 회차.
    완료된 대화 구간을 요약해 Continuity Snapshot을 만든다. 커밋은 durable 회차의
    위치를 바꾸지 않는다.
  두 회차는 따로 밀리고(Continuity Lag), 실패 뒤 범위를 좁히는 규칙을 공유한다(RFC
  librarian-lifecycle §4.3). durable 회차는 실패 표식을 루프 메모리에 두고 가장 오래된
  한 턴으로 좁힌다. 연속성 회차는 좁힌 폭(Continuity Width)을 다음 회차로 넘긴다.
  → [keeper_librarian_durable_consumer](../../lib/keeper/keeper_librarian_durable_consumer.mli) · [keeper_librarian_continuity](../../lib/keeper/keeper_librarian_continuity.mli)

**Continuity Lag (연속성 밀림)**
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

**Continuity Width (연속성 회차의 폭)**
: 연속성 회차가 한 번에 읽을 수 있는 atom 수의 상한. 크기 때문에 거절당한 회차가 좁힌
  값을 다음 회차가 이어받는다. (keepers dir, keeper)별로 그 값을 잰 trace와 함께 루프
  메모리에 둔다(`keeper_librarian_queue_refresh.ml`의 `limited_widths`). trace가 바뀌면
  atom 번호가 다시 매겨지므로 비교하지 않고 새 값으로 바꾸고, 같은 trace 안에서는 더
  좁은 값만 남는다. 끝 atom이 아니라 폭을 남기므로 커밋한 회차 다음에는 같은 자리가
  아니라 그다음 자리를 읽는다. 좁히는 것은 작은 요청이 같은 벽을 피할 수 있는 실패뿐이고,
  그 판정은 `walk_shows_size`(`keeper_librarian_runtime.mli:47`)가 들고, 원인별 판정
  규칙은 RFC-librarian-lifecycle §4.3이 정한다. 판정은 걸음의 마지막 슬롯이 아니라 걸음
  전체에 묻는다. 폭은 backlog를 끝까지 읽었을 때(`Drained`)만 푼다. 좁힌 커밋 한 번은
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

**Working Context**
: Librarian이 Keeper가 받은 요청을 묶어 저장한 현재 작업 맥락. 각 항목은 받은 일
  정리가 낸 pocket(`Keeper_librarian_context.pocket`)이고, 현재 묶음은
  `Keeper_librarian.selection.working_contexts`다. Memory OS와 같은
  operator-config Keeper 이름 범위이므로 같은 이름의 Keeper는 cluster 간에 공유한다.
  cluster별 Librarian Read Position과는 별개의 상태다.

**Fact**
: Memory OS의 기억 하나. 문장(`claim`), `category`, 처음·마지막으로 본 시각,
  `origin`, `basis`로 이뤄진다. id 필드는 없고 Memory ID는 `claim` 글자의
  SHA-256이다. 글자가 하나라도 다르면 다른 Fact다.

**Origin**
: Fact를 누가 적었나. `authored`는 Keeper가 `keeper_memory_write`로 직접 적은 것,
  `injected`는 Librarian이 대화에서 뽑아 넣은 것이다.

**Basis**
: Fact가 무엇에 근거하나. `observed`는 읽은 곳(자기 대화 또는 Board 글)을 갖고,
  `derived`는 유도(derivation)를 하나 이상 갖고, 유도마다 전제가 된 다른 Fact의
  Memory ID를 갖는다. 전제가 모두 살아 있는 유도가 하나라도 남아 있으면 `derived`
  Fact는 유지되고, 그런 유도가 하나도 없으면 무효가 된다.

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
  History를 읽는 경로의 구현 진척은 `RFC-librarian-lifecycle` §8을 본다.
  Agent Core의 읽은 위치가 저장되면 같은 wake에서 남은 이력을 계속 읽는다.
  읽을 것이 없거나 읽기·저장에 실패하면 멈추고, 실패한 범위는 다음 신호에서 다시 읽는다.
  매 회차 설정을 확인하므로 꺼진 동안에는 다음 범위를 읽지 않는다.
  이 이름은 프롬프트 category `librarian`(`config/prompts/librarian.md`,
  `workspace_memory_curator.md`)과 CLI `masc-librarian-replay`·`masc-librarian-continuity`가
  공유한다. 셋은 서로 다른 것이고, 어느 것도 Skill이 아니다. `Tool Librarian`의
  현재 지위는 [Skills](../SKILLS.md) 도입부가 정한다.

**Librarian Replay**
: `masc-librarian-replay` CLI. 라이브 워크스페이스의 turn-boundary 로그와 checkpoint에
  Librarian 읽기 규칙(`Keeper_librarian_range.select`/`slice`)을 오프라인으로 돌려,
  backlog가 몇 회차에 걸리는지·회차마다 몇 atom을 나르는지·중복 atom이 있는지를
  센다(RFC librarian-lifecycle §9). 메시지 본문은 출력하지 않고 count·atom 번호·digest만
  낸다. 아무것도 쓰지 않는다 — progress 파일·boundary line·checkpoint 모두 없다.
  서버의 Librarian 실행이 아니라 그 읽기 규칙의 측정 하네스다.
  → [masc_librarian_replay](../../bin/masc_librarian_replay.ml)

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
