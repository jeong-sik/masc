---
rfc: "exact-lane-waits-for-a-stated-reset"
title: "exact lane 은 provider 가 말한 시각 전에는 그 slot 을 부르지 않는다"
status: Draft
created: 2026-11-09
updated: 2026-11-10
author: claude
supersedes: []
superseded_by: null
related: ["provider-path-rest", "0433", "0370", "exact-lane-walks-one-slot-list", "0449"]
---

# exact lane 은 provider 가 말한 시각 전에는 그 slot 을 부르지 않는다

## 0. 요약

2026-11-09 09:25Z~10:51Z 에 Candle 채점이 Goal 하나의 같은 요청을 85번 보냈다.
모두 같은 Claude Code 계정이었고, 모두 거절됐다.
첫 거절이 이미 풀리는 시각을 말했다(2026-11-10T00:00Z).
masc 는 그 시각을 기록했다. 그런데 exact lane 은 그 기록으로 순서만 바꾼다.
slot 이 하나뿐이면 순서를 바꿔도 같은 slot 을 부른다.

규칙은 하나다. **exact lane 은 provider 가 말한 시각이 지나기 전에는 그 slot 을 부르지 않는다.**

- 말한 시각은 둘이다. slot 의 quota scope 에 적힌 리셋 시각과, 그 slot 이 받은 Retry-After 다.
- masc 가 정한 쉼은 지금처럼 순서만 바꾼다. 시각 없는 고갈 관측(RFC-0433)과 Retry-After 없는 rate limit 이 여기에 든다.
- 기다리는 slot 은 목록에 남는다. 시각이 지나면 다음 실행이 다시 부른다. 요청은 최종 결과 없이 남는다.
- 부를 slot 이 하나도 없으면 호출 없이 typed 결과로 끝낸다.
- 호출처는 기다리는 slot 을 「불렀다가 자기 계정 사정으로 거절된 slot」과 똑같이 다룬다. 호출만 없다. 모두 기다릴 때도, 일부만 기다릴 때도 같다.
- 기다림은 그 시각이 지나거나 서버가 다시 시작할 때 끝난다. 성공 한 번으로는 끝나지 않는다. Keeper walk 가 같은 기록으로 기다리는 방식과 같다(1.3).

이 RFC 는 #41490 의 세 질문에 답한다.
#39190 의 운영자 질문(「라우팅이 provider 가 알려 준 리셋 시각을 써도 되는가」)에는 exact lane 에 한해 「쓴다」로 답한다.
이 답은 저장소 주인이 이 RFC 를 병합할 때 정해진다.
RFC-provider-path-rest §6 이 미룬 Phase 2 중 exact lane 부분이 이 문서다.
Keeper turn walk 는 바꾸지 않는다.

## 1. 지금 동작

### 1.1 실측 (2026-11-09)

출처는 `<base-path>/.masc/logs/system_log_2026-11-09.jsonl` 과 Claude Code session 파일의 집계다.

- Goal 하나의 Candle 채점 요청을 09:25Z~10:51Z 에 85번 보냈다. 간격 중앙값은 60초다.
- 모두 Claude Code one-shot 이고 같은 계정이다.
- 모두 `Quota_blocked` 로 거절됐다. `Quota_spent`, 창 `seven_day`, `resets_at` 2026-11-10T00:00Z, api_status 429 다.
- 리셋까지 두면 약 790번을 더 보낸다(10:51Z~00:00Z, 분당 1번).
- #41490 은 같은 결함을 Librarian `librarian_exact` 에서 기록했다. 2026-10-05~06 Ollama Cloud 거절 2,185건 중 254건이 이 lane 이었다.

### 1.2 같은 요청이 매분 다시 나가는 길 (main `f2a6f2d7`)

1. maintenance loop 가 60초마다 `Candle_payout_worker.pulse` 를 부른다(`server_bootstrap_maintenance.ml:14`, `:790-794`).
2. 지난 결과가 `Retry_later` 인 owner 는 다시 뜰 수 있다(`candle_payout_worker.ml:49`).
3. 채점기는 보관된 요청의 상태를 읽는다(`server_candle_appraiser.ml:107`). 결과가 아직 없으면(`Pending`) `Transport_unavailable` 이 되고(`:160`), 다시 `Retry_later` 가 된다.
4. 이 읽기는 Lane Add-on 의 export tool 호출이다(`server_candle_appraiser.ml:191`). tool 이 답하면 그 instance 의 host cycle 이 깬다(`lane_addon_runtime.ml:2429`). host cycle 은 최종 결과가 없는 요청을 다시 실행한다(`lane_addon_runtime.ml:1184`, `lane_addon_exact.ml:938`).
5. provider 거절은 최종 결과가 아니라 `Deferred` 로 남는다(`lane_addon_exact.ml:953`). 그래서 다음 읽기가 다시 실행을 부른다. 서버 로그에서 `appraisal pending` 1~2초 뒤에 `Claude Code turn starting` 이 오는 것이 이 순서다.
6. 실행은 slot 을 정렬해서 걷는다. HTTP slot 은 `Runtime_exact_lane_backpressure.order`(`runtime_exact_lane_backpressure.ml:20-42`), CLI slot 은 `Keeper_lane_cli_oneshot.order_slots`(`keeper_lane_cli_oneshot.ml:418-434`)가 정렬한다. vision tool 도 같은 정렬을 쓴다(`keeper_vision_tool.ml:63-72`). 셋 다 `Runtime_candidate_standing.order` 의 `Rate_rest_only` 다.
7. 이 정렬은 쉬는 후보를 뒤로 보낼 뿐 빼지 않는다(`runtime_candidate_standing.ml:16-51`). slot 이 하나면 늘 그 slot 을 부른다.
8. 거절은 provider 가 말한 리셋과 함께 적힌다. `Quota_spent { resets_at }` 가 `Hard_quota { resets_at }` 가 되고(`fusion_official_client.ml:604-610`), scope 의 `Until` 로 남는다(`runtime_candidate_standing.ml:64-67`).

