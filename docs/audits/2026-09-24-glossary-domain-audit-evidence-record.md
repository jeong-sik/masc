# 용어집·도메인 점검 — 2026-09-24

`docs/spec/00-glossary.md` 를 코드와 다시 맞춰 읽었다. 대상은 Board, Task, Goal, Context,
Keeper, Librarian, Memory, HITL, 접근 제어, Multi Lane, Schedule, Runtime 후보 순서다.

09-23 기록 둘([용어집과 도메인 결합](2026-09-23-glossary-domain-coupling.md),
[1주일 흐름과 Tick 닫힘](2026-09-23-week-flow-and-tick-closure.md))이 적은 것은 다시 쓰지 않는다.
그 기록의 열린 칸이 지금 어떤지와, 그 기록에 없는 것만 적는다.

## 공통 헤더

- 날짜(ISO8601): 2026-09-24T10:30:00+09:00
- 작성자: Claude
- 결정 ID: glossary-domain-audit-20260924
- 적용 대상: MASC `origin/main 203322c692`, `docs/spec/00-glossary.md`. 라이브 store(`<base-path>/.masc`)는 읽지 않았다
- 결정 상태: 용어집 문장 고침은 이 PR 에 담았다. 코드 변경은 제안으로만 남긴다

## 0. 09-23 기록에서 바뀐 것

- 09-23 결합 기록은 "TUI 에 Team 블록은 없다" 고 적었다. 지금은 있다(`bin/masc_tui_overview_team.mli`, RFC-0464, 용어집 Team 블록 항목).
- 09-23 이 제안한 `Keeper_memory_lane` → `Keeper_librarian_queue` 개명은 쓰면 안 된다.
  `Keeper_librarian_queue_signal`·`Keeper_librarian_queue_refresh` 가 이미 "queue" 를 Keeper **이벤트** 대기열 뜻으로 쓴다
  (`keeper_registry_event_queue.ml:17`). 겹치지 않는 이름은 `Keeper_librarian_drain` 같은 것이다.
- 09-23 이 "열림" 으로 남긴 PR 은 모두 병합됐다: #38096(401 강등), #38047(Goal `Verifying` 에서 Drop·Reopen),
  #38042(purge 뒤 Librarian 다시 넣기), #38048(같은 기억 id 다시 쓰기), #38045(경로 표시와 걸음), #38188, #38043, #38053.
  #38205(held 목록)는 #38304 가 TUI 만 고치고 닫혔고, 남은 것은 #38411(열림)이다.
- 09-23 결합 제안 가운데 끝난 것: Karma 항목과 11-board §9, Evidence Reference·Working Context 합치기, Producer, Gate 문장.
  `board:`·`fusion:` 근거는 한 번 해석하도록 바뀌었지만(`workspace_verification_store.ml:117-125`) 저장은 여전히 `string list` 다.
  나머지 제안(TUI Agenda 가 backlog 를 직접 읽음, Librarian 이 Keeper 메타 전체를 읽음, Runtime → keeper_runtime,
  Board 판정 후보가 `board_signal` 을 통째로 저장, Schedule 소비자가 Keeper 내부를 부름, Goal → Task 연결 정리 등)은 그대로 열려 있다.

## 1. 한 개념에 이름이 둘 (중복 개념)

