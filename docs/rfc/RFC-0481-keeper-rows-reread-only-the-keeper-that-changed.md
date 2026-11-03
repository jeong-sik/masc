---
rfc: "0481"
title: "키퍼 행은 2초마다 통째로 읽지 않고, 바뀐 키퍼만 다시 읽는다"
status: Draft
created: 2026-11-03
updated: 2026-11-03
author: vincent + claude
supersedes: []
superseded_by: null
related: ["0477", "0480"]
---

# RFC-0481 — 키퍼 행은 바뀐 키퍼만 다시 읽는다

## 0. 요약

TUI 는 2초마다 키퍼 목록 두 개를 통째로 읽는다.

- roster `GET /api/v1/gate/keepers?detailed=true`: Overview, Keepers 의 모든 화면, Metrics, 그리고 키퍼 패널이나 About 이 보이는 모든 화면에서 읽는다.
- turns `GET /api/v1/keepers/turns`: 모든 화면에서 읽는다.

RFC-0477 의 fleet 처럼 행을 타입 스트림으로 보내면, 지금 경로가 이미 하는 일을 다시 만들어야 한다.

- 인증: roster 는 도구 권한(`channel_gate`)으로 읽는다. fleet 스트림은 공개 읽기다(§1.7).
- Candle: 잔액과 계정 revision 은 관리자 토큰에만 붙는다. Info 탭과 Home·Usage 가 그린다(§1.6).
- 오류 행: meta 를 못 읽은 키퍼는 오류 행으로 오고, TUI 는 그 행으로 "설정이 깨졌으니 지울까요"를 묻는다(§1.8).
- 웹 대시보드도 turns 를 읽는다(§1.8).

결정은 다섯 가지다.

1. 타입 스트림 대신, 키퍼 하나가 바뀌었다는 신호를 보낸다. TUI 는 그 키퍼 행만 기존 roster 경로로 다시 읽는다. 인증, Candle, 오류 행, 디코더는 지금 것을 그대로 쓴다(§3.1~§3.3). RFC-0480 결정 2 와 L7 이 이 방식이다.
2. 신호는 값을 쓰는 곳에서 낸다. 지금 알림이 없는 쓰기마다 신호를 더한다(§3.2). 키퍼가 생기거나 없어져도 그 키퍼 하나의 신호다. 모든 행이 함께 바뀌는 변화만 목록 전체를 다시 읽는다.
3. turns 는 턴 자리가 바뀔 때와 대기 목록이 바뀔 때 다시 읽는다. 2초 turns 읽기에 기대던 일(대기 영수증, 대기 입력, 기록 읽기, 끝난 턴 표시)은 그 읽기 결과에서 그대로 돈다(§3.4).
4. 턴 미리보기는 기록마다 바뀐다(§1.5). 서버가 키퍼마다 정해진 간격보다 자주 알리지 않고, 미리보기를 그리는 화면만 다시 읽는다(§3.5).
5. `next_action` 은 읽는 시각으로 정해진다(§1.4). 바뀔 시각을 알 수 있으므로 TUI 는 그 시각에 그 키퍼를 한 번 다시 읽는다(§3.6).

## 1. 지금 상태 (스택 `12939d7fdc2`, 2026-11-03 직독, 하위 에이전트 두 번 대조)

### 1.1 TUI 가 읽는 것

| 읽기 | 언제 | 디코더 | 위치 |
|---|---|---|---|
| roster | 2초 묶음의 `needs_keeper_roster`. Overview·Keepers 전부·Metrics, 키퍼 패널이 그려지는 모든 화면, About | `decode_keeper_runtime_list` → `keeper_runtime` | `bin/masc_tui_types.ml:4479`, `:4522~4581`, `lib/tui_decode.ml:139~166`, `:3084`, `:3203` |
| turns | 모든 화면, 2초마다 `launch_tick_side_reads` → `launch_keeper_turns_load` | `decode_keeper_turns_projection` | `bin/masc_tui.ml:3506`, `:16702`, `lib/tui_decode.ml:4584~4661`, `:4953` |
| turns(대기만) | `keeper_waiting_inventory_changed` 알림 | 같은 디코더 | `bin/masc_tui.ml:3487` |

크기는 roster 약 9 KB, turns 약 2 KB 다(키퍼 40명, `bin/masc_http_probe.ml:14~18`). roster 경로는 한 번에 200명까지만 준다(`server_routes_http_routes_channel_gate.ml:465`).

