---
rfc: "0458"
title: "sticky 레인 선호는 필요 없다 — 걷는 순서는 선언이고 쉼은 provider 의 것이다"
status: Draft
created: 2026-09-17
updated: 2026-09-23
author: vincent + claude
supersedes: []
superseded_by: null
related: ["provider-path-rest", "0370", "0440", "keeper-context-window-in-tokens"]
implementation_prs: ["#36881"]
---

# RFC-0458 — sticky 레인 선호는 필요 없다

## 0. 요약

레인은 후보 id 의 순서 목록이고, 걸음은 그 목록을 앞에서부터 시도한다. 여기에 2026-07-21
(#25386) 부터 "마지막으로 성공한 후보를 다음 턴에 맨 앞에 둔다"는 sticky 선호가 얹혀 있다.
이 선호는 성공할 때마다 갱신되고, 레인을 타는 모든 Keeper 가 공유하며, 후보의 종류를
가리지 않는다. 한 Keeper 가 네 번째 후보(공식 클라이언트 Claude Code)에서 한 번 성공하면
같은 레인의 Keeper 전부가 그 뒤로 머리 후보를 다시 두드리지 않는다. 2026-09-16 라이브에서
analyst 가 그렇게 4턴 연속 Claude Code 에 머물렀다(#36858).

sticky 선호를 없앤다. 대신 넣는 장치는 없다.

- sticky 가 원래 막으려던 것은 "시간당 rate-limit 창에 걸린 머리를 매 턴 두드리는 일"이다
  (#25386). 429·402 는 2026-09-15 의 RFC-provider-path-rest 가 쉼과 강등으로 이미 맡았다.
- 타임아웃·5xx·네트워크 실패는 아무것도 남기지 않아, 다음 턴에 같은 머리를 다시 먼저 불렀다.
  이 실패도 429 와 같은 칸에 증거로 남기고, 그 후보가 성공할 때까지 걸음에서 뒤로 보낸다
  (§3.4). 시간으로 풀리는 쉼은 만들지 않는다.
- 쉼을 남기지 않는 실패(반복 생성 등)는 같은 턴 안에서 다음 후보로 회전한다. 지금도 그렇다.
- 걷는 순서는 선언이다. 마지막 성공은 순서를 바꾸지 않는다. 마지막 후보는 앞 후보가 전부
  실패하거나 쉴 때만 걷히고, 다음 사이클은 다시 머리부터다.

운영자 결정(2026-09-17): 근본 개선은 장치를 더하는 것이 아니라 필요 없는 장치를 빼는 것이다.

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

### 1.2 걸음 순서를 정하는 것

`Keeper_turn_driver.assignment_walk_order` (#36867): 선언 순서 →
`Runtime_lane_preference.prefer_order_with` 로 sticky 후보를 맨 앞에 → quota·backpressure
강등(RFC-0370 §3.3) → 쉬는 경로 판정(`path_rest`, provider-path-rest §3.3).

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
| 14:06Z~15:25Z | deepseek 14건, 그중 4건 "model repeated itself"(`Generation_repeated`) → kimi 로 회전, kimi 400(token limit, #36844) | sticky 는 여전히 deepseek |
| 15:36Z | kimi 뒤 네 번째 후보 claude_code 성공 | sticky = claude_code |
| 15:37~15:57Z | claude_code 4턴 연속(298K→352K 토큰 세션) | 성공마다 sticky 갱신. 머리로 돌아갈 조건이 없음 |

같은 레인의 goo-yang-bong·jazz-developer 도 같은 시각에 claude_code 로 갔다. 공유된
선호가 keeper 를 가리지 않은 결과다. 공식 클라이언트 세션은 masc 의 창(marks)이 닿지
않아 186K~615K 토큰까지 자랐다.

## 2. 왜 빼도 되나

1. **원래 목적은 다른 장치가 맡았다.** #25386 의 문제 서술은 "an hourly provider rate-limit
   window is hit on every turn before the lane fails over"다. 그때는 경로별 쉼이 없었다.
   provider-path-rest 뒤로 429 는 힌트 시각 또는 60초, 402 는 리셋 시각 또는 900초를 쉬고,
   증거가 남은 경로는 `quota_ordered_runtime_ids` 가 뒤로 보낸다. 힌트가 없으면 뒤로 가는
   것은 그 후보가 성공할 때까지다. 타임아웃·5xx·네트워크 실패는 증거를 남기지 않았으므로,
   그 머리를 매 턴 두드리는 일은 sticky 를 뺀 뒤에도 남았다. §3.4 가 닫는다.
2. **sticky 는 증거가 아니라 캐시다.** "머리가 죽어 있다"를 재지 않고 "마지막에 누가
   성공했나"만 기억한다. 머리가 살아나도 알 길이 없고, TTL 은 마지막 성공에서 다시 세어져
   성공하는 fallback 은 영구히 머리다.
3. **공유 단위가 틀렸다.** provider 의 쉼은 경로의 사실이라 공유가 맞다. "누가 마지막에
   성공했나"는 사실이 아니라 선택이고, 선택을 공유하면 한 Keeper 의 failover 가 레인 전체의
   배정을 바꾼다.
4. **1시간은 근거 없는 창이다.** `MASC_LANE_PREFERENCE_TTL_S` 의 3600 은 측정에서 나오지
   않았다. 쉼의 길이는 provider 가 말한 시각이나 운영자가 선언한 floor·cap 이어야 한다.

## 3. 바꾸는 것

### 3.1 규칙

> 걷는 순서는 선언이다. 관측된 실패의 증거가 남은 후보만 뒤로 가고, 증거는 provider 가 말한
> 시각이 지나거나 그 후보가 성공하면 풀린다. 마지막 성공은 다른 후보의 순서를 바꾸지 않는다.

`assignment_walk_order ~now id` 는 선언 순서에 quota·backpressure 강등만 적용한다.
같은 턴 안의 회전(`attempt_runtime_candidates`)은 그 순서를 걷는다.

### 3.2 없어지는 것

- `Runtime_lane_preference` 의 sticky 부분: `State.remember`·`observe`·`reorder`·`preferred`,
  `prefer_order`·`prefer_order_with`·`note_success`·`preferred_of_lane`·`ttl_s`·
  `reset_for_testing`, 환경변수 `MASC_LANE_PREFERENCE_TTL_S`
  (`Env_config_runtime.Lane.preference_ttl_s`, snapshot 항목).
- 남는 429 backpressure 부분은 뜻에 맞는 이름으로 옮긴다: `Runtime_candidate_backpressure`.
  `Runtime.t.candidate_preference` 필드는 `candidate_backpressure` 로.
- 드라이버: `keeper_turn_driver.ml` 의 `prefer_order` 두 사이트와 `note_success` 한 사이트,
  `walk_order.preferred`.
- 예측(`Keeper_next_request_forecast`)의 `walk.preferred` 와 밴드의 "the lane's last good
  candidate since …" 문장. 후보의 자리는 선언 순서와 쉼으로만 설명한다.
- 대시보드 `lane_json` 의 `preferred_candidate`·`preferred_at_ts`
  (`server_dashboard_runtime_resolved_json.ml`), TypeScript 소비처 셋
  (`fleet-aside-extras.ts`, `settings-surface.ts`, `keeper-runtime-model-editor.ts`),
  TUI 의 `rrl_preferred_candidate`·`rcr_preferred_at_ts`(`tui_decode`, `masc_tui_render`).
- 테스트: `test_runtime_lane_preference` 의 sticky 케이스, failover 의 #34823 "out-of-lane
  winner" 계열, 밴드·예측·대시보드의 preferred 케이스.

죽은 개념은 흔적을 남기지 않는다. "sticky 는 폐기됐다" 같은 주석도 두지 않는다.

### 3.3 설정과 마이그레이션

설정은 바뀌지 않는다. 라이브 glm-coding 레인의 네 번째 후보 `claude_code.claude-sonnet-5`
는 자리 그대로 마지막 후보다. 이미지 후보로 넣었던 뜻은 RFC-0440 이 capability 로 맡으므로
이 자리에 남길지는 운영자가 정한다.

### 3.4 타임아웃·5xx·네트워크 실패도 증거로 남긴다

운영자 결정(2026-09-17): 숫자로 된 쉼을 새로 만들지 않고, 429 와 같은 칸에 증거로 남겨
순서를 내린다.

운영자 결정(2026-09-23, #38174): 실패를 본 Keeper 가 다음 사이클에 그 후보를 한 번 더 부른다.
증거를 그 후보의 답으로만 지우면, fallback 이 계속 답하는 동안 머리는 불리지 않는다. 답할
기회가 없으니 머리는 재시작 전까지 돌아오지 않았다. 대신 드는 값은 이렇다. 머리가 정말 죽어
있으면, 실패를 기록한 Keeper 하나가 사이클마다 머리를 한 번 헛되이 부른다. 타임아웃이면 그
Keeper 가 제한 시간 전체를 기다린다. §5 의 `Rotate_now` 헛호출과는 다르다. 그쪽은 레인을
타는 모든 Keeper 가 치르고 대개 빨리 끝난다. 이쪽은 Keeper 하나가 치르지만 한 번이 길 수
있다. 다른 Keeper 는 그동안 계속 fallback 부터 걷는다.

라이브 근거(runtime-manifests, 2026-09-16~17): 첫 시도가 실패한 1,388번 중 **408번**은 바로
다음 턴에 같은 머리를 다시 첫 시도로 불러 또 실패했다. 다음 턴에 같은 머리가 성공한 것은
**45번**이다. 되풀이된 실패에 든 시간은 합쳐 약 75,000초다. manifest 의 `error_kind` 는
`api`·`provider` 로만 나뉘어, 이 408번에는 인증·잘못된 요청처럼 이 절이 다루지 않는 실패도
섞여 있을 수 있다.

규칙:

1. **기록은 경로 분류 하나로 한다.** 지금은 실패를 경로로 분류하는 곳
   (`Keeper_runtime_failure_route.route_of_error`)과 증거를 남기는 곳
   (`keeper_turn_driver.ml` 의 `Agent_core.Error.t` match, 나머지는 `| _ -> ()`)이 따로
   분류한다. 그래서 `Runtime_connection_closed` 는 `Server_error` 로 걷히지만 증거 쪽에는
   닿지 않는다. 증거는 경로 값에서 남긴다. `Retry_after_observed` 의 `retry_class` 로:
   - `Rate_limited` → 지금처럼 후보 칸의 429 증거
   - `Hard_quota` → 지금처럼 quota 창
   - `Server_error`·`Network_transient`·`Provider_timeout` → 후보 칸의 실패 증거. 다만 경로는
     MASC 자신의 입장 단계(허가 대기열 `Queue`, 로컬 용량 `Capacity_backpressure`)에서 끝난
     타임아웃도 `Provider_timeout` 이라 부른다. 아무것도 보내지 않은 실패라 후보의 사실이
     아니므로, 그 두 phase 는 증거로 남기지 않는다. 경로가 이 둘을 가르지 못하는 문제는 따로
     고친다.
   - `Capacity_backpressure` → 남기지 않는다. MASC 자신의 슬롯과 클라이언트 봉투라 후보의
     사실이 아니다.
   - `Rotate_now`·`Exhausted_visible_alive` → 남기지 않는다(§5).
   wildcard 없이 전부 나열한다. 새 class 가 생기면 컴파일러가 이 자리를 가리킨다.
2. **한 칸에 두 증거를 나란히 둔다.** 후보 칸은 `{ rate_limit; failed_attempt }` 다. 429 는
   provider 가 말한 시각을 가질 수 있고 그 시각이 기다림을 정한다. 실패 증거는 시각이 없고
   순서만 바꾼다. 둘이 한 자리를 다투면, 나중에 난 타임아웃이 아직 창이 남은 429 의 시각을
   지워 기다림이 사라진다. 그래서 서로 지우지 않고, 그 후보가 답하면 둘 다 지운다. 실패
   증거에는 관측 시각과 class 만 있다.
3. **순서만 바꾸고 기다리게 하지 않는다.** 강등은 세 자리다. 증거 없음, 실패만 함, 쉬라는 말을
   들음(quota 소진이나 429). 각 자리 안에서는 선언 순서를 지킨다. 실패만 한 경로를 쉬는 경로
   뒤에 두면, 지금 보낼 수 있는데도 다음 dispatch 가 쉬는 머리가 풀릴 때까지 기다린다. 이
   순서는 풀린 429 가 여전히 쉬는 경로들보다 앞으로 올라오게도 한다(`walk_promotes_at_release`).
   `path_rest` 는 실패 증거에 풀리는 시각을 주지 않는다. 후보를 빼지도 않는다. 모두 증거가
   있으면 선언 순서대로 다 걷는다.
4. **첫 토큰 전에 양보한 시도는 성공이 아니다.** 사람의 메시지로 선점된 시도는
   `Ok (yielded_pre_first_token …)` 로 끝나 성공 갈래를 탄다. 지금은 응답을 한 번도 받지
   않은 후보의 429 증거와 quota 관측이 이 길로 지워진다. 양보한 시도는 증거를 지우지도
   남기지도 않는다.
5. **실패 증거는 그것을 본 Keeper 를 적는다.** 증거는 `recorded_by` 로 실패를 본 Keeper 를
   담는다. 비교는 이름 문자열의 의미가 아니라 같은 Keeper 인지만 본다. 그 Keeper 의 새 걸음
   (`Fresh_walk_by`)은 자기가 적은 증거로는 후보를 내리지 않는다. 그 후보들은 선언한 자리에
   남는다. 그래서 다음 사이클은 자기가 표시한 후보 가운데 선언 순서로 첫 번째 것을 다시 부른다.
   보통은 머리지만, 머리가 멀쩡하고 두 번째 후보만 표시돼 있으면 그 후보다. 그 후보가 또
   실패하면 증거가 새로 적히고, 답하면 지워진다. 나중에 실패를 본 Keeper 가 있으면 그 Keeper 가
   기록자가 된다. 다음 경우는 모든 증거가 후보를 내린다(`Every_mark_demotes`).
   - 다른 Keeper 의 새 걸음
   - 실패한 턴이 미뤄 둔 나머지 후보의 재시도
   - 한 걸음 안에서 다음 후보로 넘어갈 때
   - 한 번만 도는 걸음(아래)

   그래서 기록한 Keeper 도 사이클마다 표시한 후보 하나만 다시 부른다. 그 후보가 실패하면
   나머지는 지금처럼 증거 순서로 걷는다.

   **한 번만 도는 걸음은 기록자가 되지 않는다.** 완료 검토(completion review)는 매번 새
   이름(`completion-review-<uuid>`)으로 한 번만 돈다. 그 걸음이 기록자가 되면 그 이름으로 다시
   걷는 사이클이 없다. 그러면 머리는 우연히 다시 불려 답할 때까지 모든 Keeper 에게서 뒤로 간다.
   다른 Keeper 의 턴에서 앞선 후보가 모두 실패하거나, 그 후보를 직접 부르는 다음 검토가 답을
   받거나, 프로세스가 재시작해야 풀린다. 그래서 `run_named` 를 부르는 쪽이
   `Fleet_keeper_turn` 과 `One_shot_walk` 중 하나를 밝힌다. 이름의 모양으로 가르지 않는다.
   `One_shot_walk` 는 답하지 못한 실패의 증거(타임아웃·5xx·네트워크)를 남기지 않는다. 그런
   실패로 이미 있는 증거와 그 기록자를 바꾸지도 않는다. 429 와 402(HardQuota) 증거는 fleet
   턴과 똑같이 남긴다. 그 증거는 기록자 없이 provider 가 말한 쉼이나 후보의 답으로 풀리기
   때문이다. 실패 증거를 남기되 기록자를 비워 두는 길도 있었다. 하지만 그 증거는 다시 시험할
   Keeper 가 없어 이 절이 없앤 고정이 그대로 돌아온다. 증거를 남기지 않으면 머리는 다음 fleet
   Keeper 턴에 그대로 불린다. 그 턴이 실패하면 그 Keeper 가 기록자가 된다. 검토가 받은 답은
   지금처럼 증거를 지운다. 다른 Keeper 가 적은 증거도 지운다. 답은 누가 받았든 후보가 살아
   있다는 사실이다.

## 4. 고르지 않은 대안

- **(a) TTL 을 마지막 성공이 아니라 머리가 죽은 시각에서 재기.** 되돌아오는 길은 생기지만
  1시간이 여전히 근거 없는 창이고, 레인 공유는 그대로다.
- **(b) sticky 대상을 HTTP 후보로 한정.** 공식 클라이언트에 못 박히는 일은 막지만, 두 번째
  HTTP 후보에 한 시간 못 박히는 일은 그대로다.
- **(c) 후보 역할 선언(`last_resort`) + 회전 실패의 쉼.** 이 RFC 의 첫 초안이었다. 두 장치
  모두 없어도 동작이 같다는 것을 확인하고 뺐다. 마지막 수단은 자리(마지막 후보)가 이미
  말한다 — sticky 만 없으면 앞 후보가 전부 실패하거나 쉴 때만 걷히고 다음 사이클은 머리부터다.
  회전 실패에 429 floor(60초)의 쉼을 주는 것은 keeper 사이클 간격(수 분)보다 짧아 다음
  사이클에는 어차피 머리를 부르고, 같은 턴 안의 회전은 지금도 되므로 하는 일이 없다. 더 긴
  쉼은 근거 없는 창을 하나 더 만드는 것이다.
- **(d) 타임아웃·5xx·네트워크에 시간으로 풀리는 쉼.** (c) 와 같은 이유로 고르지 않았다.
  §3.4 는 시각 대신 그 후보의 성공으로 푼다.
- **(e) 다른 후보가 한 번 성공하면 머리의 증거를 풀기.** 머리가 빨리 돌아오지만, 레인을 타는
  모든 Keeper 가 사이클마다 죽은 머리를 한 번씩 두드린다(타임아웃이면 제한 시간 전체). 위
  408번이 그 비용이다. §3.4 규칙 5 는 증거를 풀지 않는다. 실패를 본 Keeper 하나만 머리를 다시
  부른다.

## 5. 남는 비용

§3.4 의 비용: 증거가 남은 머리는 두 경우에만 다시 걷힌다. 실패를 기록한 Keeper 의 다음
사이클, 그리고 앞선 후보가 모두 실패한 턴이다. 머리가 죽어 있는 동안은 기록한 Keeper 가
사이클마다 한 번 헛호출한다(타임아웃이면 제한 시간 전체). 머리가 살아나면 그 Keeper 의 다음
사이클에 돌아오고, 그 답이 증거를 지워 다른 Keeper 도 머리부터 걷는다.

기록자가 다시 걷지 않는 경우가 남는다. 기록한 Keeper 가 멈췄거나, 지워졌거나, 그 후보가 없는
레인으로 옮겨 간 경우다. 이때 증거는 그 Keeper 가 그 후보를 포함한 레인을 다시 새로 걸을
때까지 남는다. 그 전에 풀리는 길은 셋이다. 다른 Keeper 의 턴에서 앞선 후보가 모두 실패해 그
후보까지 가 답을 받거나, 그 후보를 직접 부르는 한 번만 도는 걸음(완료 검토)이 답을 받거나,
프로세스가 재시작하는 것이다. 이 경우는 받아들인다. Keeper 의 멈춤·삭제·레인
변경마다 증거를 찾아 지우려면 Keeper 수명과 런타임 셀을 잇는 새 경로가 필요하다. 그 비용에
비해 이 경우는 드물다. §6 측정에서 기록자가 오래 걷지 않은 증거가 보이면 그때 다시 정한다.

증거를 남기지 않는 실패(`Rotate_now`: `Generation_repeated`, `No_progress_*`,
`Refusal_body_not_received` …)를 내는 머리는 사이클마다 한 번 헛되이 불리고 나서 회전한다.
실린 범위(수십 K 토큰) 한 번과 실패를 알아차리는 시간(반복 생성은 스트림이 한계까지 가야
끊긴다, 수십 초)이다. 2026-09-16 analyst 는 92분에 4번이었다.

이 비용을 미리 막는 장치는 두지 않는다. §6 의 측정이 그것이 문제라고 말하면, 그때 실패
종류별 쉼을 provider-path-rest §3.3 표에 증거와 함께 더한다.

## 6. 검증

단위:

- `assignment_walk_order`: 어떤 성공 뒤에도 선언 순서다. 쉬는 경로는 뒤로 간다.
- `attempt_runtime_candidates`: 성공이 어떤 등록도 남기지 않는다(`note_success` 가 없다).
- 타임아웃·5xx·네트워크로 실패한 후보는 다음 걸음에서 뒤로 가고, 그 후보가 성공하면 돌아온다.
  기다림은 생기지 않는다.
- 실패를 기록한 Keeper 의 다음 새 걸음은 선언 순서다. 다른 Keeper 와 실패한 턴의 재시도는
  그 후보를 뒤로 보낸다. 다시 실패하면 증거가 새로 적히고, 답하면 모두에게서 지워진다.
- `run_named` 를 거친 턴과 다음 요청 예측도 같은 순서를 낸다(텍스트 턴, 이미지 재배치).
- `One_shot_walk` 의 타임아웃·5xx·네트워크 실패는 증거를 남기지 않고, 이미 있는 증거의
  기록자를 바꾸지 않는다. 429·402 증거는 fleet 턴과 같이 남긴다. 그 걸음이 받은 답은 다른
  Keeper 가 적은 증거도 지운다.
- `Runtime_connection_closed` 도 같은 증거를 남긴다(경로 분류 하나).
- `Capacity_backpressure`·`Rotate_now`·`Exhausted_visible_alive` 는 증거를 남기지 않는다.
- 첫 토큰 전에 양보한 시도는 기존 429 증거와 quota 관측을 지우지 않는다.
- 예측·밴드·대시보드·TUI 에 preferred 필드가 없다.

라이브(배포 뒤 1시간):

- 레인별로 사이클마다 첫 시도 후보를 센다. 첫 시도가 머리가 아닌 사이클은 머리가 쉬는
  동안만이어야 한다.
- 한 Keeper 가 두 사이클 연속 공식 클라이언트에 머무는 경우는 앞 후보가 전부 쉬는 동안만.
- §5 의 헛호출: 사이클마다 머리에서 `Rotate_now` 로 끝난 시도 수와 그 지연. 이 수가
  후속 결정의 근거다.

## 7. 확인 못 한 것

- 공식 클라이언트가 "쉰다"는 상태를 갖는지. `path_rest` 는 후보 행의 429 증거와 quota 창을
  보는데 Claude Code 의 rate limit 이 그 셀에 닿는지 확인이 필요하다. 닿지 않으면 마지막
  후보가 429 를 내도 다음 사이클에 다시 걷힌다 — 지금과 같다.
- #25386 이후 sticky 가 실제로 어떤 실패에서 도움이 됐는지의 기록은 없다. 라이브 측정(§6)이
  그 자리를 대신한다.

## 8. 이행

| 단계 | 내용 | 상태 |
|---|---|---|
| 1 | §3.2 전부 한 PR: sticky 삭제, 모듈 이름 변경, 드라이버·예측·밴드·대시보드·TUI·테스트 | #36881 머지 |
| 2 | §3.4 한 PR: 경로 값으로 증거 기록, 실패 증거 variant, 양보 시도의 성공 제외 | RFC |
| 3 | 배포 뒤 §6 측정, 결과를 이 RFC §5 에 적는다 | RFC |
| 4 | §3.4 규칙 5: 실패 증거에 기록한 Keeper, 그 Keeper 의 다음 걸음은 선언 순서 (#38174) | RFC |