### 1.3 이미 정해진 것

- RFC-0433 은 고갈은 말하지만 끝나는 때는 말하지 않는 provider 를 다뤘다. 「한도가 리셋되면 그것을 알아내는 방법은 하나뿐이다 — 불러보는 것」(RFC-0433:99). 그래서 「후보를 배제하지 않는다」(:172). 이 이유는 provider 가 시각을 말하지 않았을 때만 맞는다.
- RFC-exact-lane-walks-one-slot-list §3.5 는 「어느 슬롯도 목록에서 지우지 않는다. 쉬는 슬롯도 차례가 오면 부른다」고 정했다(:179). 근거로 헌법 `no_wall_clock_death` 를 든다(:181).
- `runtime_quota_window.mli:13-16` 과 `runtime_exact_lane_backpressure.mli:13-15` 도 같은 결정을 적는다. 뒤쪽은 근거로 RFC-0370 §3.3 을 든다. 그런데 RFC-0370 §3.3 본문은 반대다. 「소진된 창의 runtime은 후보 목록에 이름이 오르지 않고, `resets_at` 경과로 자연 복귀」(RFC-0370:160-165).
- RFC-provider-path-rest §6 은 「walk 가 쉬는 후보를 건너뛰고, 모두 쉬면 호출 없이 "모든 경로가 쉼" 을 typed terminal 로 끝내게 한다」를 Phase 2 로 미뤘다(:356-358). RFC-0433 과 부딪힌다는 이유였다.
- Keeper turn walk 는 이미 provider 가 말한 시각까지 기다린다. 쉬는 경로는 그 시각까지 뒤로 가고, 맨 앞 경로가 쉬면 걷기를 가장 이른 시각까지 미룬다(`keeper_turn_driver.ml:416-421`, `:491-494`). 성공은 말한 리셋 기록을 지우지 않는다(`runtime_quota_window.ml:80-88`). 말한 시각을 순서로만 읽는 것은 exact lane 뿐이다.

## 2. 왜 기존 원칙과 부딪히지 않나

- **`no_wall_clock_death`**(헌법 203-209)는 시간이 지났다는 이유로 상태를 죽이지 말라는 원칙이다. 이 RFC 는 아무것도 죽이지 않는다. 요청은 남고, slot 도 목록에 남는다. 바뀌는 것은 부르는 때다.
- **RFC-0433 의 안전선**은 「표시가 배제로 바뀌면 provider 하나의 일시적 장애가 레인을 통째로 죽인다」이다(RFC-0433 §7). 이 RFC 는 시각 없는 표시를 건드리지 않는다. 시각이 정해진 쉼만 다룬다. 그 쉼은 정해진 시각에 끝난다.
- **budget_gate**(헌법 460-465)는 provider 의 hard limit 을 금지 대상에서 뺀다.
- **게이트 정책**(헌법 499-504)은 하드 게이팅을 기본으로 두지 않는다. 실익이 크고 기능이 더 잘 돌고 연속성이 생길 때만 고려하고, 게이트 추가는 success_bar 를 모두 넘은 뒤로 미룬다.
  - 이 규칙은 새 종류의 게이트가 아니다. Keeper walk(1.3)와 verifier(헌법 104-107)가 이미 같은 기록으로 같은 시각까지 기다린다. exact lane 만 그 시각을 순서로 읽었다.
  - 실익: 그 시각 전 호출은 provider 가 거절한다고 이미 말했다. 11-09 에는 85번 중 85번이 거절이었다.
  - 연속성: 요청은 남고, 시각이 지나면 다시 걷는다. 시각 전의 실행은 그 사이 다른 slot 을 먼저 쓴다.
  - 드문 경우가 아니다. 한도를 다 쓴 계정의 exact lane 은 모두 이 길을 탄다.
  - 근거로 비용은 들지 않는다(헌법 `<cost>`).
- **헌법 104-107** 은 verifier 가 「거절한 slot 의 provider 가 다시 받는 시각을 밝혔으면 — rate limit, hard quota reset, 403 뒤 사용량 창 — 그 시각까지만 더 기다린다」고 정했다. exact lane 이 같은 규칙을 따른다.
- **#39190 triage**(2026-09-30)는 typed scope, 관측 시각, 창의 뜻, 실패의 귀속을 확인하라고 했다. 화면 usage 를 라우팅 권한으로 쓰지 말고, 낡은 `resets_at` 으로 자동 차단하지 말라고 했다. 3.2 와 3.5 가 답한다.

## 3. 바꾸는 것

### 3.1 규칙

- **R1.** exact lane 은 기다리는 slot 을 그 시각 전에 부르지 않는다. 시각은 아래 둘 중 늦은 것이다.
  - slot 의 quota scope 에 provider 가 말한 리셋: `Runtime_quota_window.rest ~scope ~now = Some (Reset_stated t)`.
  - slot 이 받은 Retry-After: candidate 칸의 `Unknown_scope_rate_limit { noted_at; retry_after = Some s }` 에서 `Keeper_runtime_failure_route.usable_retry_after` 를 통과한 `s` 로 `noted_at +. s`.