### 1.2 서버가 행을 만드는 곳

**roster.** `masc_keeper_list` 도구다(`server_routes_http_routes_channel_gate.ml:472`, 행은 `lib/keeper/keeper_tool_surface_ops.ml:318~444`). 캐시는 키 `base_path:limit:detailed`, 기본 2초다. keeper up·down 과 메시지 스트림 정리 때 지운다. keeper down 은 쓰기 전에 지운다(`keeper_tool_surface.ml:694`). 키퍼 하나만 읽는 매개변수는 없다.

**turns.** `handle_keeper_turns_list` 다(`server_routes_http_keeper_stream.ml:465~550`). 캐시는 없다. 턴 자리와 chat control token 은 `Keeper_owner_registry`, 미리보기는 `Keeper_turn_preview`, turn ref 는 `Keeper_autonomous_stream`, 대기 목록은 다섯 저장소(승인 큐, fusion, 확인 대기, 일정, 이벤트 큐)에서 온다.

### 1.3 행을 바꾸는 쓰기와 지금 나가는 신호

| 필드 | 바뀌는 곳 | 지금 나가는 것 |
|---|---|---|
| 단계, keepalive | `Keeper_registry` | SSE `keeper_phase_changed`, `keeper_composite_changed`(`lib/keeper/keeper_registry.ml:848~958`) |
| paused, activation mode, latched reason | Owner meta 전이 | Owner observer. 이 셋이 다를 때만 부르고(`keeper_owner.ml:909~935`) 키퍼 이름을 넘기지 않는다 |
| 사용 카운터(턴 수 등), `updated_at` | Owner reducer(`keeper_owner_reducer.ml:276~300`) | 없음. 이 카운터가 `health` 의 idle↔healthy 와 `next_action` 을 정한다(`keeper_status_runtime.ml:268~275`) |
| 마지막 실패 | `keeper_registry_setup.ml:268~330` | observer. 이유가 달라질 때만이라 시각만 바뀌면 없다(`:40~41`) |
| 키퍼가 생기고 없어짐 | `keeper_registry_setup.ml:641`, `:898`, `:970`, `:973`, `:979`, `:1095` | observer. 이름이 없다(`:27`). 디스크에만 생긴 키퍼는 없음 |
| runtime id | `runtime.toml` 배정과 기본 경로(`keeper_meta_contract.ml:409~418`, `runtime.ml:1137`) | 없음 |
| activation mode, sandbox profile 등 설정 필드 | 키퍼 TOML. 행은 TOML 값을 meta 위에 덮어 읽고(`keeper_meta_contract.ml:331`, `:343`), meta 파일에는 이 필드를 쓰지 않는다(`keeper_meta_json_parse.ml:318~324`). keeper_up 은 TOML 을 쓴 뒤 Owner `Update_profile` 을 commit 한다 | keeper_up 경로는 위 Owner 와 같음. 파일을 직접 고치거나 git 으로 바꾸면 없음 |
| lane 관찰 | 실행 영수증 쓰기(`keeper_execution_receipt.ml:544`) | 일부 영수증만 Activity_graph 이벤트(`:521`) |
| 초상, Candle 잔액 | Candle 원장(`Candle_ledger.update`)과 Candle 설정(`candle_observe.ml:6~27`). 원장 쓰기 하나가 여러 키퍼에 닿을 수 있다(선물) | 없음(`lib/candle*` 에 `Sse.` 호출 없음) |
| provider 쉼(`runtime_path_rest`) | 그 키퍼 경로의 runtime 마다 쌓인 쉼 기록과 읽는 시각(`keeper_turn_driver.ml:345~404`). runtime 하나의 기록이 그 runtime 을 지나는 모든 키퍼에 닿는다 | 없음 |
| 턴 자리, chat control token | 턴 자리는 `publish_turn_in_flight`(`keeper_owner.ml:610~615`)가 Atomic 으로 바꾸고 meta 를 쓰지 않는다. token 은 pause 전이(`:931~933`)와 `Pause_and_interrupt`(`:2529`)에서 바뀐다 | pause 전이만 Owner observer |
| turn ref | `Keeper_autonomous_stream.create`(`:82`)·`finish`(`:195`). Owner 가 턴 자리를 알린 뒤에 생긴다(`keeper_unified_turn_execution.ml:176`, `keeper_owner.ml:2917`) | 없음 |

