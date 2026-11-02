---
rfc: "0481"
title: "키퍼 행은 2초마다 통째로 읽지 않고, 바뀐 키퍼만 타입이 있는 이벤트로 받는다"
status: Draft
created: 2026-11-03
updated: 2026-11-03
author: vincent + claude
supersedes: []
superseded_by: null
related: ["0477", "0480"]
---

# RFC-0481 — 키퍼 행은 바뀐 키퍼만 받는다

## 0. 요약

TUI 는 2초마다 키퍼 목록 두 개를 통째로 읽는다.

- roster `GET /api/v1/gate/keepers?detailed=true`: Overview, Keepers 의 모든 화면, Metrics, 그리고 키퍼 패널이나 About 이 보이는 모든 화면에서 읽는다.
- turns `GET /api/v1/keepers/turns`: 모든 화면에서 읽는다.

RFC-0480 은 이 둘을 RFC-0477 의 fleet 처럼 타입 스트림으로 옮기기로 했다(RFC-0480 §0 결정 2, L7). 이 RFC 는 그 설계다.

코드를 직접 읽어 보니 RFC-0477 의 방법("값을 다시 계산해서 이전 값과 다르면 보낸다")을 그대로 쓸 수 없는 사실이 넷 있다.

1. 행의 필드 여럿이 바뀌어도 알리는 곳이 없다. 허브가 언제 다시 계산할지 알 수 없다(§1.3).
2. `next_action` 은 읽는 시각으로 정해진다. 아무것도 쓰지 않아도 값이 바뀐다(§1.4).
3. 턴 미리보기(preview)는 턴 스트림 기록마다 `updated_at` 이 바뀐다(§1.5).
4. Candle 잔액과 계정 revision 은 관리자 토큰에만 붙고, 잔액은 읽는 시각으로 정해진다(§1.6).

결정은 여섯 가지다.

1. fleet 스트림(`GET /api/v1/stream/fleet`)에 키퍼 행 주제를 더한다. 번호(`revision`)는 스트림 하나가 공유한다(RFC-0477 §3.6).
2. 행에는 roster 행과 턴 자리(쉬는 중인지, 도는 중이면 lane·시작 시각·interrupt token·turn ref, chat control token)를 싣는다. 미리보기, Candle 잔액, 대기 목록은 싣지 않는다(§3.1).
3. 행에 읽는 시각으로 정해지는 값을 싣지 않는다. `next_action` 대신 그 값을 정하는 사실을 싣고, TUI 가 서버와 같은 함수에 자기 시각을 넣어 계산한다(§3.2).
4. 허브는 값을 쓰는 곳에서 키퍼 이름과 함께 깨운다. 지금 알림이 없는 쓰기마다 깨움을 더한다. 주기적인 다시 계산은 두지 않는다(§3.3).
5. 미리보기는 같은 스트림의 별도 주제로 보낸다. 키퍼마다 마지막 값만 들고, 정해진 간격보다 자주 보내지 않는다(§3.4).
6. 대기 목록과 Candle 잔액은 RFC-0480 의 방법 1(알림 → 그 화면이 다시 읽기)로 둔다(§3.5).

## 1. 지금 상태 (스택 `12939d7fdc2`, 2026-11-03 직독)

### 1.1 TUI 가 읽는 것

| 읽기 | 언제 | 디코더 | 위치 |
|---|---|---|---|
| roster | 2초 묶음의 `needs_keeper_roster`. Overview·Keepers 전부·Metrics, 키퍼 패널이 그려지는 모든 화면, About | `decode_keeper_runtime_list` → `keeper_runtime` | `bin/masc_tui_types.ml:4479`, `:4522~4581`, `lib/tui_decode.ml:139~166`, `:3084`, `:3203` |
| turns | 모든 화면, 2초마다 `launch_tick_side_reads` → `launch_keeper_turns_load` | `decode_keeper_turns_projection` → `keeper_turn_row`, `keeper_waiting_row` | `bin/masc_tui.ml:3506`, `:16702`, `lib/tui_decode.ml:4584~4661`, `:4953` |
| turns(대기만) | `keeper_waiting_inventory_changed` 알림 | 같은 디코더 | `bin/masc_tui.ml:3487` |

