# 1주일 변경 감사 — 2026-09-23

확인 기준은 `origin/main a7517b0ebb`(2026-09-23 00:20 KST)와 2026-09-22 UTC 하루의 운영 로그다.
소스, PR/CI, 라이브 로그, 파일 시각을 따로 판정하고, 완료율은 산정하지 않는다.
09-19·09-22 의 두 기록([09-19](2026-09-19-weekly-lifecycle-evidence-record.md),
[09-22](2026-09-22-keeper-cycle-week-evidence-record.md))이 다룬 항목은 다시 쓰지 않고
새로 찾은 것만 적는다.

## 공통 헤더

- 날짜(ISO8601): 2026-09-23T00:40:00+09:00
- 작성자: Claude (세션 eec06d72)
- 결정 ID: week-change-audit-20260923
- 적용 대상: MASC main `7092e232bd`~`a7517b0ebb`, `~/me/.masc` 운영 파일, system log 2026-09-22
- 결정 상태: 추적 필요

## 기간과 변경 흐름

`origin/main` 의 author date 기준 2026-09-15 00:00 KST 이후 커밋 1,012건.
날짜별 수와 scope 는 아래와 같다(Conventional Commit 접두어 집계, `.ml/.mli` 변경 파일 수).

| 날짜 | 커밋 | 종류 | 가장 많이 바뀐 scope | 파일 수 | 가장 많이 바뀐 파일 |
|---|---|---|---|---|---|
| 09-15 | 295 | fix 194 | keeper 48, tui 48, agent_core 26, browser 15 | 748 | masc_tui_render, http_client, keeper_turn_driver_try_provider |
| 09-16 | 89 | fix 29, perf 18 | keeper 18, schedule 6, tui 6 | 322 | keeper_next_request_forecast(신설), masc_tui_context_inspector |
| 09-17 | 62 | fix 25, feat 12 | keeper 9, bench 6, shim 4 | 225 | keeper_next_request_forecast, keeper_turn_driver, test_keeper_turn_driver_failover |
| 09-18 | 77 | docs 20, fix 17 | rfc 15, keeper 11, exact-output 4 | 150 | keeper_turn_driver_try_provider, keeper_carried_front, keeper_turn_boundaries |
| 09-19 | 60 | fix 23, feat 11 | keeper 25 | 258 | test_keeper_turn_boundaries, keeper_history_clear, keeper_agent_run_turn_helpers |
| 09-20 | 82 | fix 53, docs 16 | dashboard 7, keeper 7, glossary 7, librarian 6 | 296 | test_board_rest_routes, tui_decode, keeper_tool_memory_runtime |
| 09-21 | 160 | fix 90, feat 21 | librarian 27, keeper 19, tui 16 | 549 | keeper_librarian_runtime(18), masc_tui_render(18), keeper_librarian_queue_refresh(14) |
| 09-22 | 187 | fix 84, feat 43 | tui 48, keeper 25, rfc 9, fusion 9, glossary 8 | 490 | masc_tui_render_chat, masc_tui, keeper_turn_driver(_try_provider) |