지금은 2초 읽기가 이 빈틈을 가린다. 신호로 바꾸면 빈틈마다 화면이 멈춘다.

### 1.4 읽는 시각으로 정해지는 값

`next_action` 은 턴을 한 번도 돌지 않은 키퍼가 만든 지 120초(`agent_staleness_threshold_s`)가 지났는지로 정해진다. 지나기 전이면 `Probe`, 지나면 `Direct_message` 다(`keeper_status_runtime.ml:230~243`, `:286~303`). 그 순간에는 아무것도 쓰이지 않는다. `health` 는 시각에 기대지 않는다(`:268`).

읽는 시각으로 바뀌는 값이 둘 더 있다.

- Candle 잔액은 반감기에 따라 줄어들고, 줄어든 만큼 workspace 의 `burned` 가 늘고 `circulating` 이 준다(§1.6). `Candle_decay.remaining ~half_life ~since ~at ~amount_milli` 는 시계도 파일도 쓰지 않는 순수 함수다.
- provider 쉼은 두 가지다. `Rest_until_answered` 는 provider 가 다시 응답해야(쉼 기록이 바뀌어야) 끝나고, 읽을 때마다 끝나는 시각이 `now` 뒤로 밀린다. `Rest_dated` 는 기록된 시각에 쓰기 없이 끝난다. 행은 끝나는 시각을 싣지 않는다(`keeper_tool_surface_ops.ml:307~316`).

### 1.5 미리보기

- `Keeper_turn_preview.change_entry` 는 값을 바꿀 때마다 `updated_at` 을 그 시각으로 바꾼다(`keeper_turn_preview.ml:104~113`). 2026-11-02 밤 라이브에서 `keeper_turn_stream_event` 는 초당 약 27건이었다(60초 1회, 신뢰 낮음).
- `observe_preparation`(`:140`, `:159`, `:165`)과 `reset`(`:195`)은 `change_entry` 를 거치지 않고 쓴다.
- 표에서 항목을 지우지 않는다. 미리보기를 고르는 열쇠는 Owner 의 interrupt token 이다(`server_routes_http_keeper_stream.ml:507~515`). 채팅 작업 턴은 turn ref 가 없다.
- 쓰는 곳: 그 키퍼 채팅 화면의 활동 줄(`Masc_tui_answering.chat_activity`), 키퍼 목록의 마지막 활동 시각(`Masc_tui_types.keeper_activity_at`). 답변 중 배지는 미리보기를 읽지 않는다.

### 1.6 Candle

잔액은 Info 탭이 그리고(`bin/masc_tui_render_keepers.ml:1404`, `info_lines` 안), Items 탭은 잔액과 계정 revision 으로 바뀜을 알아본다(`bin/masc_tui.ml:5342`). roster 응답의 workspace 단위 Candle 값(`candle`: issued, burned, circulating. `state.candle_observation`)은 Home, Usage, 도움말이 그린다. TUI 는 이 값들을 milli 단위까지 그린다(`bin/masc_tui_candle.ml`).

둘 다 요청 토큰이 CanAdmin 일 때만 붙는다. roster 경로가 `Dashboard_projection_cache.with_current_gate_keeper_observations` 로 붙이고, 이 함수는 웹 대시보드의 실행·브리핑 화면과 같은 투영(`with_current_keeper_observations_using`)을 쓴다.

서버는 읽을 때마다 원장 전체를 `Candle_balance.of_events ~at:now` 로 접는다. 접기의 끝(`advance_all`)에서 키퍼마다 마지막 잔액 이벤트 시각부터 읽는 시각까지 잔액을 줄이고, 줄어든 만큼을 `burned` 에 더한다. 그래서 키퍼 잔액, `burned`, `circulating` 이 모두 읽는 시각에 따라 바뀐다. `issued` 와 장비(portrait)는 원장 이벤트로만 바뀐다. 장비는 고른 아이템으로 정해지고 잔액과 상관없다.

### 1.7 인증

roster 경로는 `Tool { tool_name = "channel_gate" }` 라서 언제나 도구 권한을 확인한다(`channel_gate.ml:867`). fleet 스트림은 `Public_read` 라서 엄격 모드가 아니면 열려 있다(`server_routes_http_routes_fleet_stream.ml:85`). TUI 는 roster 에서 "토큰 없음"을 따로 구분한다(`bin/masc_tui_http.ml:2531~2533`).

### 1.8 roster·turns 를 쓰는 다른 곳