- **R2.** masc 가 정한 쉼은 순서만 바꾼다. `Observed_until`(시각 없는 고갈)과 Retry-After 없는 rate limit 의 floor 가 여기에 든다. exact lane 은 실패한 시도 기록을 지금도 순서에 쓰지 않는다(`runtime_candidate_standing.ml:35`). 그대로 둔다.
- **R3.** 기다리는 slot 은 목록에서 지우지 않는다. 시각이 지나면 다음 실행이 부른다. 깨우는 장치를 새로 만들지 않는다. 호출처마다 이미 있는 trigger 가 다시 판단한다(maintenance pulse, host event, librarian pass, Keeper 의 tool 호출).
- **R4.** 부를 수 있는 slot 이 없으면 호출 없이 끝낸다. 결과에는 기다리는 slot 과 그 시각을 싣는다.
- **R5.** 호출처는 기다리는 slot 을 「불렀다가 자기 계정 사정으로 거절된 slot」과 똑같이 다룬다. 호출만 없다. 모두 기다릴 때도, 일부만 기다릴 때도 같다. 그래서 호출처마다 이미 있는 「쉼」 처리를 그대로 쓴다(3.4).
- **R6.** 기다림은 그 시각이 지나거나 프로세스가 다시 시작할 때 끝난다. 같은 scope 의 성공은 말한 리셋 기록을 지우지 않는다(`runtime_quota_window.ml:80-88`, 지금 규칙). 성공으로 지우는 안은 5장에서 고르지 않았다.

### 3.2 무엇이 「provider 가 말한 시각」인가

`Runtime_quota_window` 의 `Until` 은 `note_exhausted` 만 쓴다. 부르는 곳은 모두 provider 의 답에서 시각을 읽는다.

