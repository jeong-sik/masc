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

RFC-0480 은 이 둘을 RFC-0477 의 fleet 처럼 타입 스트림으로 옮기기로 했다(RFC-0480 §0 결정 2, L7). 이 RFC 의 첫 초안도 그렇게 설계했다. 그 초안을 코드와 대조해 검토하니, 타입 스트림으로는 지금 경로가 이미 하는 일을 다시 만들어야 했다.

- 인증: roster 는 도구 권한(`channel_gate`)으로 읽는다. fleet 스트림은 공개 읽기다(§1.7).
- Candle: 잔액과 계정 revision 은 관리자 토큰에만 붙는다. Info 탭과 Home·Usage 가 그린다(§1.6).
- 오류 행: meta 를 못 읽은 키퍼는 오류 행으로 오고, TUI 는 그 행으로 "설정이 깨졌으니 지울까요"를 묻는다(§1.8).
- 웹 대시보드도 turns 를 읽는다(§1.8).

결정은 다섯 가지다.

1. 타입 스트림 대신, 키퍼 하나가 바뀌었다는 신호를 보낸다. TUI 는 그 키퍼 행만 기존 roster 경로로 다시 읽는다. 인증, Candle, 오류 행, 디코더는 지금 것을 그대로 쓴다(§3.1~§3.3). RFC-0480 결정 2 를 이렇게 바꾸는 것은 §7 결정 1 이다.
2. 신호는 값을 쓰는 곳에서 낸다. 지금 알림이 없는 쓰기마다 신호를 더한다(§3.2). 키퍼가 생기거나 없어지면 목록 전체를 다시 읽는다.
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
| sandbox profile, identity | meta·TOML. meta 를 쓰는 곳은 Owner 하나다(`keeper_meta_store.ml:193~196`) | 위 Owner 와 같음 |
| lane 관찰 | 실행 영수증 쓰기(`keeper_execution_receipt.ml:544`) | 일부 영수증만 Activity_graph 이벤트(`:521`) |
| 초상, Candle 잔액 | Candle 원장(`Candle_ledger.update`)과 Candle 설정(`candle_observe.ml:6~27`). 원장 쓰기 하나가 여러 키퍼에 닿을 수 있다(선물) | 없음(`lib/candle*` 에 `Sse.` 호출 없음) |
| 턴 자리, chat control token | `publish_turn_in_flight`(`keeper_owner.ml:610~615`), pause 전이(`:931~933`) | Owner observer 만 |
| turn ref | `Keeper_autonomous_stream.create`(`:82`)·`finish`(`:195`). Owner 가 턴 자리를 알린 뒤에 생긴다(`keeper_unified_turn_execution.ml:176`, `keeper_owner.ml:2917`) | 없음 |

지금은 2초 읽기가 이 빈틈을 가린다. 신호로 바꾸면 빈틈마다 화면이 멈춘다.

### 1.4 읽는 시각으로 정해지는 값

`next_action` 은 턴을 한 번도 돌지 않은 키퍼가 만든 지 120초(`agent_staleness_threshold_s`)가 지났는지로 정해진다. 지나기 전이면 `Probe`, 지나면 `Direct_message` 다(`keeper_status_runtime.ml:230~243`, `:286~303`). 그 순간에는 아무것도 쓰이지 않는다. `health` 는 시각에 기대지 않는다(`:268`).

### 1.5 미리보기

- `Keeper_turn_preview.change_entry` 는 값을 바꿀 때마다 `updated_at` 을 그 시각으로 바꾼다(`keeper_turn_preview.ml:104~113`). 2026-11-02 밤 라이브에서 `keeper_turn_stream_event` 는 초당 약 27건이었다(60초 1회, 신뢰 낮음).
- `observe_preparation`(`:140`, `:159`, `:165`)과 `reset`(`:195`)은 `change_entry` 를 거치지 않고 쓴다.
- 표에서 항목을 지우지 않는다. 미리보기를 고르는 열쇠는 Owner 의 interrupt token 이다(`server_routes_http_keeper_stream.ml:507~515`). 채팅 작업 턴은 turn ref 가 없다.
- 쓰는 곳: 답변 중 배지(`bin/masc_tui_answering.ml:113~238`), 키퍼 목록의 마지막 활동 시각(`bin/masc_tui_types.ml:12317~12341`), 채팅 화면(`bin/masc_tui_render_chat.ml:1895~1976`).

### 1.6 Candle