- roster 의 오류 행(meta 를 못 읽음, `keeper_tool_surface_ops.ml:253~289`)은 "설정이 깨진 키퍼를 지울까요"로 이어진다(`lib/tui_decode.ml:3227~3266`).
- roster 읽기가 실패하면 TUI 는 일부러 옛 목록을 버려서 키퍼 수명 동작(멈춤·재시작 등)을 거둔다(`bin/masc_tui.ml:14644~14655`).
- turns 의 `Keeper_turn_unavailable` 는 Metrics 가 센다(`masc_tui_render_metrics.ml:523`).
- 2초 turns 읽기의 결과로 대기 영수증 정리, `launch_waiting_keeper_input`, 기록·준비 단계 읽기, 끝난 턴 표시가 돈다(`bin/masc_tui.ml:24253~24317`).
- 웹 대시보드가 turns 의 `turn {lane, started_at_unix}` 를 읽는다(`dashboard/src/api/dashboard-keeper-turns.ts:55~66`).
- 대기 목록의 fusion 항목은 신호가 없다(`server_keeper_waiting_inventory.ml:1252`). 일정과 확인 대기도 없다.

## 2. 고르지 않은 길

| 길 | 고르지 않은 이유 |
|---|---|
| 행을 타입 이벤트로 보낸다(RFC-0477 의 fleet 방식) | 스트림에 도구 권한과 CanAdmin 구분을 새로 넣어야 한다(§1.7). 행에 붙은 하위 타입마다 엄격한 코덱을 새로 써야 한다. 오류 행, `Unavailable` 턴, 200명 상한을 다시 만들어야 한다. 허브가 키퍼마다 디스크(meta, TOML, 영수증, Candle 원장)를 다시 읽어 비교해야 하고, 그 일은 Owner fiber 와 허브 락 밖에서 돌아야 한다. 신호를 내는 쓰기는 이 길에도 똑같이 필요하다 |
| 알림마다 roster 전체를 다시 읽는다 | 키퍼 수에 비례한다. 300명이면 한 번에 약 68 KB(40명 9 KB 에서 선형 추정)이고, 알림도 키퍼 수만큼 잦아진다 |
| 서버가 몇 초마다 행을 다시 계산해 비교한다 | 폴링을 서버로 옮길 뿐이다. 신호가 빠진 쓰기가 계속 숨는다 |
| `next_action` 이 바뀔 시각에 서버 타이머를 건다 | 키퍼마다 타이머가 생긴다. 바뀔 시각은 행이 이미 알려 준다(§3.6) |
| 미리보기를 기록마다 알린다 | 초당 수십 번 알리고, 받는 쪽은 그때마다 읽는다 |

## 3. 설계

### 3.1 키퍼 하나 읽기

roster 경로에 `name=<키퍼>` 를 더한다. 그 키퍼의 행 하나(또는 오류 행 하나)를 지금 roster 와 같은 모양으로 주고, 답에 그 이름을 `name` 으로 적는다. 목록에 없는 이름이면 행이 없다. 키퍼 이름 문법에 맞지 않으면 400 이다. 인증, CanAdmin 일 때의 Candle 값, 오류 행, 디코더가 그대로다. 캐시는 이 읽기에 쓰지 않는다. `limit` 은 이 읽기를 자르지 않는다.

행은 하나만 만든다. 이름 목록(키퍼 디렉터리와 registry)과 Candle 원장은 전체 읽기처럼 한 번씩 읽는다. CanAdmin 이면 Candle 투영이 원장을 한 번 더 읽는다. 이 비용은 L3 전에 잰다(§4).

### 3.2 신호

새 SSE `keeper_row_changed { name }` 를 하나 둔다. 키퍼가 생기거나 없어져도 이 신호다. 모든 행이 함께 바뀌면(기본 runtime 경로) `keeper_roster_changed` 를 낸다. 신호는 쓰기 함수 안에서 쓰기가 끝난 뒤 낸다(RFC-0480 §3.4). 신호를 받은 쪽은 캐시를 거치지 않는 읽기로 읽는다. 키퍼 하나는 `name=`(§3.1), 목록 전체는 `fresh=true` 다. 그래서 신호 전에 roster 캐시를 지우지 않는다.