| 출처 | 기록 | 이 RFC |
|---|---|---|
| Claude Code 거절 `Quota_spent { resets_at = Some _ }` | scope `Until` (`fusion_official_client.ml:609-610`) | 기다린다 |
| HTTP 402 와 쓸 수 있는 retry hint | scope `Until` (`runtime_candidate_standing.ml:69-80`) | 기다린다 |
| Muse 거절의 quota `resets_at_ms` | scope `Until` (`runtime_muse_usage.ml:10-12`) | 기다린다 |
| Lane Add-on sampling 의 hard quota retry hint | scope `Until` (`server_lane_addon_sampling.ml:59-64`) | 기다린다 |
| 계정 거절 뒤 사용량 읽기 `Spent_until t` (#41489, Ollama `/api/balance` 포함) | scope `Until` (`runtime_provider_usage_read.ml:574-598`) | 기다린다 |
| 주기적 사용량 읽기의 완전한 보고에서 모델 호출 창 소진 | scope `Until` (`runtime_provider_usage_window.ml:950-957`, `runtime_provider_usage_read.mli:92-100`) | 기다린다 |
| HTTP 429 와 Retry-After | candidate `retry_after = Some s` | `noted_at + s` 까지 기다린다 |
| 시각 없는 고갈(`note_observed_exhausted`, `note_read_without_reset`) | scope `Observed` | 순서만 |
| Retry-After 없는 429, Claude `Rate_throttled`, Codex rate 거절 | candidate `retry_after = None` | 순서만 |
| Codex 사용량 읽기(거절한 `limit_id` 를 모름) | 쉼으로 적지 않음 (`runtime_provider_usage_read.ml:611-623`) | 그대로 |

#39190 triage 의 조건은 기록하는 쪽이 이미 지킨다.

- scope 는 typed 다(`Runtime_quota_window.scope`).
- 관측 시각보다 이른 리셋은 쉼이 아니다. 거절 뒤 읽기는 그것을 시각 없는 소진으로 바꾼다(`runtime_provider_usage_read.ml:567-599`). 보고 표는 자기 리셋 뒤에 소진으로 본 창을 「끝을 믿을 수 없음」으로 읽는다(`runtime_provider_usage_window.ml:899-912`).
- 창의 뜻은 `gates_model_calls` 와 출처별 `gate_coverage` 가 정한다(`runtime_provider_usage_window.ml:886-891`).
- 귀속이 없는 보고(Codex)는 쉼으로 적지 않는다.
- 라우팅은 지금처럼 `Runtime_quota_window` 만 읽는다. 화면 표(`Runtime_provider_usage_window`)는 읽지 않는다.

### 3.3 모양

**공유 판정 하나.** `Runtime_candidate_standing` 에 exact lane 용 정렬을 둔다.

```ocaml
type 'a exact_order =
  { walk : 'a list
      (** 지금 부를 수 있는 slot. 쉬지 않는 slot 이 적힌 순서대로 먼저,
          masc 가 정한 쉼이 있는 slot 이 적힌 순서대로 뒤에 온다. *)
  ; held : ('a * float) list
      (** provider 가 말한 시각까지 기다리는 slot 과 그 시각. 적힌 순서. *)
  }

val order_exact :
  now:float ->
  quota_scope_of:('a -> Runtime_quota_window.scope option) ->
  candidate_backpressure_of:('a -> Runtime_candidate_backpressure.candidate option) ->
  'a list ->
  'a exact_order
```

- `policy` 의 `Rate_rest_only` 는 지운다(hard cut). 세 호출처가 같은 `rest_sec` 클로저를 각자 복사해 두었다(`runtime_exact_lane_backpressure.ml:21-26`, `keeper_lane_cli_oneshot.ml:420-425`, `keeper_vision_tool.ml:68-72`). 그 계산은 `order_exact` 안으로 들어간다.
- `Keeper_walk` 와 `order` 는 바꾸지 않는다.
- scope 를 모르는 slot 은 기다리지 않는다. 모르는 id 는 고갈의 증거가 아니다(`runtime_quota_window.mli:109-110` 과 같은 규칙).

**HTTP.** `Runtime_exact_lane_backpressure.order` 는 정렬한 lane 과 기다리는 HTTP slot 을 같이 돌려준다.

```ocaml
type held_slot = { slot_id : string; until : float }

type ordered =
  { lane : Runtime_exact_output_registry.resolved_lane  (** [selected_slots] 는 [walk] *)
  ; held_http : held_slot list
  }

val order : Runtime_exact_output_registry.resolved_lane -> ordered
```

부르는 곳 넷(`server_lane_addon_exact.ml:180`, `keeper_board_attention_exact_flow.ml:203`, `hitl_summary_flow_prepare.ml:115`, `keeper_librarian_runtime.ml:691`)이 모두 `held_http` 를 받는다.

**CLI.** `order_slots` 는 `string exact_order` 를 돌려준다. `walk` 는 지금처럼 slot 하나를 마칠 때마다 다시 정렬한다(`keeper_lane_cli_oneshot.ml:436-451`). 그래서 HTTP 가 도는 사이에 기다리게 된 CLI slot 도 부르기 직전에 걸러진다. 기다리는 slot 마다 실패를 하나 적고 부르지 않는다.

```ocaml
type failure =
  | ...
  | Held of { runtime_id : string; until : float }
      (** provider 가 말한 시각 전이라 부르지 않았다. *)
```

`refused_for_binding_rest (Held _)` 는 `true` 다. 그래서 CLI 걸음의 쉼 판정은 기다리는 slot 을 쉼으로 거절된 slot 과 같이 센다. CLI 실패를 갈래별로 다루는 곳은 lib 다섯 파일과 `bin/masc_lane_cli_probe.ml` 이다. 모두 `_ ->` 없이 새 갈래를 적는다.

walk receipt 의 원인 타입(`cli_cause`, `keeper_exact_walk_failure.ml:215`)에는 `Held of { until : float }` 갈래가 생긴다.

- `Held` 원인의 관찰은 `cli_was_dispatched` 가 `false` 다(`:285`). receipt 는 부른 slot 을 이 함수로 고른다(`keeper_exact_walk_receipt.ml:292`). 그래서 기다린 slot 은 부른 slot 에 들지 않는다.
- 실패 증거로는 크기와 무관한 실행 실패다(`size_independent`, `keeper_exact_walk_failure.ml:70`). 불렀다가 거절된 CLI slot 의 증거(`:303-305`)에서 `unsettled_native_execution` 만 뺀 값이다. 보낸 것이 없으니 정산할 실행도 없다. 입력 크기 증거를 만들지 않으므로, 이 slot 때문에 입력을 줄이거나 나누지 않는다.

**Lane Add-on.** `lane_unavailable` 에 갈래를 하나 더한다.

```ocaml
type lane_unavailable =
  | ...
  | Every_slot_held of { until : float }
      (** 모든 slot 이 provider 가 말한 시각까지 기다린다. 가장 이른 시각. *)
```

이 타입의 뜻은 「Nothing was sent」다(`lane_addon_exact.mli:128`). runner 는 HTTP slot 과 CLI slot 이 모두 기다리면 `call` 을 만들지 않고 이 값을 돌려준다(`server_lane_addon_exact.ml:254-258`). 그러면 host 는 `Started` 를 적지 않고 `Deferred (Lane_unavailable _)` 를 적는다(`lane_addon_exact.ml:938-942`).

일부만 기다리면 `call` 을 만든다. 기다리는 slot 은 R5 대로 다룬다.

- 기다리는 HTTP slot 마다 실패를 `Failure.Transient` 로 적는다. 불렀다가 rate limit 으로 거절된 slot 과 같은 값이다(`exact_lane_failure.ml:22-24`).
- 적지 않으면 결과가 달라진다. `ending` 은 다시 지나갈 수 있는 거절이 하나도 없을 때만 입력 거절로 요청을 닫는다(`server_lane_addon_exact.ml:15-17`, `:25-28`). 기다리는 slot 을 빼면, 부른 slot 의 입력 거절이 요청을 최종으로 닫는다.
- 기다리는 CLI slot 은 `Held` 로 온다. `Exact_lane_failure.cli_failure` 는 이것을 `Transient` 로 읽는다.
- receipt 의 `declared_http` 는 걸은 slot 뒤에 기다리는 slot 을 붙인 목록이다. `excluded_http` 는 기다리는 slot 이다. 그 필드는 preflight 제외를 담는 자리이고(`keeper_exact_walk_receipt.mli:39-44`), 지금 Lane Add-on 은 늘 `[]` 를 적는다(`server_lane_addon_exact.ml:202`).
- receipt 검사는 순서까지 본다. `declared_http` 에서 `excluded_http` 를 뺀 목록이 flow 가 걸은 후보와 같아야 받는다(`keeper_exact_walk_receipt.ml:192-196`). 어긋나면 runner 가 `invalid_arg` 로 멈춘다(`server_lane_addon_exact.ml:204`). 그래서 걸은 slot 이 앞에 온다.
- `excluded_http` 가 비지 않으면 receipt 는 「모든 slot 이 입력을 거절했다」고 결론 내지 않는다(`keeper_exact_walk_receipt.ml:172-181`). 기다린 slot 은 입력을 받지 않았으므로 맞는 결론이다.

새 `not_final` 값은 host 화면에도 나간다. JSON codec(`lane_addon_exact.ml` 의 `not_final_to_json`·`not_final_of_json`), health 표면의 코드(`keeper_memory_execution_availability.ml:103-112`), TUI(`bin/masc_tui_lane_addons.ml`), dashboard(`dashboard/src/api/lane-addon-host-requests.ts`, `dashboard/src/components/lane-addon-host-requests.ts`)를 같이 고친다.

### 3.4 호출처별 처리

| 호출처 | 모두 기다릴 때 | 일부만 기다릴 때 |
|---|---|---|
| Lane Add-on (Candle) | runner 가 `Every_slot_held` 를 돌려준다. host 는 `Started` 없이 `Deferred` 를 적고 다음 event 를 기다린다. Candle 은 다음 pulse 에 다시 읽고, 시각 전에는 provider 를 부르지 않는다 | 남은 slot 을 걷는다. 기다리는 slot 은 `Transient` 실패로 적힌다(3.3). 그래서 부른 slot 이 입력을 거절해도 요청은 `Deferred` 로 남는다 |
| Board attention | HTTP slot 만 있으면 지금은 준비 단계 오류 `Lane_resolved_without_slots` 가 된다(`keeper_board_attention_exact_flow.ml:213`). 준비 단계 오류는 worker 를 멈춘다(`keeper_board_attention_worker.ml:1276-1289`, `:2322`). 그래서 「모두 기다림」은 준비의 Ok 쪽 결과로 받는다. 실행은 HTTP lane 처럼 Jev 에 먼저 묻는다(`keeper_board_attention_exact_flow.ml:588`, `:608`). Jev 가 정하지 않으면 부르지 않고 `Lane_resting` 으로 끝낸다. 그 뒤는 지금 길이다. `Execution_deferred`(`keeper_board_attention_worker_disposition.ml:204-205`)가 `Lane_deferred` 가 되고, maintenance pulse 가 다시 깨운다(`keeper_board_attention_worker.ml:489-491`, `:2305`). CLI slot 이 있으면 `Held` 가 `refused_for_binding_rest` 라서 지금 규칙대로 `Lane_resting` 이 된다. 격리하지 않는다 | 지금 규칙 그대로. 기다리는 slot 은 쉼으로 거절된 slot 으로 센다(`keeper_board_attention_worker_disposition.ml:196-203`) |
| HITL 요약 | 지금처럼 entry 를 실행 실패로 정산한다. 지금 CLI slot 이 모두 쉼으로 거절하면 entry 는 마지막 CLI identity 로 격리된다(`Cli_settled`, `hitl_summary_cli_walk.mli:15-17`). 기다리는 slot 은 부르지 않으니 그 identity 가 묶이지 않는다. 그래서 CLI 걸음이 끝에서 직접 정산하고 `Cli_settled` 를 돌려준다. 앞 HTTP slot 의 바인딩이 남아 있으면 그 바인딩을, 아무것도 묶이지 않았으면 기다리는 slot 의 identity 를 묶어 `Exact_flow_execution_failed` 로 격리한다. 묶이지 않은 entry 를 그대로 정산하면 안 된다. `settle_current` 는 identity 없는 entry 를 정산하지 않고 「identity unbound」로 멈춘다(`hitl_summary_exact_settlement.ml:161-167`). 이 상태는 blocked 로 남아 운영자 복구를 기다리고(`keeper_approval_queue_rules_types.ml:154-157`), owner drain 도 하지 않는다(`keeper_gate_auto_judge_worker.ml:106-110`). 묶는 identity 는 `held-hitl-` call id 와 `held:` plan fingerprint 를 달아 dispatch 한 identity 와 구별한다. `Cli_fell_back` 은 쓰지 않는다. 그 뜻이 「바인딩 저장 실패」라서(`hitl_summary_cli_walk.mli:18-21`) 로그가 틀린다. HTTP 만 있는 lane 은 지금 준비 오류 「no usable candidates」가 된다(`hitl_summary_flow_prepare.ml:73`). 준비 오류는 실행 전에 그대로 돌아간다(`hitl_summary_worker.ml:322-323`). 그래서 「모두 기다림」은 준비의 Ok 쪽 결과로 받고, worker 가 같은 방법으로 기다리는 slot 의 identity 를 묶어 정산한다. 정산을 미루지 않는다. 미룬 entry 를 시각에 깨울 trigger 가 없다(R3) | 지금 규칙 그대로. HTTP 가 모두 기다리고 CLI slot 이 있으면 지금처럼 `Cli_only` 가 된다(`hitl_summary_flow_prepare.ml:118-119`) |
| Librarian | CLI 걸음은 `Held` 를 담은 `Slot_failures` 를 돌려주고 `Cli_slots_exhausted` 가 된다(`keeper_librarian_runtime.ml:1125`, `:1165-1166`). HTTP 만 있고 모두 기다리면 지금은 `No_cli_slots` 가 `No_transport_declared`(설정 실패)로 읽힌다(`:1164`, `:109`). 「모두 기다림」은 실행 실패 갈래로 따로 돌려준다. 기다리는 HTTP slot 은 receipt 의 `excluded_http` 에 넣고, 크기와 무관한 실패 증거로 센다. 그래서 줄이거나 나누거나 확정하지 않는다. 읽은 위치는 그대로다 | 같다. 기다리는 slot 이 하나라도 있으면 크기와 무관한 실패 증거가 남는다. 부른 slot 이 모두 크기로 거절해도 입력을 나누지 않는다(`keeper_exact_walk_failure.mli:41-46`) |
| vision tool | 「모든 image runtime 이 시각 t 까지 기다림」을 typed 결과로 돌려준다. 기다리는 runtime 을 걸음에서 빼기만 하면 세 곳이 다른 말을 한다. 기다리는 runtime 만 있으면 `Vo_no_runtime`(`keeper_vision_tool.ml:678`), 이번 turn 에 제외된 runtime 과 기다리는 runtime 만 남으면 「already attempted」(`:943-948`), 기다리는 runtime 을 `runtime_id` 로 고르면 「not a configured capable image candidate」(`:953-956`)다. 셋 다 기다림 결과로 바꾼다 | 기다리지 않는 runtime 을 쓴다. 그 runtime 이 모두 실패하고 넘어가면 기다림 결과로 끝난다. 걸음의 결과는 마지막 후보의 것이고(`keeper_vision_tool.ml:673-676`), 기다리는 runtime 은 그 마지막 자리에서 쉼으로 거절된 runtime 이다(R5) |

일부만 기다릴 때의 결과는, 기다리는 slot 을 불렀고 그 slot 이 쉼으로 거절했을 때의 결과와 같다. 호출 하나만 없다. 그래서 호출처마다 결과가 다르다.

- Lane Add-on 은 쉼 거절이 하나라도 있으면 요청을 최종으로 닫지 않는다(3.3).
- Board attention 은 부른 slot 이 쉼이 아닌 이유로 실패하면, 쉼 거절이 있어도 격리한다(`keeper_board_attention_worker_disposition.ml:196-203`).

이 RFC 는 어느 쪽도 바꾸지 않는다.

이 처분은 Ledger 의 새 Gate 가 아니다. 호출처마다 이미 있는 「쉼」 처분을 다시 쓴다. Ledger 에 새 상태를 쓰지 않는다.

### 3.5 재시작·시계·낡은 기록

- **재시작.** 두 표는 프로세스 메모리에 있다(`runtime_quota_window.mli:9-11`, `runtime_candidate_backpressure.mli:1-10`). 재시작하면 잊는다. 직접 읽기를 지원하는 계정은 서버 시작 때 읽기로 다시 배운다(glossary 「Provider Usage Window」의 「직접 읽기」). Claude Code 처럼 턴 중에만 보고하는 계정은 첫 호출이 다시 거절되며 시각을 다시 배운다. 저장하지 않는다. 잊어도 durable truth 가 다치지 않는다. 요청은 남아 있고, 잃는 것은 거절된 호출 하나다.
- **slot 마다 다른 시각.** slot 은 자기 시각을 쓴다. 모두 기다리면 결과의 `until` 은 가장 이른 시각이다. 일부만 기다리면 나머지를 부른다.
- **Keeper 와 exact lane 이 scope 를 같이 쓸 때.** 같은 표를 읽는다. 어느 쪽의 성공도 리셋 기록을 지우지 않는다(R6). 그래서 두 쪽이 같은 시각에 기다림을 끝낸다.
- **운영자가 한도를 일찍 올렸을 때.** 기록된 시각까지 기다리거나 서버를 다시 시작해야 한다. Keeper walk 가 쉬는 경로를 기다리는 것도 지금 같다(1.3). 사용량 보고의 「여유 있음」은 리셋 기록을 지우지 않는다(`runtime_provider_usage_window.ml:950-952`, 지금 규칙 그대로). 화면에서 푸는 장치는 만들지 않는다.
- **Lane Add-on 기록.** 「모두 기다림」인 실행도 attempt 기록 `Deferred` 를 하나 붙인다(`lane_addon_exact.ml:941`). 기록은 attempts 목록 전체를 한 JSON 으로 쓴다(`:429`). 그래서 기다리는 동안 trigger 마다 기록이 하나씩 는다. main 은 같은 trigger 마다 `Started` 와 `Deferred` 를 붙이므로(`:944`, `:952`), 느는 양은 절반이 된다. 이 RFC 는 기록을 줄이는 Gate 를 더하지 않는다. 늘어나는 기록은 지금도 있는 문제이고 #50762 에서 다룬다.
- **시계.** provider 의 시각과 로컬 벽시계를 비교한다. 로컬 시계가 늦으면 더 기다린다. 빠르면 일찍 불러 거절을 한 번 더 받고, 그 거절이 시각을 다시 적는다. 여유 시간을 짓지 않는다.
- **지난 시각.** 읽을 때 지운다(`runtime_quota_window.ml:92`). `now < t` 일 때만 기다린다. `now = t` 이면 부른다.
- **아주 먼 시각.** 그대로 따른다. 상한을 짓지 않는다(RFC-0433).
- **HTTP 의 틈.** HTTP 는 순서를 한 번 정한 뒤 flow 를 돈다(`server_lane_addon_exact.ml:180`). 그 사이 다른 실행이 같은 slot 에 시각을 적으면, 이번 flow 는 그 slot 을 한 번 부를 수 있다. 다음 실행은 걸러 낸다. 반복되지 않으므로 받아들인다. dispatch 직전에 다시 보려면 `Exact_output` 의 `before_dispatch` 에 새 갈래가 필요하다. 지금 그 `Error` 는 masc 기록 실패라는 뜻이고, 쉼이 아닌 실패로 읽힌다(`exact_output.ml:1214`, `:1127`). CLI 는 slot 마다 다시 정렬하므로 이 틈이 없다.

### 3.6 고치는 문장

L0(이 PR):

- RFC-exact-lane-walks-one-slot-list §3.5 4번(:179)과 LiteLLM 문단(:181), 섞인 목록 예(:189), §3.6(:200), §8(:304). 줄 번호는 이 PR 을 적용한 뒤의 것이다.
- RFC-0433 §6 「후보를 배제하지 않는다」(:172)와 §7 안전선(:186). 시각 없는 표시에 대한 결정이라고 범위를 적는다.
- RFC-provider-path-rest §6(:356-358). exact lane 부분은 이 RFC 가 정한다고 적는다.
- RFC-0370 §3.3(:160-165). exact lane 이 이 문단을 따른다고 적는다. ollama_cloud 에 이제 사용량 읽기(`Ollama_balance_read`, `runtime_provider_usage_window.ml:889`)가 있다고 적는다.
- glossary 「Provider Usage Window」의 「관측 권위」(`00-glossary.md:1656`). 주기적 완전 보고도 쉼을 적는다는 사실과 이 규칙을 더한다.

L1(구현):

- `runtime_quota_window.mli:13-16`, `runtime_exact_lane_backpressure.mli:13-15`, `:20-28`, `runtime_candidate_backpressure.mli:4-6`, `:80-82`.

## 4. 하지 않는 것

- **Keeper turn walk.** 맨 앞 경로가 쉬면 기다리는 지금 동작(1.3)을 그대로 둔다. 쉬는 경로를 걸음에서 빼는 일은 RFC-provider-path-rest §6 Phase 2 의 나머지이고, #39190 의 Keeper 부분이다.
- **성공으로 리셋 기록 지우기** (5장).
- **리셋 기록 저장** (3.5).
- **기다리는 slot 을 깨우는 타이머** (R3).
- **사용량 보고의 「여유 있음」으로 리셋 기록 지우기** (3.5).
- **HTTP flow 의 dispatch 직전 재확인** (3.5).
- **verifier lane.** 이미 헌법 104-107 대로 기다린다.
- **Stagehand.** 이 정렬을 쓰지 않는다.
- **Antigravity 한도를 쉼으로 적기(#39696).** 기록하는 쪽 문제다. 적히면 이 규칙이 따른다.
- **Anthropic API 사용 한도 400.** 사용 한도 초과가 잘못된 요청과 같은 400 `invalid_request_error` 로 온다. 공식 문서는 메시지 문자열로 가르지 말라고 한다. typed 신호가 없으므로 #49686 에서 따로 정한다.

## 5. 고르지 않은 대안

- **호출처마다 확인하기.** 네 호출처와 vision 이 같은 판단을 따로 한다. 한 곳을 빼먹으면 그 lane 만 계속 부른다.
- **거절한 그 slot 만 기다리기.** 모델별 창 문제를 피한다. 그러나 #41490 을 못 고친다. Ollama 는 거절 뒤 사용량 읽기가 시각을 말하고, 그 기록은 scope 에 있다.
- **quota 리셋만 따르고 Retry-After 는 빼기.** 규칙이 둘이 된다. 헌법 104-107 은 둘을 같이 다룬다.
- **기다리는 동안 타이머로 깨우기.** 새 scheduler 상태가 생긴다. 각 호출처의 trigger 로 충분하다.
- **리셋 기록을 디스크에 저장하기.** 3.5.
- **성공이 리셋 기록을 지우기.** 한도가 일찍 풀린 계정을 바로 다시 쓸 수 있다. 이번 실측이면 13시간을 덜 기다린다. 고르지 않은 이유는 셋이다.
  - Muse 는 턴 도중 `usage/changed` 로 리셋을 적고(`runtime_muse_usage.ml:66-70`), 같은 턴이 답하면 성공을 적는다(`fusion_official_client.ml:634`). 성공이 지우면 provider 가 가장 나중에 한 말이 지워진다. 시험도 답한 뒤 이 기록이 남는다고 단언한다(`test_fusion_official_client_panel.ml:896-897`).
  - Keeper walk 가 같은 기록으로 기다린다(1.3). 지우면 Keeper 동작이 바뀐다. 이 RFC 는 Keeper 를 바꾸지 않는다.
  - 성공을 적는 곳이 다섯이다(`fusion_official_client.ml:634`, `runtime_exact_lane_backpressure.ml:82`, `server_lane_addon_sampling.ml:50`, `keeper_turn_driver.ml:939`, `keeper_vision_tool.ml:835`). 어느 성공이 그 scope 의 한도가 풀렸다는 증거인지 곳마다 따져야 한다.

  RFC-0449 §2.6 의 「그 scope 로 어떤 호출이든 성공 → `note_succeeded` → 표시 소멸」은 시각 없는 고갈 관측(§2.5 의 `note_observed_exhausted`)에 대한 문장이다. 지금 `note_succeeded` 도 그 관측만 지운다(`runtime_quota_window.ml:80-88`).

## 6. 검증

회귀 테스트는 L1 에 둔다. 「main 동작」 칸은 고치기 전 동작이다. 단언은 부른 횟수로 쓴다. 그래야 고치기 전 동작에서 실패한다.

| 무엇 | 파일 | main 동작 |
|---|---|---|
| 계정 리셋 기록은 그 계정의 HTTP slot 을 모두 기다리게 한다. 같은 계정의 성공은 풀지 않고, 시각이 지나면 모두 다시 걷는다 | `test_runtime_exact_lane_backpressure.ml` (새 시험) | 모두 걷는다 |
| Retry-After 를 받은 slot 은 시각 전에 기다리고, 시각이 되면 걷는다 | 같은 파일 (:100 을 바꾼다) | 뒤로만 간다 |
| provider hint 가 floor 상한보다 길면 그 hint 까지 기다린다 | 같은 파일 (:122 를 바꾼다) | 뒤로만 간다 |
| 모든 slot 이 Retry-After 를 받았으면 아무것도 걷지 않는다 | 같은 파일 (:139 를 바꾼다) | 적힌 순서로 모두 걷는다 |
| 시각 없는 관측과 floor rate limit 은 뒤로만 간다 | 같은 파일 (:113) | 같다 |
| 하나뿐인 CLI slot 이 기다리면 runner 를 부르지 않는다 | `test_keeper_lane_cli_oneshot.ml` | 1번 부른다 |
| 앞 CLI slot 의 거절이 리셋을 적으면, 같은 계정의 다음 slot 은 부르기 전에 기다린다 | 같은 파일 | 2번 부른다 |
| Lane Add-on: 모두 기다리면 `Started` 없이 `Deferred` | `test_lane_addon_exact_runner.ml` | `Started` 뒤 거절 |
| Lane Add-on: 일부만 기다리고 부른 slot 이 입력을 거절하면 `Deferred`. 기다린 slot 은 0번 불린다 | 같은 파일 | 기다릴 slot 도 1번 부른다 |
| Candle: 리셋 기록이 있으면 pulse 를 여러 번 돌려도 provider 호출이 0. pulse 는 보관된 원본을 읽기만 한다(main 도 같다). 호출은 그 읽기가 깨운 host 재실행(`Lane_addon_exact.run`)에서 시작한다. 그래서 호출 수는 host 를 여러 번 깨워 센다 | `test_candle_appraiser_transport.ml`(읽기), `test_lane_addon_exact_runner.ml`(재실행) | 재실행마다 1번 |
| Board attention: HTTP slot 만 있고 모두 기다리면 worker 가 멈추지 않고 `Lane_deferred`. 격리 없음 | `test_keeper_board_attention_worker.ml` | 부른 뒤 deferred |
| HITL: 하나뿐인 CLI slot 이 기다리면 부르지 않고, 그 slot 의 identity 로 `Exact_flow_execution_failed` 정산 | `test_hitl_summary_worker.ml` | 부른 뒤 격리(`Cli_settled`) |
| HITL: HTTP slot 이 실패한 뒤 CLI slot 이 모두 기다리면, CLI 를 부르지 않고 HTTP 바인딩을 `Exact_flow_execution_failed` 로 정산 | 같은 파일 | CLI 를 부른 뒤 CLI identity 로 격리 |
| HITL: HTTP slot 만 있고 모두 기다리면 준비 오류 없이, 부르지 않고 정산 | 같은 파일 | 부른 뒤 정산 |
| Librarian: 모두 기다리면 설정 실패가 아니다. 줄이기·나누기·확정 없음 | `test_keeper_librarian_cli_lane.ml` | 부른다 |
| vision tool: 모든 image runtime 이 기다리면 기다림 결과. `runtime_id` 로 고른 runtime 이 기다릴 때, 이번 turn 에 쓴 runtime 을 빼고 기다리는 runtime 만 남을 때, 부른 runtime 이 모두 실패하고 기다리는 runtime 이 남을 때도 같다 | `test_keeper_vision_tool.ml`. Retry-After 로 기다리는 runtime 을 id 로 부르던 기존 시험 둘은 기다림을 먼저 단언하게 바꾼다 | 부른다 |

TLA+ 모델은 두지 않는다. 이 규칙은 한 시점의 표를 읽는 순수 함수다. 동시성 틈은 HTTP 의 한 곳이고, 받아들였다(3.5). `specs/` 에 쉼이나 exact lane 을 다루는 모델도 없다.

배포 뒤에는 system log 에서 리셋 기록이 있는 계정으로 `Claude Code turn starting` 이 나가지 않는지 센다.

## 7. 단계

- **L0 (이 PR, 문서만).** 이 RFC 와 3.6 의 L0 문장.
- **L1 (구현, PR 하나).** 공유 판정, 세 정렬, 네 호출처와 Lane Add-on, vision tool, `.mli` 문장, 6장의 테스트. 호출처를 나눠 내지 않는다. 나누면 한 호출처만 기다리고 나머지는 계속 부르는 중간 상태가 main 에 남는다. 고칠 파일은 약 40개다. 커밋은 5개 파일씩 나눈다. 새 갈래가 닿는 곳은 OCaml 과 TypeScript 타입 검사가 모두 짚는다.

## 8. 확인 못 한 것

- 모델별 창(`seven_day_opus` 같은 이름)이 오는지 확인하지 못했다. 이 저장소의 코드·테스트·fixture 와 11-07~09 로그에는 `five_hour`·`seven_day` 만 있다. 주석도 Claude Code 창을 계정 단위로 적는다(`fusion_official_client.ml:604-606`). 모델별 창이 오면, 한 모델의 창이 끝날 때까지 같은 계정의 다른 모델 slot 도 기다린다. Keeper walk 도 지금 같다. 그때는 창 이름을 wire 경계에서 닫힌 타입으로 읽어 scope 를 나눈다.
- 이 변경 뒤 Candle 호출이 실제로 멈추는지는 배포 뒤 로그로 본다.