turns 는 채팅 화면에서 턴 칸을 펼쳤을 때만 `preparation_details_for=<키퍼>` 를 붙인다. 그러면 서버가 그 키퍼의 준비 단계 목록을 더 싣는다(`lib/server/server_routes_http_keeper_stream.ml:525`).

크기는 roster 약 9 KB, turns 약 2 KB 다(키퍼 40명, `bin/masc_http_probe.ml:14~18`). 서버 처리 시간은 둘 다 수 ms 인데, 같은 측정에서 TUI 쪽 시간은 roster 3,013 ms, turns 1,361 ms 였다. RFC-0204 의 분포는 roster p99 8.5초, turns p99 1.3초다.

### 1.2 서버가 행을 만드는 곳

**roster.** `masc_keeper_list` 도구다(`lib/server/server_routes_http_routes_channel_gate.ml:472`, 행은 `lib/keeper/keeper_tool_surface_ops.ml:318~444`).

- 디스크: 키퍼 이름 목록, meta 와 TOML 덮어쓰기, 마지막 실행 영수증(dated JSONL)
- 메모리: `Keeper_registry` 의 단계와 마지막 실패
- 초상: `Candle_equipment.reader ~now`(`lib/keeper/keeper_tool_surface.ml:110~120`)
- Candle 잔액과 계정 revision: 요청 토큰이 CanAdmin 일 때만 붙는다(`channel_gate.ml:518~523`, `lib/dashboard/dashboard_projection_cache.ml:212`)
- 캐시: 키 `base_path:limit:detailed`, 기본 2초(`MASC_KEEPER_LIST_CACHE_TTL_S`). keeper up·down 과 메시지 스트림 정리 때 지운다.

**turns.** `handle_keeper_turns_list` 다(`server_routes_http_keeper_stream.ml:465~550`). 캐시는 없다.

- `Keeper_owner_registry` 의 턴 자리와 chat control token
- `Keeper_turn_preview` 의 메모리 표(`lib/keeper/keeper_turn_preview.ml:81`)
- `Keeper_autonomous_stream.current` 의 turn ref
- 대기 목록: 승인 큐, fusion, 확인 대기, 일정, 이벤트 큐 파일(`lib/server_keeper_waiting_inventory.ml:1231~1262`)

### 1.3 바뀌어도 알리지 않는 필드

| 필드 | 바뀌는 곳 | 지금 나가는 것 |
|---|---|---|
| 단계, keepalive | `Keeper_registry` | SSE `keeper_phase_changed`, `keeper_composite_changed`(`lib/keeper/keeper_registry.ml:848~958`) |
| paused, activation mode, chat control token | Owner meta 전이(`lib/keeper/keeper_owner.ml:909~935`) | 서버 안의 observer 만. 키퍼 이름을 넘기지 않는다(`keeper_owner.ml:9~19`). health 스냅샷 무효화만 한다 |
| 마지막 실패, blocker | `Failure_reason_changed`(`lib/keeper/keeper_registry_setup.ml:268~330`) | observer 만 |
| 키퍼가 생기고 없어짐 | `Membership_changed`(`keeper_registry_setup.ml:641`, `:898`, `:970`) | observer 만. 디스크에만 생긴 키퍼는 아무것도 없다 |
| 턴 자리 | `publish_turn_in_flight`(`keeper_owner.ml:610~615`) | observer 만. `turn_started`·`turn_completed` 는 Agent_core 쪽에서 따로 나간다. 둘이 같은 순간인지는 확인하지 못했다 |
| runtime id, sandbox profile, identity(`updated_at`) | meta·TOML 쓰기 | 없음 |
| lane 관찰 | 실행 영수증 쓰기(`lib/keeper/keeper_execution_receipt.ml:544`) | 없음 |
| 초상 | Candle 장비 | 없음 |