| 쓰기 | 신호 |
|---|---|
| Owner commit(meta 저장소 `replace`·`remove`). paused, latched reason, 사용 카운터, `updated_at` 이 여기를 지난다. keeper_up 의 설정 변경도 `Update_profile` 로 여기를 지난다. 예외를 낸 쓰기와 저장소를 막은 첫 실패도 파일을 바꿨을 수 있어서 같이 알린다 | 그 키퍼 `keeper_row_changed` |
| 키퍼 TOML 을 keeper_up 밖에서 바꿈(직접 편집, git) | 없음. §6 의 한계대로 Revalidate·`r` 에서 맞는다 |
| registry 항목 commit(단계, 실패 이유와 시각, keepalive). 맵을 바꾸는 곳은 `swap_in`·`swap_out` 둘뿐이다 | 그 키퍼. 행이 읽는 값이 바뀔 때만 |
| registry 에 항목이 들어오고 나감 | 그 키퍼 |
| `runtime.toml` 배정 트랜잭션, 기본 경로 변경, 설정 다시 읽기(catalogue publication 하나하나) | 모든 행(`keeper_roster_changed`). 행의 provider 쉼이 lane 후보, runtime, binding 까지 catalogue 전체를 읽어서, 배정 id 만 비교하면 놓친다 |
| 실행 영수증 쓰기 | 그 키퍼 |
| `Candle_ledger.update`, Candle 설정 변경 | 원장 쓰기가 닿는 키퍼마다. 설정은 모든 행(`keeper_roster_changed`). 원장 라이브러리는 키퍼도 SSE 도 모르므로, 서버가 append 를 받는 hook 으로 이벤트에서 키퍼를 찾는다 |
| provider 쉼과 걷는 순서의 기록. 쓰는 곳은 `Runtime_candidate_backpressure` 의 `note_rate_limit`·`note_failed_attempt`·`note_candidate_success` 와 `Runtime_quota_window` 의 `note_exhausted`·`note_observed_exhausted`·`note_succeeded` 여섯 함수뿐이다. 실패한 시도와 성공도 걷는 순서를 바꿔 행의 serving runtime 을 바꾼다 | 행에 보이는 값(`runtime_path_rest`)이 바뀐 키퍼마다. 쓰기마다 서버 fiber 하나가 깨어 모든 키퍼의 이 값을 다시 계산하고 앞 값과 비교한다. 바뀐 키퍼가 없으면 보내지 않는다 |

Owner observer 는 지금 "non-yielding, Owner fiber 에서 돈다"(`keeper_owner.ml:20~24`). 신호는 `Sse.broadcast` 한 번이라 이 조건을 지킨다. 다시 계산은 신호를 받은 쪽(TUI)이 읽기로 한다.

### 3.3 TUI 의 roster

- `keeper_row_changed` 마다 그 키퍼에 읽을 빚을 남긴다(RFC-0480 §3.1 의 읽을 빚). 키퍼마다 하나다. 읽은 행은 roster 안의 그 키퍼 자리를 바꿔 끼운다. 처음 보는 이름이면 이름 순서 자리에 더하고, 행이 없다는 답이면 그 행을 지운다. 한 배치에서 둘 이상의 키퍼가 빚을 지면 키퍼마다 읽지 않고 전체 읽기(`fresh=true`) 하나로 갚는다. 같은 runtime 을 지나는 키퍼들이 한꺼번에 바뀌는 경우다.
- `keeper_roster_changed`, 다시 읽기(Revalidate), 권한 회복은 roster 전체를 `fresh=true` 로 읽는다. 캐시된 전체 목록이 그 사이에 받은 키퍼 행을 옛 값으로 덮지 않게 하기 위해서다.
- 실패한 읽기는 키퍼마다 늘어나는 간격으로 다시 읽는다. 전체 읽기 실패는 지금처럼 옛 목록을 버리고 수명 동작을 거둔다(§1.8).
- 2초 묶음의 roster 읽기와 `needs_keeper_roster` 의 2초 갈래를 지운다.

### 3.4 turns

turns 응답(`GET /api/v1/keepers/turns`, `handle_keeper_turns_list`, `server_routes_http_keeper_stream.ml:465~550`)의 키퍼 항목은 턴 자리, turn ref, 미리보기, chat control token, Owner 를 쓸 수 있는지, 대기 목록을 읽는다. 대기 목록 말고는 meta 에 쓰지 않아서 Owner commit 신호가 덮지 못한다.

- 새 SSE `keeper_turn_changed { name }` 를 둔다. 아래 쓰기가 끝난 뒤 그 키퍼 이름으로 낸다. 미리보기는 §3.5 다.