| # | 이름들 | 판정 | 근거 | 처리 |
|---|---|---|---|---|
| D1 | Librarian Round / Librarian Pass End | 같은 단위다. 둘 다 "회차" 로 옮겼다. 코드는 `keeper_librarian*` 에서 pass 139번, round 38번이고, wire 와 타입은 pass 다(`memory_librarian_pass_end`) | 용어집 Librarian Round·Librarian Pass End, `keeper_librarian_queue_refresh.mli:1` | 제안: 항목 이름을 **Librarian Pass** 로 맞춘다. #38511 이 같은 항목을 고치고 있어서 이 PR 에서는 뺐다 |
| D2 | Read Position / librarian progress / consumer cursor | 같은 값에 이름이 셋이다(파일 `librarian-progress.json`, 모듈 `Keeper_librarian_progress`, `keeper_librarian_continuity.mli:49,71` 의 "consumer cursor") | 위 파일들 | 이름은 Read Position 하나로 둔다. 그리고 항목이 공식 클라이언트 위치(`librarian-official-progress.json` 의 `boundary_line`, turn-boundary 줄 번호)를 빠뜨렸다 → **이 PR 에서 더했다** |
| D3 | `Runtime.exact_lane`(다섯) / `Exact_lane_run_registry.lane`(넷) | 같은 개념에 닫힌 타입이 둘이고, wire 표도 손으로 두 번 적었다 | `runtime.mli:462-475`·`runtime.ml:946-956`, `exact_lane_run_registry.mli:4-20`·`.ml:133-141` | 코드 제안 C1. 용어집 쪽은 #38453 이 고친다 |
| D4 | Route: `[runtime].default`, Keeper 배정, Fusion 좌석 route | 셋 다 "lane 이름 또는 runtime id" 인 타입 없는 문자열이고 `Runtime.resolve_assignment` 가 푼다. 용어집에는 Fusion Route 만 있다 | `runtime.mli:435-441,597-611,765-777`, `fusion_seat.ml:13` | 제안: **Runtime Route** 항목을 새로 두고 Fusion Route 가 가리키게 한다. 코드는 C2 |
| D5 | Gate / 도구 승인 | 다르다. Gate(`Keeper_gate_mode`: `Always_allow`·`Auto_judge`·`Manual`)는 턴을 막지 않는다. 도구 승인(`Keeper_tool_approval_mode`: `Auto`·`Yolo`)은 채팅 창에서 도구 호출 하나를 두고 운영자에게 묻고, 턴 fiber 가 답을 기다린다. 용어집은 앞의 것만 적었다 | `keeper_tool_approval_mode.mli:1-26`, `keeper_tool_approval_registry.mli:1-8` | **이 PR 에서 Gate 항목에 "다른 것" 을 더했다** |
| D6 | "gate" 가 붙은 다른 모듈 | `lib/gate`(Slack·Discord·Telegram 커넥터), `Keeper_librarian_absorb_gate`, `Keeper_lifecycle_gate`, `Keeper_unified_turn_phase_gate`, `Shell_command_gate` 는 Gate 와 다른 것이다 | 각 모듈 `.mli` 머리 | 제안: Gate 항목에 Lane 항목 같은 경계 목록을 둔다 |
| D7 | Task Claim / Memory `claim` | 다르다. Memory 쪽 `claim` 은 Fact 의 문장 필드인데, 용어집 Dropped/Supersedes/Absorbs 부분은 "새 claim" 을 "새로 적자고 낸 Fact" 뜻으로 쓴다 | 용어집 Fact·Claim | **이 PR 에서 Claim 항목에 "다른 뜻" 을 더했다** |
| D8 | Keeper Cycle / Keeper Turn | 용어집은 둘을 가른다. 코드는 섞는다: `Keeper_unified_turn.run_keeper_cycle` 이 turn 결과를 돌려주고(`keeper_unified_turn.mli:214-232`), `Keeper_gate.cycle_grant` 는 "턴 하나 안" 을 뜻한다(`keeper_gate.mli:177-181`) | 위 | 코드 제안 C5 |
| D9 | Runtime Attempt / provider attempt | 같은 것이다 | `runtime_attempt_fsm.mli:1`, `Keeper_provider_attempt_effect` | **이 PR 에서 Runtime Attempt 항목에 다른 이름을 적었다** |
| D10 | Turn 항목의 "단위 넷" | Turn Configuration Error 는 단위가 아니라 실패 원인이다 | 용어집 Turn | **이 PR 에서 고쳤다** |
| D11 | `(end_atom, last_atom_digest)` 쌍 | 같은 값("Atom 위치")을 레코드 여섯 곳에서 따로 선언한다 | `keeper_librarian_progress.mli:31-37`, `keeper_turn_boundaries.mli:94-96`, `keeper_memory_os_current.mli:111-113`, `librarian_continuity_snapshot.mli:7-18`, `keeper_librarian_range.mli:21` | 코드 제안 C6. wire 형식을 일부러 따로 둔 것일 수 있어 확신 중간 |
| D12 | Official Client Lane / Runtime execution | 같은 갈림을 양쪽에서 설명한다. Official Client Lane 은 `Runtime_execution.t` 의 공식 클라이언트 갈래다 | `runtime_execution.mli:1-8` | 제안: Official Client Lane 항목이 Runtime execution 을 가리키게 한다 |
| D13 | "lane" 의 일곱째 뜻 | 기계·버퍼 lane(`Msx_lane`, `Dos_lane`, `Browser_lane`, `Slack_lane`)과 Lane Add-on 의 "Lane 행" 이 Lane 항목 경계 목록에 없다 | `lib/msx_lane/msx_lane.mli:1`, `lib/slack_lane/slack_lane.ml:1` | 제안: Lane 항목 이름을 **Exact Lane** 으로 바꾸고 경계 목록에 더한다. #38453 이 같은 항목을 고치고 있어 이 PR 에서는 뺐다 |