지금은 2초 읽기가 이 빈틈을 가린다. 스트림으로 바꾸면 빈틈마다 화면이 멈춘다.

### 1.4 읽는 시각으로 정해지는 값

`next_action` 은 키퍼가 아직 턴을 한 번도 돌지 않았으면 만든 지 `agent_staleness_threshold_s` 가 지났는지로 정해진다. 지나기 전이면 `Probe`, 지나면 `Direct_message` 다(`lib/keeper/keeper_status_runtime.ml:230~243`, `:298~303`). 그 순간에는 아무것도 쓰이지 않는다. 값을 비교하는 허브는 이 변화를 볼 수 없다.

### 1.5 미리보기

`Keeper_turn_preview.change_entry` 는 기록이 값을 바꿀 때마다 `updated_at` 을 그 시각으로 바꾼다(`keeper_turn_preview.ml:104~113`). 2026-11-02 밤 라이브에서 `keeper_turn_stream_event` 는 초당 약 27건이었다(60초 1회, 신뢰 낮음). 관찰자 피드의 이 이벤트는 키퍼·turn ref·번호·시각만 싣고 본문이 없다(`bin/masc_tui_observer.ml:567~578`). 그래서 TUI 가 이벤트를 접어서 미리보기를 만들 수 없다.

미리보기를 쓰는 곳: 답변 중 배지(`bin/masc_tui_answering.ml:113~238`, `bin/masc_tui_render_overlays.ml:1092~1108`), 키퍼 목록의 마지막 활동 시각(`bin/masc_tui_types.ml:12317~12341`), 채팅 화면(`bin/masc_tui_render_chat.ml:1895~1976`, `:3652`).

### 1.6 Candle

잔액과 계정 revision 은 Items 탭만 쓴다(`bin/masc_tui.ml:5253`, `:5377`, `bin/masc_tui_render_keepers.ml:1404`). 잔액은 읽는 시각으로 정해진다(`dashboard_projection_cache.ml:41~42`, `Candle_observe.read ~now`). 초상은 목록·상세·채팅·About 이 쓴다. 초상이 시각에 따라 바뀌는지는 확인하지 못했다.

## 2. 고르지 않은 길

| 길 | 고르지 않은 이유 |
|---|---|
| 알림마다 roster 전체를 다시 읽는다 | 키퍼 수에 비례한다. 키퍼 300명이면 한 번에 약 68 KB(40명 9 KB 에서 선형 추정)이고, 알림도 키퍼 수만큼 잦아진다. RFC-0480 결정 2 가 이 길을 닫았다 |
| 허브가 몇 초마다 모든 행을 다시 계산해 비교한다 | 폴링을 서버로 옮길 뿐이다. 알림이 빠진 쓰기가 계속 숨는다. 다시 계산 비용이 키퍼 수에 비례한다 |
| 키퍼 하나를 읽는 경로를 만들고, 알림마다 그 키퍼만 읽는다 | 키퍼가 생기고 없어지는 것을 따로 맞춰야 한다. 알림이 빠진 필드는 이 길에서도 멈춘다. 결국 §3.3 의 깨움이 똑같이 필요하고, 요청 수만 더 많다 |
| `next_action` 이 바뀔 시각에 서버 타이머를 건다 | 키퍼마다 타이머가 생긴다. 값은 이미 다른 필드로 정해지므로 받는 쪽이 계산하면 된다 |
| 미리보기를 행에 넣는다 | 행 이벤트가 초당 수십 번 나가고, 그때마다 행 전체를 비교한다 |
| 미리보기를 관찰자 이벤트에서 TUI 가 만든다 | 이벤트에 본문이 없다(§1.5). 본문을 실으면 관찰자 피드의 모든 구독자가 받는다 |

## 3. 설계

### 3.1 행

`lib/fleet_stream/` 에 행 타입과 코덱을 더한다. RFC-0477 §3.1 의 규칙을 그대로 따른다. 모르는 필드·빠진 필드는 디코드 오류이고 기본값으로 채우지 않는다.