큰 흐름은 넷이다. (1) 09-15 TUI·HTTP 클라이언트·agent_core 정리 sweep,
(2) 09-16~19 요청 크기 예측(`keeper_next_request_forecast`)과 실어 보낼 시작 위치
(`keeper_carried_front`, `keeper_turn_boundaries`), (3) 09-20~21 Memory 도구와 Librarian
런타임(연속성 스냅숏 #37564, 폭 판정 #37751·#37846·#37855), (4) 09-22 TUI chat·fusion·board.
fix 가 515건으로 절반을 넘고, 같은 파일(`keeper_turn_driver_try_provider.ml`)이 7일 중 5일
상위에 있다. 이 파일이 이 주의 회귀 위험 중심이다.

## 이 주에 더해진 코드의 신호 검사

`git diff 20cc8a689c..origin/main` 의 `.ml` 추가 줄(테스트 제외) 58,681줄을 다음 신호로 훑었다
(`lib/`, `bin/`, `packages/`). 별도 탐색 에이전트 셋이 Board·Task·Goal·HITL·Access·Lane·Schedule·Skills 와
TUI 경로를 커밋 단위로 다시 읽었다.

| 신호 | 건수 | 판정 |
|---|---|---|
| 문자열/부분 문자열 분류(`String.starts_with` 등) | 14 | 전부 경로·파일명 접두어, Memory 검색의 부분 일치, JSON `kind` 태그 해독. 공급자 오류 문장을 읽는 곳은 없다. 오류 분류 파일 넷(`keeper_error_classify`·`retry`·`complete_stream_error`·`keeper_request_failure`)에 이 주 더해진 문자열 일치 줄은 0 |
| 새 `| _ ->` 갈래 | 236 (핵심 경로 79) | 대부분 JSON 해독기의 `Error "invalid …"` 와 화면 키 분기. 눈에 띄는 것 하나: `lib/keeper/hitl_summary_worker.ml:1520,1530` 이 typed `cause` 위에서 `_` 로 나머지를 `handle_flow_error` 에 보낸다. 주석이 "두 생성자만 온다" 고 말하지만 컴파일러가 아니라 주석이 지키는 불변식이다 → [#37917](https://github.com/jeong-sik/masc/issues/37917) |
| stub·`failwith "unimplemented"`·`assert false` | 0 | — |
| `max_int` 류 감시값 | 8 | 넘침 보호·해시·화면 끝 스크롤. 한 곳은 위 넘침 절의 Codex 시작 용량 |
| 근거 주석 없는 세 자리 이상 상수 | 64 후보, 실제 2 | `keeper_next_request_forecast.ml:340` `recent_records_read = 200`(진단 표본, 실측 없음), `keeper_projection_change.ml:134` memo 128 |

에이전트가 찾고 코드로 확인한 것:

- `lib/keeper/keeper_librarian_absorb_gate.ml:146` `conveyed_boundary = 0.5` — JEV Noul 확률을 우리가 잘라 "전달됨"을 정한다.
  판단을 문턱으로 근사하는 자리. JEV 는 Choice 답도 준다. → [#37915](https://github.com/jeong-sik/masc/issues/37915)
- `lib/goal/reliable_change_g1.ml:1178` — 깨진 `usage` 값을 빈 객체로 바꿔 계속 읽는다(#36845). 손상이 "usage 없음"으로
  보인다. → [#37916](https://github.com/jeong-sik/masc/issues/37916)
- Skills: 반복 해결법에서 Skill 을 만드는 producer 는 이 주에도 없다. 커밋은 전부 사람이 쓴 초안을 검증·발행하는 경로다.
- 같은 날 fix 사슬: `lib/completion_authority_wakeup.ml` 09-15 에 4건(#36461·#36500·#36552·#36555),
  `lib/browser_lane_launcher.ml` 09-15 에 3건(#36481·#36516·#36537), `keeper_board_attention_exact_flow.ml` 주간 8건(순차 롤아웃).
  둘째 fix 에서 근본을 봤는지는 이 기록에서 판정하지 않는다.
- Access Control: 권한을 읽고 Error/None 에서 계속 진행하는 곳(fail-open)은 대상 경로에서 찾지 못했다.
  `keeper_librarian_context_review.ml:85-87`·`keeper_librarian_absorb_gate.ml:566-589` 는 얼핏 fail-open 같지만
  "게이트가 꺼져 있으면 예전 동작, 켜져 있는데 답이 없으면 흡수를 막는다" 는 의도된 비대칭이다.
- Schedule: `schedules/signal_keys.json` 은 8,846 키·619 KB(+`.last-good` 사본)이고 지우는 코드가 없다.
  723b932f09 가 "#26686 items 1-3 of 5" 라고 자인한 채 item 4(무제한 증가)를 남겼고 #26686 은 닫혔다.
  → [#37919](https://github.com/jeong-sik/masc/issues/37919)
- Board attention 후보·파티션·워커에 주간 5 커밋(v7 hard cut → #37586 → #37668 → #37693 → #37641)이 "정체된 후보" 계열
  증상으로 몰렸다. #37668 은 `Settled -> Ready` 전이를 `_` 없이 명시해 FSM 규칙은 지켰다. 다음 회차에 또 나오면 근본을 본다.
- Librarian·Memory 핵심 경로(별도 에이전트, 코드로 확인): 문자열 분류·stub·이름만 있는 `Ok ()` 는 0. 남은 것은 닫힌 variant 위의
  `_` 셋과 근거 없는 상수 둘이다 — `keeper_librarian_continuity.ml:173` (`R.selection` 5개 중 3개를 "바닥 모름" 으로),
  `keeper_librarian_queue_refresh.ml:141` (`pass_end` 6개 중 5개를 한 갈래로), `librarian_continuity_snapshot.ml:167`
  (`R.selection` 4개를 `source_range` 로); `keeper_librarian_absorb_gate.ml:6` `min_statement_chars = 20`,
  `keeper_checkpoint_purge.ml:13` `keep_recent_messages = 20`. 셋은 모두 "모르면 보수적으로" 방향이라 오늘 동작은 안전하지만
  새 생성자가 조용히 그 갈래로 떨어진다. → [#37922](https://github.com/jeong-sik/masc/issues/37922)
  좋은 반례: `keeper_librarian_absorb_gate.ml:574-606` 은 게이트 불가를 이름 있는 세 묶음으로 나누고 원문을 남기는 쪽으로 틀린다.
  fix 사슬 둘 더: absorb gate 의 "판정이 안 돌았으면 원문을 버리지 않는다" 6 커밋(#37369→#37409→#37432→#37464→#37630→#37708),
  연속성 스냅숏 재작성 11 커밋(09-21~22, #37564→…→#37795). 09-15 의 Memory 쓰기 실패 문장 4 커밋, 09-20 의 Memory 검색·철회 4 커밋.
- 도메인 결합(Glossary 의 부분집합 질문): Librarian 은 Task 를 안다(`keeper_librarian.ml:28,222`, `keeper_librarian_queue_refresh.ml:401-402`
  가 `Task_goals` 를 만든다) 와 Board 를 안다(`keeper_memory_os_types.ml:424-576` 등이 Board 글·댓글 참조를 기억의 출처로 담는다).
  Board 참조는 데이터 출처라 결합이 아니다. `Task_goals` 는 Librarian 이 Task 도메인 타입을 조립하는 것이라, 호출자가 목표를
  값으로 넘기면 Librarian 은 Task 를 몰라도 된다. Schedule·TUI 참조는 없다. 분리는 제안이며 이 기록에서 결정하지 않는다.
- Runtime Failover 경로 8개 파일·89 커밋(별도 에이전트, 코드로 확인): 문자열 분류·stub·permissive default 0.
  `keeper_runtime_failure_route.ml` 은 커밋이 많았는데도 전부 exhaustive match 와 근거 주석이다.
  남은 것 넷 — `retry.ml:55-56` 의 `529`·`500..599` 에 출처 주석이 없다(529 는 Anthropic 의 overloaded 상태).
  `keeper_next_request_forecast.ml:340` 의 `200` 은 #37250 이 "진단 표본" 으로 떼어 낸 뒤 남은 고른 수다.
  `keeper_turn_driver.ml:2031`·`keeper_turn_driver_try_provider.ml:1274` 의 새 `_` 갈래는 로컬 튜플 매치라 위험이 낮다.
  `88fd893bc6`(#36984) 은 스스로 "#36979 의 반쪽" 이라 밝혔고 #36979 는 닫혔다. 다른 반쪽(멈춘 슬롯의 failover 분류)이
  #37319 로 닫혔는지는 이 기록에서 확인하지 않았다.
- 같은 자리의 fix 사슬 하나 더: continuity 앞머리 조립(`keeper_turn_driver_try_provider.ml`)에 09-19 이후 커밋이 몰렸고,
  #37735 → 되돌림 → #37734 → "#37735 를 #37734 위에 다시" 순서가 있었다. 각 커밋은 앞 커밋이 놓친 경계를 좁히는 모양이지만,
  이 파일이 주간 최다 변경 파일인 이유가 여기 있다.
- `7db9e2fefe` 의 v7 hard cut 은 v6 를 테스트로 거절하고 호환 층을 남기지 않았다.

## 이번 세션에서 찾은 결함과 조치

| 결함 | 조치 | 확인한 증거 | 남은 증거 |
|---|---|---|---|
| Librarian working state 메시지가 per-turn 컨텍스트 carrier 와 같은 표식을 달아 요청 조립 검사가 실패하고 turn-record 의 `input_components` 가 비었다 | [#37894](https://github.com/jeong-sik/masc/pull/37894) | 09-22 경고 10,864건(13 Keeper), msx-retro-mania turn-record 139/139 구성 없음. 표식 분리 뒤 스위트 4개(21+38+14+9) 통과, CI 5/5 | 배포 뒤 경고 0건, `input_components` 생성 |
| checkpoint 가 없는 Keeper(sangsu)를 부팅마다 ERROR + `failed=1` 로 셌다 | [#37904](https://github.com/jeong-sik/masc/pull/37904) | 재시작 27번 모두 같은 ERROR. `Ref_not_found` 는 typed 부재인데 실패로 접혔다. 새 스위트가 수정 전 빨강·후 초록, CI 5/5 | 배포 뒤 `failed=0` |
| microvm Keeper 의 스크립트 `cd masc` 를 호스트 파일시스템에서 검사해 거절했다 | [#37908](https://github.com/jeong-sik/masc/pull/37908) | 09-22 `tool_execute` cwd 거절 145건(모두 microvm, 호스트 fallback 없음). `Execute_script_paths.judge_operands` 가 `is_cd` 를 존재 요구로 그대로 넘김. 케이스 3개 추가, 스위트 14/14 | CI, 배포 뒤 거절 0건 |
| working state 바이트가 turn-record 의 `Message_user` 에 섞인다 | [#37895](https://github.com/jeong-sik/masc/issues/37895) | `input_component_id` 에 값이 없음 | 결정 |
| supervised 재시작이 store 세대 preflight 를 거치지 않아 event-queue v18→v19 뒤 13분간 ERROR 1,884줄, 20 Keeper 큐 없음 | [#37900](https://github.com/jeong-sik/masc/issues/37900) | 04:29:41~04:42:11Z, `deploy.sh` 만 preflight 실행. 04:41Z 수동 정리로 종료(로그에 cut 기록 없음) | 부팅 검사 vs 스크립트 preflight 결정 |

결함이 아니라고 판정한 것: 04:42:15Z `Board attention … settling blocked partition` ERROR
2,766건은 파티션·후보가 각 한 번씩이라 수동 cut 뒤 한 번 도는 정리다(레벨만 과함).
`masc_schedule_update` 가 due 를 요구하는 것은 "통째로 교체" 계약이다.
`keeper_memory_write source_read_failed` 44건은 Keeper 가 없는 경로를 넘긴 것이다.
`prompt_context_carrier_repeated` 706건은 위 첫 결함의 다른 얼굴이다.

## Tick 별 상태 — Librarian 연속성 순환

RFC-librarian-lifecycle §4.3(사다리)·§4.11(단위) 기준으로 한 Keeper 의 상태를 tick 마다 적는다.
tick = Librarian 회차 하나.

| 상태 | 다음 tick | 닫힘 |
|---|---|---|
| 스냅숏이 이력에 맞음 | 한 단위 읽고 커밋, 위치 전진 | 닫힘 |
| 스냅숏이 안 맞음(purge 뒤 등) | `[0, N)` 다시 쓰기 시작, `catch_up_end_atom` 기록 | 닫힘(아래 수렴 실측) |
| 회차 실패, 원인이 크기 | 폭 절반으로 접고 프로세스 메모리에 기억 | 열림: 재시작이 기억을 지운다 |
| 회차 실패, 원인이 크기 아님 | 같은 폭으로 기다림 | 닫힘 |
| 읽을 것 없음(Drained) | 폭 기억 해제 | 닫힘 |
| 공식 클라이언트 레인 턴 | atom 이 없어 스냅숏이 덮을 수 없음 | 열림: #37207 |

실측(goo-yang-bong, 09-22 UTC): 12:52 부팅 뒤 `12756→6378→3189→1594→797`, 13:40 부팅 뒤
다시 `12756→6378→3189→1594`. 14:26 rewrite 시작 뒤 폭 534 로 2~3분마다 한 단위
(`4209→4743→…→7313`), 목표 `catch_up_end_atom` 은 `12984→12994` 만 움직여 수렴한다.
하루 접힘 32회 중 재시작 뒤 최대 폭에서 다시 시작한 것이 8회(Keeper 별 1~2회).
재시작 27번인 날에는 재발견 비용(실패 호출 4번, 각 1~3분)이 회차 예산의 큰 몫이다.
§4.11 의 턴 구간 단위가 오면 사라지는 비용이다. RFC §4.3 은 "실패 표식은 루프의 메모리에만 두고
재시작하면 전부 읽기부터 다시 한다" 로 이미 정해 두었고, 세션 A 의 판단(2026-09-23 00:50 KST)은
비용을 받는 쪽이다: 커밋 간격으로 폭을 추정하면 거절 근거가 아닌 값이 되고, durable 사실이
손상되는 경우도 아니며, §4.11 뒤 걷어낼 개념이 하나 더 생긴다. 이 기록은 그 판단에 동의하고
비용의 뿌리를 재시작 횟수로 본다.

재시작 27번의 출처: `masc-start-0922-*.log`(start 스크립트, KST 이름) 19개와 ±4분 안에 맞는
부팅이 20번, 맞는 로그가 없는 부팅이 7번(00:39, 03:25, 03:37, 04:29, 04:41, 05:11, 09:08Z).
앞의 20번은 병합 뒤 배포 주기다. 뒤의 7번은 다른 시작 경로(supervisor·deploy.sh·수동)이며
04:29Z 의 v18→v19 사건(#37900)이 여기 든다. 재시작을 줄이는 쪽(배포 묶음)이 폭 기억보다 큰 레버다.

같은 날 msx-retro-mania 의 turn-record 145건은 순환이 어디서 벌어지는지 보여 준다(표는 시간대별 요청 본문 중앙값과
실어 보낸 atom 수):

| UTC | 요청 본문 중앙값 | 실어 보낸 atom | 전체 atom |
|---|---|---|---|
| 01~03 | 150~169 KB | 1~57 | 12,764~12,910 |
| 08 | 216 KB (최대 1,001 KB) | 55~494 | 14,012~14,102 |
| 13 | 641 KB | 222~273 | 14,999~15,050 |
| 15 | 615 KB | 485~492 | 15,262~15,280 |

이 Keeper 의 Librarian 은 하루 42번 실패했다(glm 429 `rate_limited` 35, deepseek `completion failed raw_response=none` 7).
실패마다 사다리가 접혀 폭이 `130→65→32→16` 이 됐고, 15:17Z 에야 16 atom 단위 커밋이 시작됐다(`14777→14793→14808`).
그동안 Keeper 는 시간당 약 100 atom 을 더해 스냅숏이 487 atom 뒤처졌고 요청이 615~806 KB 로 커졌다.
빈 응답(`Completion_failed`, raw_response 없음)을 크기 증거로 읽어 접는 것이 이 비용의 절반이다.
그 갈래를 가르는 일은 [#37899](https://github.com/jeong-sik/masc/issues/37899)(agent_core)로 분리돼 있고, 이 수치를 거기 남겼다.
`continuity pass reads one unit … -> N` 줄은 계획이지 커밋 결과가 아니라서, 실패한 회차도 같은 줄을 남긴다. 읽는 사람이
결과로 오해하기 쉽다.

요청 구성(09-22 실측, agent-core 레인): 고정 약 88 KB(지시문 14 KB + 도구 스키마 74 KB),
working state 약 2 KB, 완료 턴 atom 당 약 0.8 KB, 현재 턴 도구 결과 25~131 KB.
recall 은 턴 첫 요청에 실린다. 창 투영과 Librarian 흡수로 위가 막히고, 아래는 §4.3 바닥 규칙이
막는다. 열린 것은 위 표의 둘뿐이다.

Keeper 쪽 넘침은 이 날 공식 클라이언트 레인에서만 났다: Codex typed overflow 8, Claude Code 3, 그 뒤
`official-client session recovery … decision=restart_fresh` 4(critic 1, glossary-maniac 3, 01:53Z).
Codex 레인은 시작 용량을 `unbounded_model_input_capacity_bytes = max_int` 로 두고 공급자 거절에서 다음 크기를
배운다(`keeper_codex_runtime.ml:94,1316`). 이는 #36828(2026-09-16, "크기는 서버가 판정한다")의 결정대로다.
Claude Code 레인만 선언된 `max-prompt-bytes` 를 시작 용량으로 읽는다(`keeper_claude_code_runtime.ml:1345-1362`).
비대칭이지만 결정에 어긋나지는 않는다. 로그에 `previous_capacity_bytes=4611686018427387903` 로 찍히는 것은
"선언 없음" 이 숫자로 보이는 것이라 읽는 사람이 헷갈린다.

## Glossary

`docs/spec/00-glossary.md` 는 이 주에 74 커밋, 674줄 추가(41→703줄), 작성자 3(사용자 2계정,
Keeper pangyo-preachers). Continuity 절(426~703행)에서 찾은 것:

1. 끝의 `### 대화 작업 상태 (working_state)` 는 형식(### 제목, `~입니다`)이 다른 항목과 다르고,
   **Continuity Snapshot** 이 이미 정의한 파일의 텍스트 절반을 다시 정의한다.
2. **받은 일 정리**(`Keeper_librarian_context`)와 **Working Context** 가 서로를 가리키지 않는다.
   코드는 `Keeper_librarian.selection.working_contexts : Keeper_librarian_context.pocket list` 다.
3. "Continuity" 가 붙은 항목이 넷(Snapshot·Synthesis Observation·Measurement·CLI 이름)이고 뜻이 다 다르다.

셋을 glossary-maniac Keeper 에게 근거와 함께 전달했다(2026-09-23 00:35 KST). 제안이며 결정은 아니다.

## Runtime Failover 근거 경로

판정은 typed 이고 닫혀 있다. 기록은 수와 문자열만 남긴다.

- 다음 후보로 넘어가는 규칙은 `Exact_output.execution_failure_may_advance`
  (`packages/agent_core/lib/llm_provider/exact_output.ml:1804`)의 `(cause, phase)` exhaustive match 다.
  넘어가는 갈래: dispatch 전 `Completion_failed`, 성공 응답인데 본문이 없는 `Response_body_deadline_exceeded`,
  응답을 받은 `Request_body_refused`·`Rate_limited`·`Overloaded`·`Server_error`, `Invalid_json_output`,
  `Missing_output`. 나머지 refusal(`Context_overflow`·`Invalid_request`·`Input_capacity`·`Timeout`·
  `Network_error`·`Auth_failed`·`Authorization_refused`·`Payment_required`·`Not_found`·
  `Refusal_body_not_received`)은 전부 이름을 적어 걸음을 끝낸다. `_` 갈래는 없다.
  거절 산문을 문자열로 읽는 곳은 `exact_output.ml`·`keeper_runtime_failure_route.ml` 에서 찾지 못했다.
- durable 로 남는 것: 실행 영수증의 `runtime_lane_attempt_count`(수)와 `runtime_fallback_applied`(참/거짓)
  (`lib/keeper/keeper_agent_run_receipt.ml:121-125`), 이긴 runtime 의 호출 목록 `attempts`
  (`lib/runtime/runtime_observation.mli:12-24`, `error : string option`), Keeper meta 의
  `last_runtime_attempt`(`lib/keeper/keeper_meta_contract.mli:167`, `outcome : [Success | Failure of string]`).
  `attempts` 는 한 runtime_id 의 것이라 failover 뒤에는 이긴 쪽만 남는다(`keeper_agent_run_receipt.ml:180-185` 주석).
- 남지 않는 것: 어느 후보를 어떤 typed 이유로 지났는지. 후보별 typed 오류는 `lib/keeper/keeper_unified_turn_types.ml:15-18`
  의 `runtime_attempt_error` 에 프로세스 메모리로만 쌓이고, 읽는 곳은 `lib/keeper/keeper_unified_turn.ml:1330` 의 WARN 한 줄뿐이다.
  마지막 실패 하나의 route 만 `keeper_unified_turn.ml:1425-1434` 의 카운터 라벨과 `Keeper_registry.set_failure_reason`
  (`lib/keeper/keeper_unified_turn_failure.ml:33-34`, 한 칸 덮어쓰기)에 남는다. `lib/types/turn_record.ml` 에는 lane·fallback·
  attempt·reject 필드가 없다(별도 탐색 에이전트, 코드로 확인). 판정 시점의 `Exact_output` 증거(advances·final)는
  Librarian 폭 판정(#37875)만 읽는다.
  제안: 걸음의 typed 증거를 turn-record 에 그대로 싣는다. 이 주에 `Completion_failed` 로 접히던 429 가
  `Rate_limited` 로 분류된 것과 같은 방향이다. 코드 변경은 하지 않았다(#37875 영역).

## HITL · Schedule 에서 본 것

- HITL: 09-22 `tool_execute` 인가 9,094건이 전부 `workspace_always_allow` 다. 사람 승인 게이트는
  connector_post replay 3줄 말고는 이 날 한 번도 돌지 않았다. 게이트 코드가 틀렸다는 뜻이 아니라,
  이 워크스페이스 설정에서는 그 경로가 라이브로 검증되지 않았다는 뜻이다.
- Schedule: 실행기가 보류(deferred)한 발생을 15초 tick 마다 INFO 로 다시 적어 하루 21,218줄이다.
  가장 큰 몫은 paused 인 lane-smith(6,821줄)로, 04:42:22Z 부터 큐에 남은 `schedule_due` 2건이
  소비되지 않아 새 발생이 종일 보류됐다. 보류 이유는 일정 상태에도 화면에도 없다.
  [#37912](https://github.com/jeong-sik/masc/issues/37912). 취소된 일정의 보류 줄은 취소 시각에
  멎었다(polisher 08:40Z, edgar 04:29Z) — 그쪽은 결함이 아니다.
  v18→v19 사건 창의 일정 dispatch 실패 925줄은 #37900 에 덧붙였다.

## 아직 판정하지 못한 것

- Terminal-Bench 4.0 전체 실행: 09-22 기록대로 GPU(H100) 3개 task 와 CPU 16개·메모리 16 GiB 를
  이 호스트가 주지 못한다. 어댑터(`benchmarks/terminal_bench`)와 pin(Harbor 0.23.0)은 그대로다.
  이 세션에서 어댑터의 Python 테스트 193개는 통과했다(`.venv/bin/python -m pytest -q tests`, 20초).
  `dist/manifest.json` 은 release 0.35.22 를 가리키고 최신 태그는 v0.36.0 이다. `dist/` 는 git 에 없고
  `fetch_masc.sh` 가 실행 때 최신 릴리스를 받으므로 낡은 것은 로컬 사본뿐이다. 벤치 실행은 하지 않았다.
  로컬 데이터셋 사본(`results/datasets/terminal-bench-4.0.0`)은 지금 `task.toml` 이 없는 불완전 상태라
  `dataset_plan.py` 가 "download it again" 으로 거절한다(09-22 기록의 CPU·메모리 거절과 다른 이유).
- HITL·Access Control·Multi Lane·Schedule: 로그의 오류 모양만 봤다(위 "결함 아님" 셋).
  실제 전이·권한 거절·취소 경로는 이번에 읽지 않았다.
- Skills 재생성: 09-19 기록의 "자동 생산 경로 미구현"(#37633) 이후 새 producer 를 찾지 못했다.
- TUI 배선: 이 주에 Memory/Keeper 화면에 더해진 키 세 묶음(연속성 밀림, 요약 진행 관측, JEV 준비 상태)은
  서버 writer 와 TUI reader 가 file:line 단위로 짝이 맞고, reader 만 있거나 writer 만 있는 키는 없었다
  (별도 탐색 에이전트, origin/main 기준). `64f20a0187` 은 #37856 이 `.ml` 에만 필드를 더하고 `.mli` 를 빠뜨려
  깨진 빌드를 다음 날 고친 것이다. "not measured"(`bin/masc_tui_render_memory.ml:132`)는 서버가 관측하지
  못한 `None` 을 그대로 보여 주는 자리이고, 색 분기는 전부 typed variant 매치다. `String.starts_with` 는
  JSON 본문 판별과 경로 접두어 축약 두 곳뿐이다. lane declaration 화면과 dashboard(TypeScript)는 보지 않았다.

## 근거

- Evidence: 위 PR/이슈, `~/me/.masc/logs/system_log_2026-09-22.jsonl`, `gh pr checks`,
  `git log origin/main --since=2026-09-15T00:00:00+09:00`, `stat -f %SB`(파일 생성 시각)
- Timestamp: 2026-09-23T00:40:00+09:00
- Confidence: High(로그 집계·PR CI), Medium(tick 표의 "닫힘" 판정은 §4.3/§4.11 문서와 실측 하루 기준), Low(재시작 비용의 하루 밖 일반화)
- Delta: 이 주의 Librarian 연속성 경로에 결함 셋(표식 충돌, 부팅 복구 오분류, 게스트 cd 검사)을 더했고, 재시작이 사다리 폭을 잊는 열린 순환을 수치로 남겼다.

## 검증

- 1차: 날짜별 git 집계와 결함마다 producer→store→consumer 코드를 읽었다.
- 2차: 결함마다 하루 로그에서 건수·Keeper·시각을 셌다.
- 3차: 수정 셋은 해당 스위트 exe 만 targeted 로 빌드해 돌렸다(20~60초, `_build/default` 에서 실행).
  constitution 의 "로컬 빌드는 하지 않는다" 를 targeted 빌드까지 금지로 읽는 세션이 있어 사용자 결정으로 남긴다.

## 불확실성

- 미확인 항목: 세 PR 의 배포 효과, 재시작 비용의 다른 날 재현, Glossary 제안의 채택.
- 영향: 이 기록은 결함 셋과 열린 순환 하나를 말할 뿐 전체 하네스의 올바름을 말하지 않는다.
- 추가 확인 필요: 병합·배포 뒤 같은 로그 지표(`prompt_context_presence_mismatch`, `canonical checkpoint unavailable`, `cwd_not_directory: masc`)가 0인지.

## 적용범위

- 영향 받는 영역: Librarian 연속성, 부팅 복구, exec policy, 운영 재시작 절차, Glossary.
- 제약/배제: 원문 로그·사용자 발화·비밀 정보는 싣지 않는다. 벤치마크 통과를 주장하지 않는다.
- 롤백 조건: 배포 뒤 지표가 남으면 해당 결함 판정을 철회하고 원자료로 다시 본다.