| 쓰기 | 위치 |
|---|---|
| 턴 자리 | `Keeper_owner.publish_turn_in_flight`(채팅 시작, 자율·정비 턴 시작, 끝) |
| turn ref | `Keeper_autonomous_stream.create`·`finish`, current 표를 바꾼 뒤 |
| chat control token | 멈춤 상태(`paused`, `latched_reason`)가 바뀌는 전이, `Pause_and_interrupt` 회전. 키퍼 meta 가 생기거나 지워지는 전이도 멈춤 상태가 없음↔있음으로 바뀌어 여기에 든다(commit 뒤) |
| shutdown operation id | `Keeper_owner.publish_shutdown_operation_id` |
| Owner 를 쓸 수 있는지 | Owner pool 이 Owner 를 열거나 열지 못함(`keeper_owner_registry.ml`) |

- `keeper_turn_stream_event` 는 턴 자리와 turn ref 가 바뀌기 전에 나갈 수 있다. 그래서 turns 읽기의 신호로 쓰지 않는다.
- TUI 는 `keeper_turn_changed` 를 받으면 turns 전체를 읽을 빚을 남긴다(약 2 KB). 키퍼 하나씩 읽게 바꾸는 일은 이 RFC 밖이다. 다시 읽기와 권한 회복 때도 빚을 남긴다. 답변 중 배지는 모든 화면이 그리므로 화면에 들어올 때 따로 읽지 않는다. 어느 turns 읽기든 실패하면 늘어나는 간격으로 다시 읽는다.
- 2초 turns 읽기는 없다. 답변 중 배지와 채팅 화면의 준비 단계 읽기(`launch_selected_preparation_operation_read`)는 미리보기 알림(§3.5)으로 turns 를 읽어 미리보기를 따라간다.
- 대기 목록 읽기가 실패하면 늘어나는 간격으로 다시 읽는다.
- 대기 목록은 `keeper_waiting_inventory_changed` 로 읽는다. 일정(`schedule_store_invalidated`), 확인 대기(`operator_pending_confirm_invalidated`), fusion(`fusion_run_status`) 알림도 대기 목록을 읽을 빚을 남긴다. 셋 다 이미 나가는 알림이라 서버는 바꾸지 않는다. 일정과 확인 대기 알림은 키퍼 이름이 없다. 그래서 알림만으로는 화면의 행을 비우지 않는다. 다만 알림 전에 시작한 대기 목록 읽기는 현재 값으로 받지 않는다. 그 읽기가 답하면 그 키퍼 행은 뒤따르는 읽기가 답할 때까지 '확인 안 됨'으로 보인다. 대기 목록 읽기는 대기 상태만 바꾸고, turns 행·토큰·끝난 턴 표시는 turns 읽기가 바꾼다.
- turns 읽기 결과를 다루는 곳(§1.8: 대기 영수증, control generation, 끝난 턴 표시, `launch_waiting_keeper_input`, 기록·준비 단계 읽기, Metrics)은 읽기가 신호로 일어나도 그대로 돈다. 끝난 턴 표시는 두 읽기 사이의 running→idle 로 정해진다. 시작 신호의 읽기가 끝나기 전에 턴이 끝나면 표시되지 않는 것은 2초 읽기와 같다.
- 웹 대시보드는 turns 응답 모양이 그대로라 바뀌지 않는다.

### 3.5 미리보기

미리보기를 그리는 화면(그 키퍼의 채팅 화면, 키퍼 목록)이 열려 있을 때만 turns 를 다시 읽는다. 그런 화면이 없을 때 바뀐 키퍼는 기억해 두었다가, 그 미리보기를 그리는 화면에 들어오면 한 번 읽는다. 서버는 `Keeper_turn_preview` 의 쓰기(`change_entry`, `observe_preparation`, `reset`) 가운데 turns 답이 읽는 writer 에 쓴 것만 알린다. 옛 writer 의 쓰기는 turns 답을 바꾸지 않는다. 미리보기 표는 키퍼 이름으로만 잡혀 있으므로, `reset` 이 작업 공간(`base_path`)을 받아 writer 에 담는다.