잔액은 Info 탭이 그리고(`bin/masc_tui_render_keepers.ml:1404`, `info_lines` 안), 계정 revision 은 Items 탭이 쓴다(`bin/masc_tui.ml:5253`, `:5377`). roster 응답의 workspace 단위 Candle 값(`state.candle_observation`, `bin/masc_tui.ml:14628`)은 Home, Usage, 도움말이 그린다. 잔액은 읽는 시각으로 줄어든다(decay). 둘 다 요청 토큰이 CanAdmin 일 때만 붙는다(`channel_gate.ml:518~523`).

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
| 행을 타입 이벤트로 보낸다(이 RFC 첫 초안, RFC-0480 결정 2) | 스트림에 도구 권한과 CanAdmin 구분을 새로 넣어야 한다(§1.7). 행에 붙은 하위 타입마다 엄격한 코덱을 새로 써야 한다. 오류 행, `Unavailable` 턴, 200명 상한을 다시 만들어야 한다. 허브가 키퍼마다 디스크(meta, TOML, 영수증, Candle 원장)를 다시 읽어 비교해야 하고, 그 일은 Owner fiber 와 허브 락 밖에서 돌아야 한다. 신호를 내는 쓰기는 이 길에도 똑같이 필요하다 |
| 알림마다 roster 전체를 다시 읽는다 | 키퍼 수에 비례한다. 300명이면 한 번에 약 68 KB(40명 9 KB 에서 선형 추정)이고, 알림도 키퍼 수만큼 잦아진다 |
| 서버가 몇 초마다 행을 다시 계산해 비교한다 | 폴링을 서버로 옮길 뿐이다. 신호가 빠진 쓰기가 계속 숨는다 |
| `next_action` 이 바뀔 시각에 서버 타이머를 건다 | 키퍼마다 타이머가 생긴다. 바뀔 시각은 행이 이미 알려 준다(§3.6) |
| 미리보기를 기록마다 알린다 | 초당 수십 번 알리고, 받는 쪽은 그때마다 읽는다 |

## 3. 설계

### 3.1 키퍼 하나 읽기

roster 경로에 `name=<키퍼>` 를 더한다. 그 키퍼의 행 하나(또는 오류 행 하나)를 지금 roster 와 같은 모양으로 준다. 인증, CanAdmin 일 때의 Candle 값, 오류 행, 디코더가 그대로다. 캐시는 이 읽기에 쓰지 않는다. 키퍼 하나를 만드는 비용은 지금 roster 의 행 하나와 같다.

### 3.2 신호

새 SSE `keeper_row_changed { name }` 를 하나 둔다. 키퍼 목록이 바뀌면 `keeper_roster_changed` 를 낸다. 신호는 쓰기 함수 안에서 쓰기가 끝난 뒤 낸다(RFC-0480 §3.4). roster 캐시는 신호 전에 지운다.

| 쓰기 | 신호 |
|---|---|
| Owner commit(meta 저장소 `replace`·`remove`). paused, activation, 사용 카운터, `updated_at`, sandbox profile, 턴 자리, chat control token 이 모두 여기를 지난다 | 그 키퍼 `keeper_row_changed` |
| registry 항목 commit(단계, 실패 이유와 시각, keepalive) | 그 키퍼 |
| registry 목록 변화 | `keeper_roster_changed` |
| `runtime.toml` 배정 트랜잭션, 기본 경로 변경, 설정 다시 읽기 | 배정이 닿는 키퍼마다. 기본 경로는 모든 키퍼 |
| 실행 영수증 쓰기 | 그 키퍼 |
| `Candle_ledger.update`, Candle 설정 변경 | 원장 쓰기가 닿는 키퍼마다. 설정은 모든 키퍼 |
| `Keeper_autonomous_stream.create`·`finish` | 그 키퍼 |

Owner observer 는 지금 "non-yielding, Owner fiber 에서 돈다"(`keeper_owner.ml:20~24`). 신호는 `Sse.broadcast` 한 번이라 이 조건을 지킨다. 다시 계산은 신호를 받은 쪽(TUI)이 읽기로 한다.

### 3.3 TUI 의 roster

- `keeper_row_changed` 마다 그 키퍼에 읽을 빚을 남긴다(RFC-0480 §3.1 의 읽을 빚). 키퍼마다 하나다. 읽은 행은 roster 안의 그 키퍼 자리를 바꿔 끼운다.
- `keeper_roster_changed`, 다시 읽기(Revalidate), 권한 회복은 roster 전체를 읽는다.
- 실패한 읽기는 키퍼마다 늘어나는 간격으로 다시 읽는다. 전체 읽기 실패는 지금처럼 옛 목록을 버리고 수명 동작을 거둔다(§1.8).
- 2초 묶음의 roster 읽기와 `needs_keeper_roster` 의 2초 갈래를 지운다.

### 3.4 turns