다른 것으로 확인한 쌍: Turn Start / Turn Boundary Position / Carried Front(용어집이 이미 경고한다), `authorization_source` / Completion Authority,
Fact / Memory Event, Continuity Snapshot / Working State(Working State 는 Snapshot 의 한 칸이다. 09-23 이 이미 적었다).

## 2. 헷갈리거나 어려운 말

| 자리 | 문제 | 처리 |
|---|---|---|
| Demotion 항목 "맨 앞 후보가 쉬는 중이면 그 walk는 그 후보가 풀릴 때까지 기다린다" | 쉬라는 말을 들은 후보는 맨 뒤로 가므로(`keeper_turn_driver.ml:175-209`), 이 말은 모든 후보가 쉬는 중일 때만 맞다. 읽으면 "머리 하나가 쉬면 전체가 멈춘다" 로 들린다 | **이 PR 에서 고쳤다** |
| Exact lane 이름 `Hitl_auto_judge` | 이름에 HITL(사람)이 들어 있지만 lane 은 모델을 부른다(`lib/keeper/hitl_summary_worker.mli:1`). 이 lane 이 Gate `Auto_judge` 판정까지 맡는지는 끝까지 따라가지 못했다 | 확인 필요. 코드 이름 변경은 라이브 `[runtime.exact_output_lanes.hitl_auto_judge]` 표를 바꿔야 해서 제안만 한다 |
| "Exact-output route" | Failure Route·Fusion Route 와 "route" 가 겹치고, 실제로는 exact lane 선언(`exact_output_lane_decl`)이다 | 제안: "Exact Lane 선언" 으로 부른다 |
| "원장" 27번, "영수증" 12번, "귀속" 7번, "투영" 6번 | 한자어가 몰린 항목은 Continuity 절이다. 코드 이름을 옮긴 자리라 이번에는 두었다 | 다음 용어집 정리 때 항목별로 본다 |

## 3. 코드 목록과 어긋난 항목

| 항목 | 용어집 | 코드 | 처리 |
|---|---|---|---|
| PR Reader | 이유 셋 | `Reader_declaration_invalid` 까지 넷(`server_repository_pulls.mli:109`) | **이 PR 에서 고쳤다** |
| Transcript Tail Recovery | `Recovering_requests` 부팅 단계 | 그런 생성자는 없다. `Recovering_persistence`(`server_bootstrap_loops.mli:21`, `.ml:737` 에서 들어가고 `:778` 에서 복구) | **이 PR 에서 고쳤다**. 같은 잘못된 이름이 `keeper_transcript_tail_recovery.mli:9` 주석에도 있다(코드라 두었다) |
| Continuity Width | `keeper_librarian_runtime.mli:47` | 필드는 `:71` 이고 `:47` 은 `type served_slot =` | **이 PR 에서 줄 번호를 빼고 필드 이름으로 적었다** |
| Seed | `source` 다섯 | `Turn_start_after_librarian_refusal` 까지 여섯(`keeper_carried_front.mli:38-57`) | 이 PR 에서 뺐다. #38341 이 바로 아랫줄에 문단을 넣어서 충돌한다. #38341 뒤에 한 줄 더하면 된다 |
| Operator Disposition | "그 원인은 둘로 갈린다" | 셋째 `Reason_official_client_recovery_required`(`keeper_execution_receipt.ml:171`) | #38442 가 "둘" 을 지운다. 셋째 이름은 그 PR 뒤에도 없다 |
| Carried Front | origin 다섯 | `Past_librarian_point` 까지 여섯 | #38497 이 고친다. 다만 #38497 도 "Librarian 지점이 있으면 원장·씨앗은 읽지 않는다" 문장을 남겨 `Past_librarian_point` 와 맞지 않는다 |
| Turn Start | wire `kind` `turn_boundary`·`turn_boundary_unknown` | 그런 wire 문자열이 없다(`turn_start_to_string` 은 `boundary:`·`unknown:`) | #38421 이 고친다 |
| Lane / Standalone Lane | 같은 것을 다섯·넷으로 다르게 센다 | 위 D3 | #38453 이 고친다 |