서버 fiber 하나가 쓰인 키퍼를 모아, 그 작업 공간의 관찰자에게 키퍼마다 `keeper_turn_preview_changed { name }` 를 한 번 보내고 `preview_post_interval_s` 를 기다린다. 첫 쓰기는 바로 나가고, 기다리는 동안의 쓰기는 기다림이 끝날 때 한 번에 나간다. 키퍼마다 타이머를 두지 않는다. 받는 쪽은 그때의 최신 값을 읽으므로 버려지는 값은 없다. 사이 값을 그리지 않을 뿐이다.

키퍼 목록의 마지막 활동 시각은 미리보기 시각 대신, 도는 턴은 시작 시각을, 끝난 턴은 마지막 턴 시각을 쓴다. 목록이 초 단위로 미리보기를 따라가지 않는다. §7 결정 1 이다.

### 3.6 `next_action`

`Probe` 는 health 가 failing 일 때와, healthy·idle 인 키퍼가 아직 시작 중일 때만 나온다(`keeper_status_runtime.ml:286~303`). 그래서 health 가 failing 이 아닌데 `next_action` 이 `Probe` 이면 시작 중이고, 값은 `created_at + 120초` 에 바뀐다. 행의 identity 에 `created_at` 이 있다. TUI 는 그 시각에 그 키퍼에 읽을 빚을 한 번 남긴다. 120초는 서버 상수 `Keeper_status_runtime.agent_staleness_threshold_s` 를 그대로 쓴다(TUI 가 이미 `Masc` 를 링크한다). 서버와 TUI 의 시계가 다르면 그만큼 늦거나 이르게 읽는다. 이르면 값이 아직 같고, 다음 신호나 다시 읽기가 맞춘다.

### 3.7 읽는 시각으로 바뀌는 다른 값

- Candle 잔액과 공급량: roster 응답은 CanAdmin 일 때 `candle` 옆에 접기의 기준 `candle_decay` 를 싣는다. 반감기, 읽는 시각까지 줄이기 전의 `burned`, 잔액 기록이 있는 키퍼마다 마지막 잔액 이벤트 시각(`since`)과 그 직후 잔액(`amount_milli`)이다. TUI 는 그릴 때 지금 시각으로 계산한다.
  - 키퍼 잔액 = `Candle_decay.remaining ~half_life ~since ~at ~amount_milli`
  - `burned` = 기준 `burned` + 키퍼마다 (`amount_milli` − 잔액)
  - `circulating` = `issued` − `burned`

  서버가 같은 시각에 접는 것과 같은 함수에 같은 입력이라 값이 같다. 한 번 줄인 값을 다시 줄이면 내림이 겹쳐 서버 값과 1 milli 쯤 달라질 수 있어서, 읽는 시각의 값이 아니라 줄이기 전 기준을 싣는다. TUI 는 행의 `candle_balance_milli` 를 읽지 않는다. 그 필드는 웹 대시보드가 쓰므로 투영에 남는다. Items 탭은 잔액 대신 그 키퍼의 기준(`since`, `amount_milli`)으로 바뀜을 알아본다. 서버 타이머도, 다시 읽기도 없다.
- provider 쉼: §3.2 의 서버 fiber 가 `Rest_dated` 중 가장 이른 끝나는 시각에 한 번 깨어 다시 계산한다. 키퍼마다 타이머를 두지 않고, fiber 하나가 다음 시각 하나만 기다린다. 행에는 끝나는 시각을 싣지 않고, TUI 에도 타이머가 없다. `Rest_until_answered` 는 시각으로 끝나지 않으므로 쓰기 신호로만 맞춘다.

## 4. 규모

- 키퍼 하나 읽기는 행 하나(약 0.2 KB)다. 빈도는 그 키퍼의 쓰기 수다. 2026-11-02 측정에서 `keeper_composite_changed` 는 전체 초당 0.40건, 키퍼 하나 최대 0.20건이었다. Owner commit 은 이보다 잦을 수 있다(턴마다 카운터). L2 에서 잰다.
- RFC-0480 §7 의 기준대로, 키퍼 화면 하나의 초당 요청이 지금의 2초 읽기(초당 0.5번)보다 많으면 그 신호를 다시 본다.
- 미리보기 읽기는 미리보기를 그리는 화면 하나당 초당 1 ÷ `preview_post_interval_s` 를 넘지 않는다.

## 5. 작업 나눔

스택 PR 로 올린다. 각 층은 20k token 안쪽이다.