```ocaml
(* 요약. 필드는 지금 Tui_decode.keeper_runtime 과 keeper_turn_row 에서 TUI 가 읽는 것만 옮긴다 *)
type turn_slot =
  | Idle
  | Running of { lane : string; started_at : float; interrupt_token : string;
                 turn_ref : Ids.Turn_ref.t option }

type row = {
  name : string;
  identity : keeper_identity;
  portrait : Keeper_portrait_equipment.reading;
  phase : Keeper_state_machine.phase;
  keepalive_running : bool;
  paused : bool;
  activation_mode : Keeper_activation_mode.t;
  health : Keeper_types.keeper_health;
  quiet_facts : quiet_facts;          (* §3.2 *)
  runtime_id : string;
  sandbox_profile : string;
  runtime_blocker : runtime_blocker option;
  last_failure : keeper_failure option;
  lane_observation : lane_observation option;
  turn : turn_slot;
  chat_control_token : string option;
}

type event = (* 기존 fleet 이벤트에 더한다 *)
  | Rows_snapshot of { revision : Revision.t; rows : row list }
  | Row_changed of { revision : Revision.t; row : row }
  | Row_removed of { revision : Revision.t; name : string }
  | Preview_changed of { revision : Revision.t; name : string; turn_ref : Ids.Turn_ref.t;
                         preview : preview }
  | Preview_cleared of { revision : Revision.t; name : string }
```

- 연결 직후 첫 상태에 행 전부가 같이 온다. fleet `Snapshot` 과 같은 번호로 오는지, 이벤트 둘로 오는지는 L1 에서 코덱 시험과 함께 정한다. 둘로 오면 첫 상태가 두 이벤트 다 와야 끝난다.
- `Row_changed` 는 그 키퍼의 행 전체를 바꿔 끼운다. 필드 단위 차이는 보내지 않는다.
- 키퍼 이름은 행 목록 안에서 한 번만 나온다. 같은 이름이 두 번 오면 디코드 오류다.

### 3.2 시각으로 정해지는 값은 받는 쪽이 계산한다

`next_action` 과 quiet reason 은 `Keeper_status_runtime.classify_keeper_quiet_reason` 과 `keeper_next_action_path` 가 정한다. 입력은 activation mode, keepalive, 총 턴 수, 선제 실행 수, `created_at`, 그리고 `now` 다. 행에는 `now` 를 뺀 입력(`quiet_facts`)을 싣는다. TUI 는 같은 함수(`Masc.Keeper_status_runtime`, TUI 가 이미 링크한다)에 자기 시각을 넣는다.

같은 이유로 행에는 나이(`*_age_seconds`, "몇 초 전")를 싣지 않는다. 시각만 싣는다.

### 3.3 깨움

허브는 키퍼 이름 하나로 깨운다(`wake : keeper:string -> unit`, 허브 자기 락만 잡는다). 깨면 그 키퍼 행만 다시 만들어 이전 값과 비교하고, 다르면 `Row_changed` 를 낸다. 깨움이 여러 번 와도 값이 같으면 이벤트는 0건이다.

깨움은 값을 쓰는 함수 안에서 쓰기가 끝난 뒤 부른다(RFC-0480 §3.4). §1.3 의 표에서 지금 observer 만 있거나 아무것도 없는 곳마다 깨움을 더한다.

- Owner meta 전이, 턴 자리, chat control token: Owner observer 가 키퍼 이름을 넘기게 바꾸고, 그 observer 에서 깨운다.
- 실패 이유, 목록 변화: registry observer 에서 깨운다. 목록에서 빠지면 `Row_removed` 다.
- meta·TOML 쓰기(runtime id, sandbox profile, identity): 쓰는 함수에서 깨운다. 디스크에 키퍼 파일만 생기는 경우(운영자가 파일을 직접 만듦)는 허브가 알 수 없다. 이 경우는 L8 의 파일 변경 감시가 같은 깨움을 부른다.
- 실행 영수증: 영수증을 쓰는 함수에서 깨운다.
- 초상: Candle 장비가 바뀌는 쓰기에서 깨운다. 쓰는 곳은 L2 에서 찾는다(확인하지 못했다).