- 턴 자리와 chat control token 은 Owner commit 의 `keeper_row_changed` 가 알린다. turns 는 지금처럼 전체를 읽는다(약 2 KB). 키퍼 하나씩 읽게 바꾸는 일은 이 RFC 밖이다.
- 대기 목록은 `keeper_waiting_inventory_changed` 로 읽는다. 일정, 확인 대기, fusion 대기에 같은 알림을 더한다.
- 2초 turns 읽기에 기대던 일(§1.8)은 turns 읽기 결과를 다루는 곳에서 돈다. 읽기가 신호로 일어나도 그대로 돈다. 층마다 이 일들이 신호 뒤에도 일어나는지 시험한다.
- 웹 대시보드는 turns 응답 모양이 그대로라 바뀌지 않는다.

### 3.5 미리보기

미리보기를 쓰는 화면(답변 중 배지, 채팅 화면)이 열려 있을 때만 그 키퍼의 turns 를 다시 읽는다. 서버는 `Keeper_turn_preview` 의 모든 쓰기(`change_entry`, `observe_preparation`, `reset`)에서 그 키퍼의 `keeper_turn_preview_changed` 를 내되, 키퍼마다 마지막으로 낸 뒤 `preview_post_interval_s` 가 지나지 않았으면 그 간격이 끝날 때 한 번만 낸다. 받는 쪽은 그때의 최신 값을 읽으므로 버려지는 값은 없다. 사이 값을 그리지 않을 뿐이다.

키퍼 목록의 마지막 활동 시각은 미리보기 시각 대신, 도는 턴은 시작 시각을, 끝난 턴은 마지막 턴 시각을 쓴다. 목록이 초 단위로 미리보기를 따라가지 않는다. §7 결정 2 다.

### 3.6 `next_action`

`Probe` 는 health 가 failing 일 때와, healthy·idle 인 키퍼가 아직 시작 중일 때만 나온다(`keeper_status_runtime.ml:286~303`). 그래서 health 가 failing 이 아닌데 `next_action` 이 `Probe` 이면 시작 중이고, 값은 `created_at + 120초` 에 바뀐다. 행의 identity 에 `created_at` 이 있다. TUI 는 그 시각에 그 키퍼에 읽을 빚을 한 번 남긴다. 120초는 서버 상수 `Keeper_status_runtime.agent_staleness_threshold_s` 를 그대로 쓴다(TUI 가 이미 `Masc` 를 링크한다). 서버와 TUI 의 시계가 다르면 그만큼 늦거나 이르게 읽는다. 이르면 값이 아직 같고, 다음 신호나 다시 읽기가 맞춘다.

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
| L2a~ | §3.2 의 신호. 쓰기 하나가 층 하나다 | 쓰기마다 신호가 한 번 나가는지, 신호 전에 캐시가 지워졌는지 |
| L3 | TUI roster: 키퍼별 빚 읽기, 목록 변화 전체 읽기, 2초 roster 읽기 삭제 | 신호 하나 → 요청 하나, 실패 재시도 |
| L4 | 대기 목록 빈 곳 알림(일정, 확인 대기, fusion), TUI turns 의 2초 읽기 삭제 | §1.8 의 일들이 신호 뒤에 도는지 |
| L5 | 미리보기 알림과 그 화면의 읽기, 목록 활동 시각 | 간격 안의 여러 쓰기 → 알림 하나 |
| L6 | `next_action` 시각 읽기 | 120초 뒤 읽기 하나 |

L2 가 다 들어가기 전에는 L3 을 넣지 않는다. 신호가 빠진 필드는 L3 뒤에 멈추기 때문이다.

## 6. 트레이드오프와 한계

- 신호를 빠뜨린 쓰기가 있으면 그 필드가 멈춘다. 신호를 쓰기 함수 안에 두고 호출부에 두지 않는 것으로 막는다. 그래도 앞으로 새 저장소가 행에 들어오면 신호를 같이 넣어야 한다.
- 디스크에서 키퍼 파일을 직접 고치면 신호가 없다. Revalidate(관찰자 피드가 다시 열릴 때)나 `r` 까지 행이 바뀌지 않는다.
- 신호는 값이 같아도 나간다. 서버가 비교하지 않기 때문이다. 받는 쪽 읽기가 그만큼 늘 수 있다(§4).
- 미리보기는 간격 사이의 중간 값을 그리지 않는다.

## 7. 결정이 필요한 것

1. RFC-0480 결정 2(키퍼 행은 타입 이벤트로)를 이 RFC 의 "키퍼 하나 신호 → 그 키퍼 다시 읽기"로 바꿀지. 추천은 바꾸는 것이다(§2 첫 줄). 바꾸면 RFC-0480 의 결정 2 와 L7 행을 고친다.
2. 키퍼 목록의 마지막 활동 시각을 미리보기 대신 턴 시작·마지막 턴 시각으로 바꿀지(§3.5). 추천은 바꾸는 것이다. 지금은 도는 키퍼의 시각이 기록마다 움직인다.
3. `preview_post_interval_s` 값. 추천은 0.25초다. 답변 중 배지는 초 단위 경과 시간과 한 줄 상태를 보인다.