| 층 | 내용 | 확인 |
|---|---|---|
| L0 | 이 RFC | 리뷰 |
| L1 | roster 경로의 `name=` 키퍼 하나 읽기 | 같은 키퍼의 행이 전체 읽기의 행과 같은지, 오류 행, 인증 |
| L2a~ | §3.2 의 신호. 쓰기 하나가 층 하나다 | 쓰기마다 신호가 한 번 나가는지 |
| L2f | provider 쉼 신호: 여섯 쓰기 함수의 hook, 서버 fiber 의 다시 계산과 비교, 가장 이른 `Rest_dated` 시각에 깨기(§3.2, §3.7) | 쓰기·시각마다 값이 바뀐 키퍼에게만 신호, 바뀌지 않으면 없음 |
| L3 | TUI roster: 키퍼 하나 읽기(L3a), 키퍼별 빚 읽기와 목록 변화 전체 읽기(L3b), 2초 roster 읽기 삭제(L3c, L6·L6b 뒤) | 신호 하나 → 요청 하나, 실패 재시도 |
| L4a | `keeper_turn_changed`: 턴 자리, turn ref, chat control token, shutdown id, Owner 사용 가능 여부의 쓰기 뒤 신호(§3.4) | 쓰기마다 신호가 한 번, 값이 바뀐 뒤에 나가는지 |
| L4b | TUI turns 빚 읽기(신호, 다시 읽기, 권한 회복, 실패 재시도), 일정·확인 대기·fusion 알림의 대기 목록 빚 | §1.8 의 일들이 신호 뒤에 도는지 |
| L4c | 2초 turns 읽기 삭제, 대기 목록 읽기 실패 재시도(L5 뒤) | 화면 하나의 turns 요청 수, 실패한 대기 목록 읽기를 기다린 뒤 다시 읽는지 |
| L5a | 미리보기 알림: turns 답이 읽는 writer 의 쓰기 뒤, fiber 하나가 간격마다 모아 보냄 | 간격 안의 여러 쓰기 → 알림 하나, 옛 writer 의 쓰기 → 알림 없음 |
| L5b | TUI 미리보기 읽기, 목록 활동 시각 | 알림 → turns 읽기 하나 |
| L6 | `next_action` 시각 읽기 | 120초 뒤 읽기 하나 |
| L6b | roster 응답의 `candle_decay`(서버), TUI 가 그릴 때 잔액·`burned`·`circulating` 계산(§3.7) | 같은 원장에서 기준으로 계산한 값 = 같은 시각의 `of_events` 값 |

L2 가 다 들어가기 전에는 L3 을 넣지 않는다. 신호가 빠진 필드는 L3 뒤에 멈추기 때문이다. 같은 까닭으로 2초 roster 읽기(L3c)는 시각으로 바뀌는 값(L6, L6b)이 들어간 뒤에 지운다.

## 6. 트레이드오프와 한계

- 신호를 빠뜨린 쓰기가 있으면 그 필드가 멈춘다. 신호를 쓰기 함수 안에 두고 호출부에 두지 않는 것으로 막는다. 그래도 앞으로 새 저장소가 행에 들어오면 신호를 같이 넣어야 한다.
- 디스크에서 키퍼 파일을 직접 고치면 신호가 없다. Revalidate(관찰자 피드가 다시 열릴 때)나 `r` 까지 행이 바뀌지 않는다.
- Owner commit 과 영수증 쓰기는 값이 같아도 신호를 낸다. registry 와 runtime 배정은 행이 읽는 값이 바뀔 때만 낸다. 앞의 둘 때문에 받는 쪽 읽기가 늘 수 있다(§4). registry 의 비교(`row_fields_changed`)는 행이 registry 에서 읽는 값과 손으로 맞춘 목록이라, 행이 registry 값을 더 읽게 되면 함께 고쳐야 한다.
- 미리보기는 간격 사이의 중간 값을 그리지 않는다.
- TUI 시계가 서버 시계와 다르면 Candle 값은 그만큼 다른 시각의 값으로 그려지고, `next_action` 다시 읽기는 그만큼 이르거나 늦다.

## 7. 결정이 필요한 것

1. 키퍼 목록의 마지막 활동 시각을 미리보기 대신 턴 시작·마지막 턴 시각으로 바꿀지(§3.5). 추천은 바꾸는 것이다. 지금은 도는 키퍼의 시각이 기록마다 움직인다.
2. `preview_post_interval_s` 값. 추천은 0.25초다. 답변 중 배지는 초 단위 경과 시간과 한 줄 상태를 보인다.