맞는 것으로 확인한 항목(정의 타입과 하나씩 대조): Exit Reason, Keeper Fleet Blocker, Terminal Reason, Operator Disposition kind 여덟,
Failure Route, Demotion 세 값, Official-client Session Recovery, Turn Configuration Error, Usage Scope, Tool Call Outcome,
Execution Disposition, Standalone Lane 상태·구성, Keeper Health Reading, Reasoning Effort, Identity Row State, Detail State,
Connector Connection, Board·Karma·Flair·Hearth, Broadcast, Task 상태 여섯, Goal phase 다섯, Schedule 상태 일곱·반복 넷,
Fusion 항목들, Gate 세 값, HITL Delivery Occasion, Task Lifecycle 항목들, Skill State, Repository Status,
Autoboot Exclusion Reason, Checkpoint Purge, Turn Boundary Position, Continuity Request Observation, Working State,
Librarian Range Receipt, Memory OS 항목들, Library, Librarian Pass End(종결 여섯·실패 아홉), Board 판정 항목들, Keeper Chat Operation.

접근 제어는 용어집에 항목이 아직 없다(09-23 제안, 열림).

## 4. 도메인 결합 — 새로 찾은 것

09-23 기록에 없는 것만 적는다. dune `libraries`(테스트 stanza 제외)로 선을 찾고, 실제로 쓰는 이름을 `rg` 로 셌다.

| # | 선 (A → B) | A 가 실제로 쓰는 것 | 줄일 방법 | 영향 |
|---|---|---|---|---|
| C0 | Board·Schedule·Goal → `masc_workspace` (`lib/board/dune:44`, `lib/schedule/dune:24`, `lib/goal/dune:19`) | Board 는 `Workspace_utils.masc_root_dir_from` 하나(`board_paths.ml:9`). Schedule 은 `Workspace_utils`(설정·파일 잠금·JSON). Goal 은 `Workspace_utils` 와 근거 타입 하나. 그런데 `masc_workspace` 에 Task 저장소(`workspace_task*`)가 들어 있어서 셋 다 Task 를 링크한다. 09-23 의 "Board 는 Task 를 안 든다" 와 `lib/goal/dune:3-8` 주석 "중립 라이브러리만" 과 어긋난다 | `workspace_utils_{backend_setup,paths_backend,ops}` 를 중립 라이브러리(`masc.workspace_io` 같은)로 옮긴다. 끊을 곳은 둘이다: Task id 검사(`workspace_utils_ops.ml:12,47-49`), hook(`:513,552`). 근거 타입은 작은 모듈로 뺀다 | `Workspace_utils.` 호출: Board 2, Schedule 59, Goal 47 |
| C0-2 | `masc.runtime` → `masc.auth` | 접근 제어가 아니라 파일·토큰 도우미 셋(`Auth.save_private_text_file`, `generate_token`, `is_generated_token_shape`) | 세 함수를 `auth_credential_base.ml` 에서 파일·난수 도우미 모듈로 옮긴다 | auth 밖 15곳, 10파일 |
| C0-3 | `masc.runtime` → `masc.fusion_core` | 설정 저장 때 `[fusion]` 절 검사 하나(`runtime.ml:2695-2718`) | `validate_save_text` 가 절 검사 목록을 부르는 쪽에서 받는다 | 2곳 |
| C0-4 | 최상위 감싸개 `lib/board_core{,_persist,_payload,_classify}.ml` | `include Masc_board_handlers.X` 로 Board 내부 모듈을 `masc` 라이브러리에 다시 내보내 `(wrapped true)` 를 무른다. Board 밖 운영 코드 호출은 classify 1곳뿐이다 | 감싸개를 지우고 테스트는 `Masc_board_handlers.X` 를 쓴다 | 테스트 5파일 |
| C0-5 | `masc.keeper_checkpoint_ref` → `masc.keeper_registry` | `Keeper_id.Trace_id` 하나 | `keeper_id` 를 자기 라이브러리로 뺀다 | 약 6줄. 이득 작음 |

## 5. 상태 기계 Tick 추적

"닫힘" 은 운영자가 손대지 않아도 끝 상태나 대기에 이르거나, 횟수에 상한이 있는 재시도라는 뜻이다.
"열림" 은 운영자가 손대기 전까지 같은 실패를 되풀이하거나 멈춰 있는 갈래다.

### 5.1 Librarian 회차

