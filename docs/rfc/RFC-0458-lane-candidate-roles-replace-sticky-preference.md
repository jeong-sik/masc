---
rfc: "0458"
title: "레인 후보의 역할은 선언이다 — sticky 선호를 없애고 쉼과 마지막 수단으로 걷는다"
status: Draft
created: 2026-09-17
updated: 2026-09-17
author: vincent + claude
supersedes: []
superseded_by: null
related: ["provider-path-rest", "0370", "0440", "0265", "keeper-context-window-in-tokens"]
implementation_prs: []
---

# RFC-0458 — 레인 후보의 역할은 선언이다

## 0. 요약

레인은 후보 id 의 순서 목록이고, 걸음은 그 목록을 앞에서부터 시도한다. 여기에 2026-07-21
(#25386) 부터 "마지막으로 성공한 후보를 다음 턴에 맨 앞에 둔다"는 sticky 선호가 얹혀 있다.
이 선호는 성공할 때마다 갱신되고, 레인을 타는 모든 Keeper 가 공유하며, 후보의 종류를
가리지 않는다. 그래서 한 Keeper 가 네 번째 후보(공식 클라이언트 Claude Code)에서 한 번
성공하면 같은 레인의 Keeper 전부가 그 뒤로 머리 후보를 다시 두드리지 않는다. 2026-09-16
라이브에서 analyst 가 그렇게 4턴 연속 Claude Code 에 머물렀다(#36858).

운영자는 2026-09-17 에 "근본 개선"을 택했다. 이 RFC 는 세 가지를 바꾼다.

1. **걷는 순서는 선언이다.** 마지막 성공은 순서를 바꾸지 않는다. sticky 선호 장치를 없앤다.
2. **쉬는 경로만 뒤로 간다.** 쉼은 증거와 풀리는 시각을 가진다(RFC-provider-path-rest).
   같은 턴에서 다른 후보로 넘어가게 한 실패(`Rotate_now`)도 그 경로를 정해진 길이만큼
   쉬게 한다. 지금은 이런 실패가 쉼을 남기지 않아서 sticky 선호가 그 자리를 대신 메우고 있었다.
3. **마지막 수단은 선언한다.** 레인 표에 `last_resort` 배열을 둔다. 여기 적힌 후보는
   `candidates`(동료 후보)가 전부 쉴 때만 걷고, 성공해도 다음 사이클의 순서를 바꾸지 않는다.

## 1. 지금 동작 (2026-09-16 실측, 서버 eee8f6aee8)

### 1.1 선언

```toml
# 기본 레인. analyst, sangsu, jazz-developer, imp, goo-yang-bong …
# sonnet-5 는 이미지 후보다.
[runtime.lanes."glm-coding.glm-5.3-flash"]
candidates = [
  "glm-coding.glm-5.3-flash",
  "ollama_cloud.ollama-cloud-deepseek-v4-1-flash",
  "kimi_coding.kimi-k3",
  "claude_code.claude-sonnet-5",
]
```

주석은 sonnet-5 를 "이미지 후보"라고 적었다. 코드에는 그런 구분이 없다. 네 후보는 같은
자격으로 걷힌다.

### 1.2 걸음 순서를 정하는 것

`Keeper_turn_driver.assignment_walk_order` (#36867 뒤): 선언 순서 →
`Runtime_lane_preference.prefer_order` 로 sticky 후보를 맨 앞에 → quota·backpressure
강등(RFC-0370 §3.3) → 쉬는 경로 판정(`path_rest`).

sticky 선호(`lib/runtime/runtime_lane_preference.ml`, 상태는 `_state.ml`):

- `note_success ~lane_id ~candidate` 는 **모든** 성공 시도에서 불린다
  (`keeper_turn_driver.ml:731`). 머리가 성공해도, 네 번째 후보가 성공해도.
- 항목은 레인 id 로 키가 잡힌다. `.mli` 가 명시한다: "shared across keepers on purpose:
  one keeper's successful failover discovery benefits every keeper routed through the same lane".
- TTL 은 `MASC_LANE_PREFERENCE_TTL_S`(기본 3600초). **마지막 성공 시각**부터 센다. 성공이
  이어지는 한 만료되지 않는다. 머리는 sticky 후보가 실패하고 나서야 다시 시도된다.
- 후보 종류 구분이 없다. HTTP 바인딩, 공식 클라이언트, 로컬 모델이 같은 규칙을 탄다.

### 1.3 라이브에서 일어난 일

analyst, glm-coding 레인, 14:06Z~15:57Z.

| 시각 | 일 | 순서에 미친 영향 |
|---|---|---|
| ~13:06Z | deepseek 성공(failover) | sticky = deepseek. 이후 glm-coding 시도 0건 |
| 14:06Z~15:25Z | deepseek 14건, 그중 4건 "model repeated itself"(`Generation_repeated`) → kimi 로 회전, kimi 400(token limit, #36844) | `Rotate_now` 는 쉼을 남기지 않음. sticky 는 여전히 deepseek |
| 15:36Z | kimi 뒤 네 번째 후보 claude_code 성공 | sticky = claude_code |
| 15:37~15:57Z | claude_code 4턴 연속(298K→352K 토큰 세션) | 성공마다 sticky 갱신. 머리로 돌아갈 조건이 없음 |

같은 레인의 goo-yang-bong·jazz-developer 도 같은 시각에 claude_code 로 갔다. 공유된
선호가 keeper 를 가리지 않은 결과다. 공식 클라이언트 세션은 masc 의 창(marks)이 닿지
않아 186K~615K 토큰까지 자랐다.

## 2. 기존 장치가 왜 못 했나

1. **sticky 는 증거가 아니라 캐시다.** "머리가 죽어 있다"는 사실을 재지 않고 "마지막에
   누가 성공했나"만 기억한다. 머리가 살아나도 알 길이 없다.
2. **갱신 규칙이 되돌아오는 길을 막는다.** TTL 을 마지막 성공에서 재니, 성공하는 fallback
   은 영구히 머리다.
3. **공유 단위가 틀렸다.** 429·402 같은 provider 의 쉼은 경로의 사실이라 공유가 맞다
   (provider-path-rest). "누가 마지막에 성공했나"는 사실이 아니라 선택이고, 선택을 공유하면
   한 Keeper 의 failover 가 레인 전체의 배정을 바꾼다.
4. **후보의 역할이 코드에 없다.** 운영자는 주석으로 "이미지 후보"라고 적었다. 걸음은 그
   주석을 읽지 못한다.
5. **sticky 가 진짜 메우던 구멍은 따로 있다.** provider-path-rest 는 429·402·타임아웃에
   쉼을 준다. 그러나 같은 턴 안에서 다음 후보로 넘어가게 하는 `Rotate_now` 부류
   (`Generation_repeated`, `No_progress_*`, `Refusal_body_not_received`, `Attempt_rejected`,
   `Model_unavailable`, `Auth_failed` …)는 쉼을 남기지 않는다. sticky 를 그냥 빼면 이 실패
   뒤 다음 사이클은 같은 머리를 다시 부른다. deepseek 가 한 시간에 네 번 반복 생성으로
   끊긴 날에는 매 사이클 그 머리를 두드리게 된다. 그래서 sticky 제거는 이 구멍을 typed 쉼으로
   채우는 것과 한 묶음이어야 한다.

## 3. 바꾸는 것

### 3.1 규칙

> 걷는 순서는 선언이다. 쉬는 경로만 뒤로 가고, 쉼은 증거와 풀리는 시각을 가진다.
> 마지막 수단은 동료가 전부 쉴 때만 걷고, 성공해도 아무것도 바꾸지 않는다.

### 3.2 선언 모양

```toml
[runtime.lanes."glm-coding.glm-5.3-flash"]
candidates = [
  "glm-coding.glm-5.3-flash",
  "ollama_cloud.ollama-cloud-deepseek-v4-1-flash",
  "kimi_coding.kimi-k3",
]
last_resort = ["claude_code.claude-sonnet-5"]
```

- `candidates` 는 동료 후보다. 선언 순서로 걷는다.
- `last_resort` 는 마지막 수단이다. 순서가 있고, `candidates` 가 **전부** 쉴 때만 그 순서로
  걷는다. 비어 있어도 된다(키를 생략).
- 한 id 가 두 배열에 다 있으면 로드 오류. 두 배열이 모두 비면 로드 오류(지금과 같다).
- `[runtime].default` 가 걸음을 끝낸다는 규칙(`resolve_assignment`)은 그대로다. default 가
  두 배열 어디에도 없으면 `candidates` 끝에 붙는다.

타입:

```ocaml
(* Runtime_lane *)
type role = Peer | Last_resort
type t = { id : string; peers : string list; last_resort : string list }
val ordered_candidates : t -> string list   (* peers @ last_resort — 지금 읽는 곳을 위해 *)
val role_of : t -> string -> role option
```

`Runtime_schema.lane_decl` 에 `last_resort_ids : string list` 가 붙고, `parse_lane` 은
`candidates`·`last_resort` 두 키만 받는다(그 밖은 지금처럼 오류).
`Runtime.set_runtime_lane_candidates` 는 `~last_resort` 를 같이 받아 두 배열을 함께 쓴다.

### 3.3 걸음

`assignment_walk_order ~now id` 는:

1. `peers` 를 선언 순서로 두고, 쉬는 경로(`path_rest = Path_resting`)를 뒤로 보낸다
   (quota·backpressure 강등은 지금 규칙 그대로).
2. `peers` 가 하나라도 쉬지 않으면 `last_resort` 는 이번 걸음에 **들어가지 않는다**.
3. `peers` 가 전부 쉬면 `peers`(쉬는 채로) 뒤에 `last_resort` 를 선언 순서로 붙인다.
   `walk_rest` 는 지금처럼 "첫 경로가 풀리는 시각"과 "그보다 이른 승격 시각" 중 이른 쪽을
   기다린다. 마지막 수단이 쉬지 않으면 즉시 걷는다.

`prefer_order` 단계는 없어진다. `walk_order.preferred` 도 없어진다.

같은 턴 안의 회전(`attempt_runtime_candidates`)은 이 순서를 그대로 걷는다. 걸음이
`last_resort` 에 닿는 것은 `peers` 가 이 턴에서 전부 실패했거나 전부 쉬는 경우다.
`last_resort` 에서의 성공은 `note_success` 를 부르지 않는다(함수 자체가 없어진다).

### 3.4 회전 실패의 쉼

provider-path-rest §3.3 표에 한 줄을 더한다.

| 증거 | 풀리는 시각 |
|---|---|
| `Rotate_now { rotate }` 로 이 경로를 떠났다 | `noted_at + rate_limit_backoff_floor_sec` (60초, 운영자 선언값) |

- 새 숫자를 만들지 않는다. 힌트 없는 429 가 쉬는 길이와 같은 선언값을 쓴다. 이 값이 부족하면
  운영자가 그 선언을 고친다.
- `Exhausted_visible_alive`(요청 자체가 문제: `Deterministic_request`, `Context_overflow` …)
  는 쉼을 남기지 않는다. 입력이 바뀌지 않으면 어느 경로도 같다.
- 저장소는 429 와 같은 자리다: `Runtime_lane_preference.note_rate_limit` 가 쓰는 후보 행의
  backpressure 셀. 회전 실패도 같은 셀에 `Rotated { noted_at; rotate }` 로 남고,
  `candidate_backpressure ~now` 가 풀리는 시각을 답한다. 성공이 셀을 지운다(지금과 같다).

이 한 줄이 sticky 가 메우던 구멍이다. 머리가 반복 생성으로 끊기면 60초 뒤에 다시 머리다.
그 사이는 두 번째 후보가 머리다. 한 시간 동안 두 번째 후보에 못 박히는 일은 없다.

### 3.5 없어지는 것

- `Runtime_lane_preference` 의 sticky 부분: `State.remember`·`observe`·`reorder`·`preferred`,
  `prefer_order`·`prefer_order_with`·`note_success`·`preferred_of_lane`·`ttl_s`,
  환경변수 `MASC_LANE_PREFERENCE_TTL_S`(`Env_config_runtime.Lane.preference_ttl_s`).
- 남는 backpressure 부분은 모듈 이름이 뜻과 맞게 바뀐다:
  `Runtime_candidate_backpressure`. `Runtime.t.candidate_preference` 필드는
  `candidate_backpressure` 로.
- 대시보드 `lane_json` 의 `preferred_candidate`·`preferred_at_ts`
  (`server_dashboard_runtime_resolved_json.ml`), 그 TypeScript 소비처 셋
  (`fleet-aside-extras.ts`, `settings-surface.ts`, `keeper-runtime-model-editor.ts`),
  TUI 의 `rrl_preferred_candidate`·`rcr_preferred_at_ts`(`tui_decode`, `masc_tui_render`).
  대신 `role` 과 `rest`(풀리는 시각)를 낸다.
- 예측(`Keeper_next_request_forecast`)의 `walk.preferred` → 후보마다 `role` 이 붙고, 밴드의
  "the lane's last good candidate since …" 문장은 "last resort: walks only when every peer
  rests" 로 바뀐다.
- 테스트: `test_runtime_lane_preference` 의 sticky 케이스 10건, failover 의 #34823
  "out-of-lane winner" 계열은 대상이 사라진다. 새 테스트는 §6.

죽은 개념은 흔적을 남기지 않는다. "sticky 는 폐기됐다" 같은 주석도 두지 않는다.

### 3.6 마이그레이션

하드 컷이다. `last_resort` 키가 없는 레인은 지금과 같은 뜻이다(전부 동료 후보, sticky 만
사라짐). 라이브 `runtime.toml` 은 배포 때 glm-coding 레인의 `claude_code.claude-sonnet-5`
를 `last_resort` 로 옮긴다. 이미지 후보로 넣었던 뜻은 RFC-0440(이미지 턴의 reroute 가 lane
∪ media_failover 를 걷는다)이 맡으므로 이 레인에 남길 이유가 마지막 수단뿐이다.

## 4. 고르지 않은 대안

- **(a) TTL 을 마지막 성공이 아니라 머리가 죽은 시각에서 재기.** 되돌아오는 길은 생기지만
  "1시간"이 여전히 근거 없는 창이고, 레인 공유와 역할 부재는 그대로다.
- **(b) sticky 대상을 HTTP 후보로 한정.** 공식 클라이언트에 못 박히는 일은 막지만,
  두 번째 HTTP 후보에 한 시간 못 박히는 일은 그대로다. 그리고 어느 후보가 마지막 수단인지
  코드가 여전히 모른다.
- **(c′) 역할을 세 가지 이상으로.** `image_only`, `local_fallback` 같은 역할은 지금 근거가
  없다. 이미지는 RFC-0440 이 capability 로 고른다. 두 배열로 시작하고, 필요가 측정되면 늘린다.

## 5. 지켜지는 것

- provider-path-rest 의 보장(#34653: provider 의 쉼은 wake 로 끊지 않는다)은 그대로다.
  회전 쉼은 `Path_release` 부류로 같은 규칙을 탄다.
- RFC-0370 §3.3 quota 강등은 그대로다. 강등은 순서일 뿐 제외가 아니다.
- RFC-0440 이미지 reroute 는 후보 집합을 바꾸지 않는다. 마지막 수단도 이미지를 받으면
  reroute 후보가 될 수 있다.
- deferred suffix(실패한 턴이 남긴 나머지 후보)는 지금처럼 다음 사이클이 그대로 걷는다.
  suffix 에 마지막 수단이 들어 있으면 동료가 전부 실패했다는 뜻이므로 규칙과 맞는다.

## 6. 검증

단위:

- `parse_lane`: `last_resort` 수용, 겹치는 id 거부, 미지 키 거부, 두 배열 모두 비면 거부.
- `assignment_walk_order`: 동료가 하나라도 서 있으면 마지막 수단이 순서에 없다; 전부 쉬면
  뒤에 붙는다; 마지막 수단의 성공 뒤 다음 걸음은 다시 선언 순서다.
- `Rotate_now` 뒤 `path_rest` 가 60초 쉼을 답하고, 그동안 걸음이 그 경로를 뒤로 보내고,
  풀린 뒤 머리로 돌아온다.
- `Exhausted_visible_alive` 는 쉼을 남기지 않는다.

라이브(배포 뒤 1시간):

- 레인별로 사이클마다 첫 시도 후보를 센다. 동료가 서 있는데 마지막 수단이 첫 시도인 사이클은 0.
- 한 Keeper 가 두 사이클 연속 공식 클라이언트에 머무는 경우는 동료가 전부 쉬는 동안만.
- `Generation_repeated` 뒤 같은 머리가 60초 안에 다시 불리는 사이클은 0, 60초 뒤에는 다시 머리.
- `origin=whole_history` 전송과 kimi `token limit` 400 은 #36857 뒤로 이미 0 이어야 한다.

## 7. 확인 못 한 것

- 회전 실패의 쉼 길이로 429 의 floor(60초)를 같이 쓰는 것이 맞는지. 반복 생성은 provider
  상태가 아니라 모델과 입력의 성질이라 더 길어야 할 수도 있다. 측정 뒤 별도 선언값으로
  가를지 정한다.
- 공식 클라이언트가 "쉰다"는 상태를 갖는지. 지금 `path_rest` 는 후보 행의 429 증거와 quota
  창을 보는데 Claude Code 의 rate limit 이 그 셀에 닿는지 확인이 필요하다.
- `set_runtime_lane_candidates` 를 부르는 대시보드 레인 편집기가 `last_resort` 를 편집할
  UI 를 갖출지, 아니면 파일 편집만으로 둘지.

## 8. 이행

| 단계 | 내용 | 상태 |
|---|---|---|
| 1 | 선언과 타입: `lane_decl.last_resort_ids`, `Runtime_lane.role`, 파서, `resolve_assignment`, `set_runtime_lane_candidates ~last_resort` | RFC |
| 2 | 걸음: `assignment_walk_order` 에서 sticky 제거·마지막 수단 규칙, `Rotate_now` 쉼(§3.4), `Runtime_lane_preference` → `Runtime_candidate_backpressure` | RFC |
| 3 | 표면: 대시보드·TUI·예측 밴드에서 preferred 를 빼고 role·rest 를 낸다 | RFC |
| 4 | 라이브 설정: glm-coding 레인의 sonnet-5 를 `last_resort` 로, 배포 뒤 §6 측정 | RFC |

1·2 는 한 PR 이어야 한다. sticky 를 먼저 빼면 §2-5 의 구멍이 그대로 열린다.