행을 만드는 함수는 지금 roster 의 행 함수(`keeper_tool_surface_ops.ml:318~444`)와 turns 의 턴 자리 부분을 타입 있는 값으로 내게 바꾼 것이다. JSON 을 만들고 다시 읽는 변환(RFC-0477 §3.3 의 `Fleet_stream_health_section`)은 만들지 않는다. 행 함수는 이미 키퍼 하나씩 만들기 때문이다.

### 3.4 미리보기

미리보기는 키퍼마다 마지막 값 하나만 허브가 든다. `Keeper_turn_preview.change_entry` 가 값을 바꾸면 허브에 그 키퍼의 새 값을 넣는다. 허브는 키퍼마다 마지막으로 보낸 뒤 `preview_post_interval_s` 가 지나지 않았으면 기다렸다가 그때의 마지막 값만 보낸다. 중간 값은 버린다. 턴이 끝나 미리보기가 없어지면 `Preview_cleared` 를 바로 보낸다.

이 간격은 Execute 출력 스트림의 `keeper_execute_stream_post_interval_s`(0.05초, `bin/masc_tui.ml`)와 같은 성격이다. 화면이 그리는 빈도를 정하는 값이지 데이터를 버리는 cap 이 아니다. 미리보기는 "지금 무엇을 하는 중인가"만 보여 주고, 중간 값은 기록으로 남지 않는다. 기록은 채팅 기록과 턴 스트림이 따로 갖는다. 값은 §6 의 결정 1 이다.

채팅 화면이 펼친 준비 단계 목록(`preparation_details_for`)은 미리보기에 싣지 않는다. 그 화면이 열려 있는 동안 그 키퍼 하나만 RFC-0480 방법 1 로 읽는다.

### 3.5 대기 목록과 Candle 은 알림 → 다시 읽기로 둔다

- **대기 목록.** 이미 `keeper_waiting_inventory_changed` 가 있다(`lib/keeper/keeper_waiting_inventory_broadcast.ml:31~45`). 빠진 곳은 일정과 확인 대기 두 곳이다. 그 쓰기에서 같은 알림을 보낸다. 읽는 경로는 turns 다. 행 주제가 들어가면 turns 는 대기 목록만 읽는 경로가 되므로, 응답에서 턴 자리와 미리보기를 뺀다.
- **Candle 잔액과 계정 revision.** Items 탭만 쓴다. 그 탭이 열릴 때와 Candle 원장 쓰기 알림이 올 때 읽는다. 원장 쓰기 알림은 지금 없다(`lib/candle`·`lib/candle_config`·`lib/candle_runtime`·`lib/candle_store` 에 `Sse.` 호출이 없다). 시각으로 바뀌는 잔액은 화면이 읽은 시각을 함께 보인다.

### 3.6 TUI

- fleet 스트림 job(`launch_fleet_stream`)과 순수 클라이언트(`Masc_tui_fleet_stream`)에 행과 미리보기를 더한다. 번호 건너뜀, 다른 `schema`, 읽을 수 없는 프레임은 지금처럼 연결을 다시 연다.
- `keeper_roster` 와 `keeper_turns` 상태는 스트림이 채운다. 2초 묶음의 roster 읽기와 `launch_tick_side_reads` 의 turns 읽기를 지운다. `needs_keeper_roster` 도 지운다.
- 스트림이 끊긴 동안 HTTP 로 읽는 길을 두지 않는다(hard cut, RFC-0477 §3.5). 화면은 마지막 행을 그리고 끊긴 시각을 보인다.
- TUI 시험은 상태 전이만 본다. 화면 문구 시험은 만들지 않는다.

## 4. 규모