| tick | 일어나는 일 | 근거 |
|---|---|---|
| 1 | 턴 끝·이벤트 대기열 변경·받은 일 정리 커밋이 신호를 보낸다. 신호는 한 줄로 묶인다. 부팅과 purge 도 다시 넣는다(#38042) | `keeper_agent_run_post_turn_memory.ml:93`, `keeper_registry_event_queue.ml:17`, `keeper_librarian_queue_refresh.ml:482-519` |
| 2 | 이 프로세스가 그 Keeper 의 실패 표식을 쥐고 있으면 턴 하나(`To_first_cut_point`)만, 아니면 안 읽은 전부를 읽는다 | `keeper_librarian_durable_consumer.ml:1154,1159` |
| 3 | 읽은 위치 → 공식 클라이언트 위치 → trace 넘김 순서로 범위를 고른다. 위치를 증명 못 하면 회차를 끝낸다 | `durable_consumer.ml:643-795`, `keeper_librarian_range.ml:233,285` |
| 4 | Memory 가 이미 커밋된 앞부분을 들고 있으면 모델을 안 부르고 위치만 적는다 | `durable_consumer.ml:835-876` |
| 5 | 모델을 부르고 답을 검사한다. 이미 있는 id 를 다시 쓴 답은 "유지" 로 읽는다(#38048). 다른 형식 오류는 답 전체를 거절한다 | `keeper_librarian.ml:357-374,740-746` |
| 6 | Memory 를 먼저 쓰고 위치를 옮긴다(`Eio.Cancel.protect`) | `durable_consumer.ml:1031-1058` |
| 7 | 진전이 있으면 다시 읽고, 읽을 것이 없으면 `Drained` 로 표식을 푼다 | `queue_refresh.ml:141-157` |
| C | 연속성 회차는 크기 때문일 때만 폭을 좁히고, CLI 가 알려 준 한도로 줄이는 재시도는 끝 atom 이 줄어들기만 해서 멈춘다 | `queue_refresh.ml:340-414` |

판정: 회차 하나는 닫힌다(실패한 신호마다 후보 걸음 한 번). **신호를 넘어서는 세 갈래가 열려 있다.**

1. 늘 실패하는 턴 하나. 크기가 모든 slot 보다 큰 턴이나 늘 형식이 틀리는 턴이면, 실패 표식이 회차를 그 턴에 묶는다(`keeper_librarian_range.mli:30-32`). 건너뛰는 길이 없어 신호마다 걸음 한 번을 더 쓰고 Read Position 은 움직이지 않는다.
   가장 작은 방향: 더 나눌 수 없는 턴이 크기나 출력 판정으로 실패하면 "못 읽은 턴" 을 타입으로 적은 영수증을 커밋하고 위치를 옮긴다. 그 턴은 흡수 안 된 턴으로 남긴다.
2. 증명할 수 없는 읽은 위치. `Position_mismatch`(`keeper_librarian_range.ml:285`), `Position_not_in_history`(`durable_consumer.ml:621`), `Progress_boundary_missing`, `Range_end_boundary_missing` 는 모든 회차를 멈춘다. 새 trace 나 운영자가 `librarian-progress.json` 을 고쳐야 풀린다(09-23 lane-smith 사례).
   가장 작은 방향: 위치가 지금 checkpoint 에 없고 Memory 범위 영수증이 흡수한 곳을 증명하면 기준점을 다시 잡는 타입 단계를 둔다.
3. 공식 클라이언트 줄의 `Official_stop` 과 `Counterpart_interval_non_monotone`(`durable_consumer.ml:1080-1106`). 둘 다 운영자만 풀 수 있고, 각자의 문서가 그렇게 적는다(`keeper_librarian_range.mli:185-192`). 설계대로다.

확신: 코드 경로 High, 라이브 빈도 Medium(로그로 세지 않았다).

### 5.2 Keeper 턴과 Runtime 후보 걸음

| tick | 일어나는 일 | 근거 |
|---|---|---|
| 1 | heartbeat cycle 이 Owner 자리에서 돈다 | `keeper_heartbeat_loop_cycle.ml:86-113` |
| 2 | lane 후보를 선언 순서로 놓고 강등으로 세 무리(`Not_demoted` → `Failed_without_rest` → `Told_to_rest`)로 나눈다. 빼는 후보는 없다 | `keeper_turn_driver.ml:175-209,1733-1750` |
| 3 | 후보 k 를 보낸다. provider 가 답했을 때만 그 후보의 실패 흔적을 지운다 | `keeper_turn_driver.ml:734-765` |
| 4 | 실패를 route 로 분류한다. 429 는 rate limit, HardQuota 는 quota 창, 5xx·네트워크·타임아웃·529 는 실패 흔적 | `keeper_turn_driver.ml:841-876`, `keeper_runtime_failure_route.ml:359` |
| 4a | 401·403 과 다른 `Rotate_now` 는 흔적을 안 남기고 이번 턴에서만 다음 후보로 간다. 다음 턴은 머리부터(#38096) | `keeper_turn_driver.ml:877-899` |
| 5 | 남은 후보를 다시 강등하고 다음으로 간다. 목록은 한 칸씩 줄어든다 | `keeper_turn_driver.ml:910,1004` |
| 6 | 후보가 다 떨어지면 넘침이 있었으면 넘침, 아니면 "후보 소진" 으로 턴을 끝낸다 | `keeper_turn_driver.ml:672-681,1027-1071` |
| 7 | 다음 cycle: rate limit·quota 면 `release_at` 까지(상한 `rate_limit_backoff_cap_sec`) 기다리고, 그 밖은 평소 주기로 돈다. 실패한 턴의 자극은 대기열에 남는다(`Batch_no_action`) | `keeper_turn_driver.ml:395-431`, `keeper_heartbeat_loop.ml:223-239,470-475` |

판정:
- 턴 하나 안의 걸음은 닫힌다. 상한은 lane 후보 수이고, 그 안의 줄이기·반 접기는 값이 한쪽으로만 움직여 멈춘다. 확신 High.
- 401 순환은 #38096 으로 닫혔다. 확신 High.
- **열림(결정된 설계)**: 5xx·타임아웃·네트워크·529 로 강등된 후보는 그 후보가 답하거나 프로세스가 다시 뜰 때만 풀린다(`runtime_candidate_backpressure_state.ml:27-43`). fallback 이 답하는 동안 머리는 다시 안 불린다. RFC-0458 §3.4 가 이 값을 운영자 결정으로 적었다.
- **열림**: 연속 실패 턴 수에 상한이 없다. `Turn_failed { consecutive }` 는 수만 센다(`keeper_state_machine.ml:79-87`). 모든 후보가 계속 실패하는 lane 은 cycle 마다(자극이 오면 더 빨리) 끝없이 다시 돈다. 확신 High.

### 5.3 Goal 검증

| tick | 일어나는 일 | 근거 |
|---|---|---|
| 1 | `Request_complete`: 증명 대기 행을 먼저 쓰고 `Executing` → `Verifying`, verifier 를 깨운다 | `goal_phase.ml:160`, `workspace_goals.ml:691-700,856-879` |
| 2 | 검사가 `Verifying` Goal 을 한 번에 넷까지 잡는다 | `goal_verification_agent.ml:83-108,528,646-671` |
| 3 | `verifier_exact` slot 을 차례로 걷는다. 상한은 slot 수 | `task/anti_rationalization.ml:549-667` |
| 4a | 증명 통과: `Awaiting_confirmation`, 판정을 fleet 에 알린다 | `goal_phase.ml:176`, `workspace_goals.ml:498-530,581-631` |
| 4b | 증명 반박: `Executing` 으로 돌아간다 | `goal_phase.ml:177` |
| 5 | 사람이 `Confirm_completion` → `Completed` | `goal_phase.ml:196`, `workspace_goals.ml:921-950` |
| 6 | 판정자를 못 쓰거나 이유 없는 판정이거나 커밋이 거절되면 `Deferred`. 행은 남고 **다시 검사하지 않는다** | `goal_verification_agent.ml:328-336,367-371,615-636` |
| 7 | `Verifying` 에서 Drop·Reopen 이 된다(#38047). 진행 중 검사는 abandon promise 로 취소된다 | `goal_phase.ml:179-180`, `goal_verification_agent.ml:575-588` |

판정:
- Drop·Reopen 은 닫혔다(#38047). 확신 High.
- **열림(멈춤)**: `Deferred` 갈래. 검사 루프는 `Deferred` 에서 멈추고, 한 건이라도 커밋했을 때만 다시 검사를 요청한다(`goal_verification_agent.ml:622-636`). 주인 Keeper 에게 알리는 것도 없다. 판정은 커밋 때만 알리고, 실행 기록은 운영자의 Standalone Lane 화면에만 보인다(`server_standalone_lane_projection.ml:131`). Goal 은 Keeper 가 우연히 다시 요청하거나, 다른 Goal 커밋이 검사를 다시 부르거나, 서버가 다시 뜨거나, 운영자가 옮길 때까지 `Verifying` 에 머문다. 확신 High.
  가장 작은 방향: `Deferred` 일 때 주인 Keeper 에게 Goal 사건이나 대기열 자극을 보낸다. 관문이 아니라 보이게 하는 일이다.
- 반박 → 다시 `Request_complete` 는 상한이 없다. Keeper 가 고르는 일이라 설계대로다.
- `Awaiting_confirmation` 은 사람을 시한 없이 기다린다. HITL 로 의도한 것이다.

### 5.4 Schedule 회차

| tick | 일어나는 일 | 근거 |
|---|---|---|
| 0 | runner 가 기본 15초마다 돈다. 부팅 때 `Running` 행은 `Due` 로 돌린다 | `server_bootstrap_maintenance.ml:494-584`, `schedule_store.ml:1149-1185` |
| 1 | `Scheduled` → `Due`, 또는 `expires_at` 이 지났으면 `Expired` | `schedule_domain.ml:900-910`, `schedule_store.ml:931-966` |
| 2 | `delivery=none` interval 만, 대상 대기열에 앞 회차가 있으면 붙잡는다(held) | `server_schedule_consumers.ml:1466-1507`, `schedule_runner.ml:540-555` |
| 3 | `Due` → `Running`, wake 기록을 쓴다 | `schedule_store.ml:998-1018` |
| 4 | 자극을 넣고 주인을 깨운다. 받아들여지면 다음 시각(놓친 회차는 건너뜀)이나 `Succeeded` | `server_schedule_consumers.ml:1225-1368`, `schedule_store.ml:1020-1061` |
| 4a | 메타 파일이 없으면 `Failed` | `server_schedule_consumers.ml:519-544` |
| 4b | 멈춤·중지·꺼짐·미등록이면 자극을 남기고 받아들인 것으로 친다 | `server_schedule_consumers.ml:546-608,1318-1327` |
| 4c | 등록됐지만 fiber 가 안 돌면 `Retryable_dispatch_failure` → `Due` 로 돌아가 다음 tick 에 다시 | `server_schedule_consumers.ml:1293-1317`, `schedule_store.ml:1128-1147` |
| 5 | Keeper 가 바쁘면 자극이 기다린다. 실패한 턴은 자극을 남기고 끝난 턴이 ack 한다 | `keeper_heartbeat_loop.ml:410-475,1081-1119` |

판정: 정상 경로는 닫힌다. **세 갈래가 열려 있다.** 확신: 코드 High, 빈도 Medium.

1. 4c: 등록됐지만 fiber 가 안 도는 Keeper. `Due` → `Running` → `Due` 를 15초마다 되풀이하고, `expires_at` 말고는 상한이 없다. 저장은 wake 32개로 묶이지만(`schedule_store.ml:452`) 시간은 안 묶인다.
   가장 작은 방향: 4b 처럼 받아들인다(자극은 이미 저장돼 있다).
2. held 인데 대상이 계속 실패: 실패한 턴은 ack 하지 않으니 `delivery=none` interval 은 Keeper 가 실패하는 동안 계속 붙잡혀 있다. 5.2 의 "상한 없는 연속 실패" 를 물려받는다.
3. 멈춘 Keeper 의 Cron·Daily 일정: 회차마다 받아들여 자극을 넣고, 이벤트 대기열에는 상한이 없다(`keeper_event_queue.ml:311-317`). 멈춘 동안 자극이 쌓인다.

`delivery=none` interval 자체는 닫힌다(대기 한 회차, 놓친 회차는 한 번으로 따라잡음). held 표시는 TUI 는 닫혔고(#38304) 실패 중 낡은 표시와 dashboard 는 #38411(열림)이다.

## 6. 다음에 할 만한 코드 변경 (제안)

영향이 큰 순서다. 이 PR 은 코드를 바꾸지 않는다.

1. **Goal `Deferred` 알림** (5.3): `Deferred` 에서 주인 Keeper 에게 자극이나 Goal 사건을 보낸다. 지금은 Goal 이 소리 없이 `Verifying` 에 남는다.
2. **Librarian 못 읽는 턴 영수증** (5.1-1): 나눌 수 없는 턴의 크기·출력 실패를 타입으로 적고 위치를 옮긴다. 지금은 신호마다 같은 턴에서 걸음을 쓴다.
3. **Schedule 4c 받아들이기** (5.4-1): fiber 가 안 도는 등록 Keeper 도 멈춘 Keeper 처럼 자극을 남기고 회차를 넘긴다.
4. **C1 exact lane 타입 하나로**: `Exact_lane_run_registry.lane` 이 `Runtime.exact_lane` 을 쓰고, Verifier 를 빼야 하면 변환 함수 하나로 뺀다. wire 표가 하나가 된다. 41곳·13파일, 67곳·11파일.
5. **C0 Workspace 입출력 떼기**: Board·Schedule·Goal 이 Task 저장소를 링크하지 않게 한다.
6. **C2 Route 타입**: `Route.t = Lane of id | Runtime of id` 로 `[runtime].default`·Keeper 배정·Fusion 좌석이 같은 타입을 쓴다. `resolve_assignment` 23곳·8파일.
7. **C5 cycle/turn 코드 이름**: `run_keeper_cycle` → `run_keeper_turn`(37곳·20파일), `cycle_grant` → `turn_grant`(94곳·25파일).
8. **C6 Atom 위치 타입**: `(end_atom, last_atom_digest)` 를 한 타입으로. wire 가 같은지 먼저 본다.
9. 작은 것: C0-2(runtime → auth), C0-3(runtime → fusion_core), C0-4(Board 감싸개 삭제), `keeper_transcript_tail_recovery.mli:9` 주석의 `Recovering_requests`.

## 이 PR 에서 고친 용어집 항목

Turn, Runtime Attempt, Demotion, Gate, Claim, PR Reader, Transcript Tail Recovery, Read Position, Continuity Width 아홉 항목만 바꿨다.
용어집을 항목별로 나눠 `origin/main` 과 비교해 이 아홉 밖은 바뀌지 않은 것을 확인했다(163항목 중 9).
열린 PR 이 고치는 항목(Lane, Standalone Lane, Seed, Carried Front, Turn Start, Operator Disposition, Librarian Round, Librarian Pass End)은 건드리지 않았다.

## 근거

- Evidence: `git fetch origin` 뒤 `origin/main 203322c692`, `docs/spec/00-glossary.md`, 위 표의 `.mli`·`.ml` 줄,
  `lib/**/dune` 의 `libraries`, `gh pr view <n> --json state,mergedAt`(#38096·#38047·#38042·#38048·#38045·#38188·#38043·#38053·#38304·#38411),
  용어집을 고치는 열린 PR 13건(#38511·#38497·#38484·#38463·#38453·#38447·#38443·#38442·#38438·#38421·#38344·#38341·#38309)의 용어집 diff
- Timestamp: 2026-09-24T10:30:00+09:00
- Confidence: High(목록 대조, PR 상태, 닫힘 판정의 코드 경로), Medium(열린 갈래가 라이브에서 얼마나 자주 일어나는지, Atom 위치 타입 합치기의 이득), Low(`Hitl_auto_judge` lane 이 Gate `Auto_judge` 를 맡는지)
- Delta: 09-23 의 열린 칸이 모두 병합으로 닫혔음을 확인하고, 새로 열린 갈래 여섯(Librarian 둘, Keeper 연속 실패, Goal `Deferred`, Schedule 둘)과 중복 개념 13건, 새 결합 5건을 더했다.

## 불확실성

- Tick 표는 코드를 읽은 추론이다. 라이브 로그로 빈도를 세지 않았다.
- verifier 모델 호출에 시간 상한이 있는지, chat lane 의 걸음, 미룬 lane 힌트 저장은 따라가지 않았다.
- `lib/keeper`·`lib/fusion`·`lib/lane_addon` 은 `masc` 라이브러리 하나 안에 있어서 dune 으로는 서로의 결합이 안 보인다. 일부만 직접 봤다.
- 결합 영향 수는 `rg -c` 로 `lib`·`bin` 만 셌다(테스트 제외).

## 적용범위

- 영향 받는 영역: 용어집, Librarian, Keeper 턴, Runtime 후보 순서, Goal 검증, Schedule, 도메인 라이브러리 경계.
- 제약/배제: 코드·라이브 store·운영 설정은 바꾸지 않았다. 원문 로그와 비밀 정보는 싣지 않는다.
- 롤백 조건: 위 열린 PR 이 병합되며 같은 항목을 다르게 고치면, 이 기록의 "처리" 칸을 그 PR 기준으로 다시 본다.