- 행 하나는 지금 roster 행보다 작다(초상과 Candle 을 빼면). 정확한 크기는 L1 의 코덱 시험에서 잰다.
- 키퍼 300명의 첫 상태는 행 300개다. 40명 roster 9 KB 에서 선형이면 약 68 KB 다. 연결할 때 한 번이다.
- 행 이벤트 빈도는 깨움 수가 아니라 값이 바뀐 수다. 2026-11-02 측정에서 `keeper_composite_changed` 는 전체 초당 0.40건, 키퍼 하나 최대 0.20건이었다. 행 이벤트는 이보다 많지 않을 것으로 본다(확인 필요, L3 에서 잰다).
- 미리보기 이벤트는 도는 키퍼 수 ÷ `preview_post_interval_s` 를 넘지 않는다.

## 5. 작업 나눔

스택 PR 로 올린다. 각 층은 20k token 안쪽이다.

| 층 | 내용 | 확인 |
|---|---|---|
| L0 | 이 RFC | 리뷰 |
| L1 | 행·미리보기 타입과 코덱(`lib/fleet_stream`) | 코덱 시험(모르는 필드, 빠진 필드, 이름 중복) |
| L2a | 행을 타입 있는 값으로 만드는 함수. roster 와 turns 가 이 함수의 결과를 JSON 으로 내게 바꾼다 | 바꾸기 전후 응답이 같은지 |
| L2b | `quiet_facts` 와 받는 쪽 계산(§3.2) | 같은 입력·시각에서 서버와 같은 값 |
| L2c~ | §3.3 의 깨움. 쓰기 종류 하나가 층 하나다 | 쓰기마다 깨움이 한 번 나가는지 |
| L3 | 허브의 행 주제와 미리보기 주제, SSE 연결 | 허브 시험, loopback 시험, 라이브에서 초당 행 이벤트 수 |
| L4 | TUI 구독, roster·turns 읽기와 `needs_keeper_roster` 삭제 | 상태 전이 시험, 화면 증거 |
| L5 | 대기 목록 빈 곳 알림, turns 응답 축소, Candle Items 탭 읽기(§3.5) | 알림 하나 → 읽기 하나 |

L2c~ 가 다 들어가기 전에는 L4 를 넣지 않는다. 깨움이 빠진 필드는 L4 뒤에 멈추기 때문이다.

## 6. 트레이드오프와 한계

- 깨움을 빠뜨린 쓰기가 있으면 그 필드가 멈춘다. 지금은 2초 읽기가 가린다. L2c~ 에서 쓰는 곳을 전수로 확인해도 앞으로 새 쓰기가 깨움 없이 들어올 수 있다. 행 함수의 입력 저장소마다 깨움을 쓰기 함수 안에 두는 것으로 막고, 호출부에 두지 않는다.
- 운영자가 디스크에서 키퍼 파일을 직접 고치면 L8 의 파일 감시 전까지 행이 바뀌지 않는다.
- 미리보기는 간격 사이의 중간 값을 보이지 않는다.
- 서버와 TUI 빌드가 다르면 `schema` 가 달라서 키퍼 목록 전체를 못 그린다. 지금처럼 일부 필드만 못 읽고 넘어가는 동작은 없어진다(RFC-0477 §7 과 같다).
- 서버가 행 300개를 메모리에 든다. 지금 roster 캐시와 비슷한 크기다.

## 7. 결정이 필요한 것

1. `preview_post_interval_s` 값. 추천은 0.25초다. 답변 중 배지는 초 단위 경과 시간과 한 줄 상태를 보이고, 사람이 그 줄을 읽는 빈도보다 빠를 필요가 없다. Execute 출력처럼 0.05초로 맞추면 도는 키퍼 10명에서 초당 최대 200건이다.
2. 대기 목록을 이 RFC 처럼 행 주제에 넣을지, §3.5 처럼 알림 → 다시 읽기로 둘지. 추천은 다시 읽기다. 대기 목록은 다섯 저장소를 읽어 만들고, 그 다섯 쓰기에 깨움을 모두 더하는 일이 행보다 크다.
