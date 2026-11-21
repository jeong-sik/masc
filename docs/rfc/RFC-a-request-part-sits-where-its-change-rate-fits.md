---
rfc: "a-request-part-sits-where-its-change-rate-fits"
title: "요청의 각 부분은 바뀌는 빈도에 맞는 자리에 둔다"
status: Draft
created: 2026-11-20
updated: 2026-11-21
author: claude
supersedes: []
superseded_by: null
related: ["tool-results-age-out-of-context", "keeper-context-window-in-tokens"]
---

# RFC: 요청의 각 부분은 바뀌는 빈도에 맞는 자리에 둔다

## 0. 요약

- Keeper 요청 하나는 `[tools][system][이력 창][이번 턴 입력과 턴 문맥]` 이다.
- provider 캐시는 앞에서부터 같은 바이트만 읽는다. 앞부분이 바뀌거나, 유지 시간이 지나면 그 뒤를 전부 다시 쓴다.
- 2026-11-19~20 운영 기록으로 쟀다. 캐시에 안 닿은 입력의 57.9% 가 앞부분을 통째로 다시 쓴 요청에서 나왔다.
- 이미 보낸 요청 앞부분은 창이 옮겨질 때만 바뀐다(이하 「접두사 규칙」, `Keeper_model_input_ledger`). 이 RFC 는 그 규칙이 닿지 않은 여섯 곳을 고친다.
  1. 캐시 유지 시간을 binding 의 요청 정책으로 선언한다(§3.1).
  2. 턴마다 캐시를 얼마나 읽고 왜 다시 썼는지 화면에 보인다(§3.2).
  3. Anthropic 레인은 도구를 불러올 때 도구 배열을 바꾸지 않는다(§3.3).
  4. 턴 문맥은 쓴 사람에 따라 역할을 나눈다(§3.4).
  5. 같은 규범 목록을 system 에 두 번 싣지 않는다(§3.5).
  6. 회상 글은 사실 하나가 줄 하나인 바깥 글 구획으로 싣는다(§3.6).
- Fleet 방송(§4.1)은 논의 중이다.

## 1. 측정

### 1.1 자료

| 자료 | 범위 | 쓴 곳 |
|---|---|---|
| 비용 원장(요청 행) | 2026-11-19 ~ 11-20, 이틀 | 토큰, 시각, 런타임 |
| provider 입력 스냅샷(턴마다 한 행) | 같은 이틀 | system·도구·메시지 sha256 |
| wire 캡처 | 바이트 예산 ring, 3.2~3.5시간 | 도구 배열 변화의 갈래 |

- 캐시에 안 닿은 입력은 `non_cached_input_tokens`(= cache_creation + cache_miss)다.
- Claude 레인의 `cache_miss_input_tokens` 는 요청마다 2 안팎이라 그것만 세면 손실이 안 보인다.

### 1.2 비용 구성

- 턴 2,731 · 요청 22,764.
- 캐시에 안 닿은 입력 2억 2,470만 · 캐시 읽기 32억 8,400만 · 출력 1,500만 토큰.
- 앞부분을 통째로 다시 쓴 요청(입력 6만 토큰 이상, 안 닿은 몫이 절반 넘음)이 안 닿은 입력의 57.9% 다.

### 1.3 통째로 다시 쓴 까닭

Claude 레인, 입력 6만 토큰 이상인 턴 첫 요청이다. 앞 턴 마지막 스냅샷과 처음 달라진 곳을 견줬다.

| 기간 | 까닭 | 다시 쓴 토큰 |
|---|---|---|
| 11-20 01:36Z 이전 빌드 | system 끝의 요청 출처 블록이 바뀜(Goal 변화 포함) | 약 3,070만 |
| 01:36Z 이후 빌드(1.5시간) | 5분 넘게 쉼 | 542만(73%) |
| 같은 기간 | Goal 사건 하나(Goal 1→2개) | 131만 |
| 같은 기간 | 그 밖(도구 배열·창 이동) | 141만 |

- 요청 출처 블록은 #53316 이 끝 문맥으로 옮겼다. 01:36Z 빌드부터 system 에 그 블록은 0번이다.
- 새 빌드의 system 변화 31쌍은 모두 Goal 사건 하나에서 나왔다.

앞 요청이 끝난 뒤 쉰 시간별로 보면 이렇다(두 빌드, 회상을 켜지 않은 Keeper).

| 쉰 시간 | 턴 | 통째로 다시 씀 |
|---|---|---|
| 1분 안 | 743 | 34.1%(옛 빌드의 요청 출처 블록 몫이 크다) |
| 1~4분 | 493 | 26.6% |
| 4~5분 | 199 | 13.1% |
| 5~6분 | 41 | 90.2% |
| 6분 넘게 | 199 | 100% |

- Anthropic 기본 캐시는 5분 산다. 요청 시작부터 잰다.
- GLM 레인은 5분 넘게 쉬고 덧붙이기만 한 턴 125개에서 다시 쓰기가 0번이었다.

### 1.4 도구 배열 변화

wire 캡처 3.2시간, 연속한 요청 4,162쌍에서 62번 바뀌었다.

| 갈래 | 번 |
|---|---|
| 공식 클라이언트 시도가 끼어든 뷰 전환 | 22 |
| 새 빌드 뒤 도구 설명 변경 | 18 |
| 턴 중 도구 불러오기 | 13 |
| 턴 경계 은퇴 | 5 |
| 재시작 뒤 lane add-on 복귀 | 4 |

- Claude 레인에서 불러오기 직후 요청은 6번 모두 캐시를 하나도 못 읽었다. 한 번에 8.8만~15.5만 토큰을 다시 썼다.
- 불러오기·은퇴 18번이 그 창에서 캐시에 안 닿은 입력의 6.5% 다.
- 도구 배열이 바뀌면 그 전 thinking 블록도 요청에서 빠진다.

### 1.5 턴마다 다시 실리는 것

- 판정 회상을 켠 Keeper 넷이 턴의 11.4% 인데, 캐시에 안 닿은 입력의 23.6% 를 쓴다.
- 고른 기억 본문(턴당 177~343KB)이 턴 문맥에 실린다. Anthropic 레인은 지난 턴 문맥을 `clear_at` 으로 빼서, 고른 집합이 같아도 새 턴마다 본문을 다시 쓴다.
- 이 Keeper 들의 턴 사이 창 옮김 비율은 4.5~16% 다.

### 1.6 요청마다 겹쳐 실리는 것

- 규범 20조가 Agent Core 요청의 system 에 두 번 실린다. `<norms>` 6,532B, `<norms_current>` 6,895B 이고 조항 줄은 같다.
- 까닭: 원장에 roster 밖 주체가 쓴 줄이 있어 투영이 늘 `Isolated_history` 다. 그때는 기록된 System 이 있어도 현재 조항 전체를 덧붙인다(`keeper_run_context.ml`).

## 2. 규칙

### 2.1 한 문장

요청의 각 부분은 값이 바뀌는 빈도에 맞는 자리에 둔다. 역할은 그 글을 누가 썼는지로 정한다.

### 2.2 자리

| 바뀌는 때 | 자리 | 예 |
|---|---|---|
| 빌드·설정을 바꿀 때 | tools, system | Keeper 안내문, 규범, 상주 도구 |
| 창이 옮겨질 때 | 창 머리 | 하던 일 메시지 |
| 턴마다, 사건이 날 때 | 턴 첫 요청 끝, 한 번 | 턴 문맥 |
| 요청마다 | 최신 도구 결과 뒤 | 도구 라운드 뒤 다시 싣는 블록 |

- 쉬는 것도 바뀌는 것이다. 유지 시간을 넘긴 쉼은 앞부분이 바뀐 것과 같은 값을 치른다.
- 그래서 유지 시간은 Keeper 가 깨는 주기에 맞춰 선언한다(§3.1).

## 3. 곳마다 바꾸는 것

### 3.1 캐시 유지 시간을 선언한다

지금:
- Agent Core 의 `Provider_config.cache_extended_ttl` 은 있다. 켜면 breakpoint 마다 `"ttl": "1h"` 를 싣는다.
- MASC 가 Agent 설정을 짤 때 이 값을 넣지 않아 늘 5분이다.

비용 모형(이틀치 Claude 레인 요청, Sonnet 5.5 가격: 5분 쓰기 1.25배, 1시간 쓰기 2배, 읽기 0.05배):

| | 5분 대비 |
|---|---|
| 모두 1시간 | +19% |
| 깨는 주기가 5~60분인 Keeper 다섯 | −15% ~ −43% |
| 대부분 5분 안에 다시 깨는 Keeper 아홉 | +4% ~ +39% |

- 1시간 쓰기는 모든 쓰기에 붙는다. 5분 안에 이어지는 턴이 많은 Keeper 는 더 비싸다.
- 그래서 모두에게 켜지 않고 Keeper 가 고른다.

바꾸는 것:
- binding(provider × 모델)에 요청 정책 `cache-retention` 을 둔다. 값은 `"5m"` 과 `"1h"` 둘이다.
  - 닫힌 variant(`Runtime_schema.cache_retention`)로 읽는다. 다른 글이면 설정 오류다.
  - 없으면 provider 기본값인 5분이다.
- 받는 곳은 catalog provider 행이 정한다. 행이 `supports_extended_cache_ttl` 을 선언한 Messages 런타임만 받는다.
  - 같은 Messages wire 를 쓰는 다른 endpoint 는 그 계약을 적지 않았다. `supports_parallel_tool_suppression` 과 같은 방식이다.
  - 다른 wire 와 공식 클라이언트는 선언을 거절한다.
- 런타임 어댑터가 `Provider_config.make ~cache_extended_ttl` 로 넘긴다.
- Agent 설정 조립이 provider 설정의 값을 이어받는다. checkpoint 로 다시 시작할 때도 같다.
- runtime.toml 편집기는 글 단위로 고치므로 이 키를 지우지 않는다.
- 1시간 쓰기는 값이 다르다. 공식 가격표에서 모든 모델이 기본 입력의 2배다(5분은 1.25배).
  - 모델 행이 `cache_write_1h_multiplier` 를 선언한다.
  - 가격 출처는 그 요청이 쓴 등급을 든다. `Provider_config.pricing_source` 가 요청 본문의 `ttl` 과 같은 `cache_extended_ttl` 로 정한다.
  - 1시간 값이 없는 모델의 1시간 쓰기는 값 없이 남는다. 5분 값으로 바꿔 매기지 않는다.
  - 이 층이 binding 선언보다 먼저 들어간다. 그래야 1시간을 켤 수 있게 된 순간부터 `cost_usd` 가 청구와 맞는다.

binding 에 두는 까닭:
- 레인은 여러 provider 후보를 잇는 목록이다. 구독 공식 클라이언트와 GLM 후보에는 이 값이 뜻이 없다.
- 요청 정책(`disable_parallel_tool_use`, `max_context`)은 이미 binding 에 있다.
- 1시간이 맞는 Keeper 는 1시간 binding 을 직접 배정하거나, 그 binding 을 잇는 레인을 쓴다.

### 3.2 턴마다 캐시 결과와 까닭을 보인다

운영자가 §3.1 을 고르려면 Keeper 마다 무엇을 잃는지 보여야 한다.

투영(projection) 하나를 둔다. 새 저장 상태는 없다.
- 입력: 앞 턴과 이번 턴의 provider 입력 스냅샷, 이번 턴 첫 요청의 비용 행, 앞 요청이 끝난 시각, 선언된 유지 시간.
- 출력: 읽은 토큰, 다시 쓴 토큰, 처음 달라진 곳, 쉰 시간.

처음 달라진 곳은 닫힌 variant 다.

| 갈래 | 뜻 |
|---|---|
| `Appended` | 앞 요청 뒤에 덧붙이기만 했다 |
| `System_changed` | system 바이트가 다르다 |
| `Tools_changed` | 도구 배열이 다르다 |
| `History_changed of int` | 그 번호의 메시지부터 다르다(창 이동 포함) |

- `Appended` 인데 쉰 시간이 선언된 유지 시간보다 길면 「유지 시간 넘김」으로 적는다.
- 비율이나 문턱으로 까닭을 고르지 않는다. 바이트 비교와 선언된 값만 쓴다.
- TUI Inspector 는 턴마다 한 줄로 적는다. 예: 「앞부분 13.9만 다시 씀 · 9분 쉼(유지 5분)」.
- Keeper 목록은 오늘 「유지 시간 넘김으로 다시 쓴 토큰」과 「1시간이었다면 든 값」을 보인다. 둘 다 기록에서 계산한다.

기록에서 읽는 것(2026-11-20 코드 기준):

| 사실 | 있는 곳 |
|---|---|
| 요청마다 읽은·쓴 토큰, 끝난 시각, 걸린 시간, runtime | 비용 원장 요청 행: `agent`·`keeper_turn_id`·`agent_core_turn_ordinal`·`ts_unix`·`request_latency_ms`·`cache_read_tokens`·`cache_creation_tokens`·`runtime_id` |
| 턴 마지막 요청의 system·도구·메시지 sha | `Keeper_provider_input_snapshot`(Keeper 마다 턴 한 행) |
| 그 요청이 고른 유지 시간 | 없다. 스냅샷의 wire 관측도 본문 크기와 sha 만 적는다 |
| provider 기본 유지 시간의 길이 | 없다 |

더하는 사실 둘:
- 요청이 고른 유지 시간.
  - `Complete_common.patch_telemetry` 는 요청 설정의 `canonical_model_id`·`effective_context_window` 를 응답 telemetry 에 찍는다. 같은 자리에서 `cache_write_lifetime` 을 찍는다.
  - 값은 `Provider_config` 의 함수 하나가 정한다. 가격 출처(#53780)도 그 함수를 쓴다.
  - 비용 행이 그 값을 적는다.
  - 이 기록이 없으면 투영이 지금 선언을 옛 턴에 덮어씌운다. 하루 중에 선언을 바꾸면 그 전 턴을 틀리게 센다.
- provider 기본 유지 시간.
  - catalog provider 행이 초로 선언한다. claude 는 300 이다(공식 문서).
  - 선언이 없는 provider 는 「유지 시간 넘김」을 판정하지 않고 쉰 시간만 보인다. 지금 GLM 이 그렇다(§9).
  - `One_hour` 는 등급 자체가 3600초라 따로 선언하지 않는다.
- provider 응답의 등급별 쓰기 토큰(`cache_creation.ephemeral_1h_input_tokens`)은 읽지 않는다.
  - 청구의 진실은 그 값이다. 다만 두 응답 파서(stream·non-stream)를 고쳐야 하고, Anthropic 호환 endpoint 가 그 값을 주는지는 모른다.
  - 1시간은 catalog 계약이 있는 공식 API 만 받는다(L2). 그래서 요청이 고른 값과 쓴 등급이 갈리는 길이 없다.

셈:
- 턴 N 의 첫 요청을 본다.
- 쉰 시간은 턴 N-1 마지막 요청의 시작부터 턴 N 첫 요청의 시작까지다. 시작은 `ts_unix - request_latency_ms` 다.
- 처음 달라진 곳은 턴 N-1 과 턴 N 의 스냅샷을 견준다.
  - 스냅샷은 턴의 마지막 요청만 담는다. 두 스냅샷이 `Appended` 면 턴 N 첫 요청도 덧붙이기만 했다.
  - 턴 안에서 덧붙이기가 아닌 변화는 wire 캡처 창(§1.1)에서 2,776쌍 중 22쌍이었다.
  - 그래서 `Appended` 로 센 유지 시간 넘김은 하한이다.
- 갈래에 `Runtime_changed` 를 더한다. 두 요청의 `runtime_id` 가 다르면 모델이나 계정이 달라 앞 캐시를 못 읽는다.
- 유지 시간 넘김: `Appended` 이고, 쉰 시간이 턴 N-1 마지막 요청이 고른 유지 시간보다 길다.
- 「1시간이었다면 든 값」: 그 Keeper 의 오늘 요청을 다시 매긴다.
  - 모든 쓰기는 `cache_write_1h_multiplier`(#53779)로 매긴다.
  - 5분을 고른 요청 가운데, 유지 시간 넘김 턴이면서 쉰 시간이 3600초 이하인 첫 요청은 다시 쓴 토큰을 읽기 값으로 매긴다.
- 투영을 어디서 부를지(서버 대시보드 또는 TUI)와 TUI 자리는 TUI 일관성 작업과 맞춘다.

### 3.3 Anthropic 레인은 도구를 불러올 때 배열을 바꾸지 않는다

지금:
- `keeper_tool_search` 가 이름을 받으면 다음 요청부터 그 도구를 배열에 넣는다.
- 도구 배열은 요청 맨 앞이라 그 뒤 캐시를 다 잃는다(§1.4).
- 빼는 규칙이 둘 있다. 부르지 않은 도구는 다음 턴까지, 부른 도구는 최근 300 tool call 까지다. 뺄 때 한 번 더 깨진다.

Anthropic 공식 방법(Tool search tool, Custom tool search implementation):
- 모든 지연 도구 정의를 `tools` 에 `defer_loading: true` 로 싣는다. API 는 지연 도구를 앞부분에서 뺀다.
- 사용자 정의 검색 도구가 `tool_result` 의 content 에 `{"type": "tool_reference", "tool_name": ...}` 를 돌려주면 API 가 그 자리에서 정의를 펼친다.
- 펼친 정의는 이력에 남아 다음 턴에도 다시 찾지 않고 쓴다.
- 지연 도구에는 `cache_control` 을 달 수 없다. 상주 도구가 하나는 있어야 한다.

바꾸는 것(Agent Core HTTP Anthropic 레인만):
- 요청의 `tools` 는 상주 도구, loader, 지연 도구 정의 전부다. 지연 도구에 `defer_loading: true` 를 단다.
- `cache_control` 은 마지막 상주 도구에 단다. 지금은 배열의 마지막 도구에 단다.
- `keeper_tool_search` 결과는 찾은 이름마다 `tool_reference` 블록을 싣는다.
- 은퇴 규칙 둘은 이 레인에서 쓰지 않는다. 도구는 그 `tool_reference` 가 보낸 이력 창 안에 있는 동안 쓸 수 있다. 창이 옮겨지면 같이 빠진다.
- 다른 provider 와 공식 클라이언트 레인은 지금 설계 그대로다.

남는 것:
- loader 설명에 지연 이름 목록이 있다. add-on 이 붙거나 떨어지면 그 설명이 바뀐다. 이 RFC 는 다루지 않는다.

### 3.4 턴 문맥은 쓴 사람에 따라 역할을 나눈다

지금:
- Anthropic 레인은 턴 문맥 전체를 대화 중간 system 메시지(`clear_at: next_user_message`)로 보낸다.
- 그 안에는 호스트가 쓴 상태(Task, 승인, 완료 판정)와 바깥에서 온 글(Fleet 방송, Board 글, 다른 화자의 mention, 기억·wiki 본문)이 같이 있다.
- 공식 문서(Mid-conversation system messages, Limitations)는 이렇게 적는다. "Not a place for untrusted content. Do not place text from outside the conversation, such as raw tool output, retrieved documents, or web content, directly in a system message; doing so gives that text operator-level authority."
- 다른 provider 는 턴 문맥을 이미 User 끝 메시지로 보낸다.
- 턴 문맥은 턴 첫 요청 끝에 한 번 실린다(`Agent_turn.context_message`, origin `System_context`).
- 도구 라운드 뒤 요청은 대개 턴 문맥 없이 도구 결과로 끝난다. glm-5-3 Keeper 하나의 턴 마지막 요청 snapshot 127개 중 102개가 그랬다(2026-11-20~21).
- 그 메시지는 다음 요청의 입력에 남지 않는다.
  - Anthropic 레인은 응답에 서명된 thinking 이 있을 때만 그 메시지를 이력에 둔다(`Historical_system_context`, `pipeline.ml`). `clear_at` 계약 모델(`reasoning_replay = "turn_scoped_system_context_preserve_always"`)에서는 API 가 다음 요청 입력에서 그 글을 뺀다. 계약이 없는 모델은 이력 제자리에 그대로 다시 보내 쌓인다(`Preserve_positions`, `message_origin_lowering.ml`).
  - 다른 레인은 이력에 두지 않는다(`Omit_historical_system_context`, `message_origin_lowering.ml`).
  - 그래서 Agent Core 레인의 모델은 첫 도구 라운드 뒤로 턴 문맥을 못 본다. 다음 턴에는 바뀌지 않은 층도 처음부터 다시 쓴다.

같은 문서에서 이 설계에 닿는 것:
- tool_result 만 담은 user 메시지도 「다음 user 메시지」로 친다. 그래서 턴 문맥은 첫 도구 라운드 뒤 요청에서 지워진다. 입력 토큰도 0 이고 캐시 키에도 안 들어간다.
- Sonnet 5.5·Haiku 5.5 는 도구 결과 바로 뒤의 system 메시지를 믿지 못할 글로 보고 무시할 수 있다고 적는다. 도구 라운드 뒤에 다시 싣는 블록이 그 자리로 나가는지는 L5 에서 요청 캡처로 확인한다.

바꾸는 것:
- `Keeper_context_layers.layer` 마다 쓴 사람을 닫힌 variant 로 붙인다.
  - `Host_state`: 호스트가 자기 저장소에서 그린 상태.
  - `Outside_text`: 다른 Keeper, 사람, 외부 서비스, 기억 원장이 쓴 글.
- exhaustive match 로 정한다. 새 층을 더하면 컴파일러가 이 결정을 요구한다.
- Anthropic 레인에서 `Host_state` 층은 지금처럼 system 이다. `Outside_text` 층은 이번 턴 User 입력에 싣는다.

대가와 같이 정할 것:
- User 자리 글은 `clear_at` 이 없어 이력에 남는다. 다음 턴부터는 캐시로 읽힌다(0.05배).
- 그래서 `Outside_text` 층은 「한 번 도착」이어야 한다. 매 턴 같은 보기를 다시 싣는 층은 이력에 같은 글이 쌓인다.
- 층마다 둘 중 하나로 정한다.
  - 새로 온 것만 싣는다.
  - 바뀌었을 때만 다시 싣는다. 무엇을 이미 실었는지는 창 안 메시지의 `metadata` 에서 읽는다(아래 「L5 에서 정하는 것」). 실은 바이트는 이력의 그 메시지에 있어 따로 들지 않는다.
- 층마다 어느 쪽인지는 L5 설계에서 표로 정한다. Fleet 은 §4.1 과 같이 정한다.

층별 표(2026-11-20 코드 기준, 「도착 방식」은 `Keeper_context_layers.resend_on_resume` 값):

| 층 | 쓴 사람 | 바이트가 바뀌는 때 | 도착 방식 | 한도 |
|---|---|---|---|---|
| `Active_goals` | 섞임: Goal 제목·기준(운영자나 Keeper) | Goal 편집·단계 변화 | 바뀔 때 | 없음 |
| `Direct_input_source` | 섞임: 바깥 사용자 이름·채널 | 작업마다 | 바뀔 때 | 1줄 |
| `Goal_observations` | 섞임: 리뷰 메모·측정 글 | 리뷰·측정·Task claim | 바뀔 때 | 없음 |
| `Goals_awaiting_proof` | 호스트 | Verifying 에 들고 날 때 | 도착 | 없음 |
| `Current_task` | 섞임: Task 제목·앞 담당자 인계 | claim·상태·인계 | 바뀔 때 | 없음 |
| `Approval_authority` | 호스트 | 승인 저장소 revision | 바뀔 때 | 없음 |
| `Connected_surfaces` | 호스트 | 연결·살아 있음 변화 | 바뀔 때 | 없음 |
| `Namespace_state` | 호스트(제목 없음) | backlog 쓰기·도는 fiber 수(거의 매 턴) | 바뀔 때 | claim 가능 10줄 |
| `Workspace_memory` | 호스트(hash·개수만) | 원장 쓰기·도구 경로 | 바뀔 때 | 고정 크기 |
| `Wiki` | 섞임: page 제목·요약 | page 쓰기 | 바뀔 때 | 색인 전체 |
| `Lane_updates` | 호스트(id 만) | 새 lane 관측·ack | 바뀔 때 | 구독마다 1 |
| `Autonomous_trigger` | 호스트 | 매 턴 | 도착 | 3줄 이하 |
| `Scheduled_automation` | 호스트(깨움 글은 user 메시지로 간다) | 일정 변화 | 도착 | 5개 |
| `Completion_authority` | 섞임: 판정 까닭(운영자나 LLM 판정자) | 그 턴만 | 도착 | 없음 |
| `Task_cancellations` | 섞임: 취소한 이의 까닭 | 그 턴만 | 도착 | 없음 |
| `Pending_mentions` | 바깥 | 새 메시지, 답하거나 ack 할 때까지 매 턴 | 도착 | 없음, 전문 |
| `Own_board_posts` | 섞임: 이 Keeper 의 글 제목·본문 | 새 글·답글·투표 수 | 바뀔 때 | 5개, 80자 |
| `Board_activity` | 섞임, 거의 바깥(다른 Keeper·사람·connector) | 그 턴 묶음만 | 도착 | 줄 수 없음 |
| `Own_recent_actions` | 섞임: 거절된 호출 인자·도구 오류 글 | 도구를 부른 턴마다 | 바뀔 때, 줄 단위 | 10턴, 요약 8개 × 240B |
| `Recent_work` | 바깥: 최근 대화 | 거의 답할 때마다 | 바뀔 때 | 메시지 8개 + 답 1 |
| `Fleet_messages` | 바깥 | 방송이 올 때 | 바뀔 때 | 10줄 |

지금 자리(Agent Core):
- `Active_goals`·`Goals_awaiting_proof` 는 System 꼬리다(`keeper_run_prompt.ml`). 둘 중 하나가 바뀌면 그 뒤 전체를 다시 쓴다. §1.3 의 「Goal 사건 하나 131만 토큰」이 이것이다.
  - 접두사 규칙을 배포한 뒤에도 그대로다. 2026-11-20 01:35Z~14:00Z 에 같은 서버 프로세스 안에서 이어진 881턴을 셌다(#53938 「배포 뒤 측정」, 스크립트는 그 PR 의 「다시 돌리기」).
  - 앞 턴과 처음 달라진 곳이 system 의 Goal 절인 턴이 4.3% 다. 그 턴들은 첫 요청 입력의 40.2% 만 캐시에서 읽었다(토큰 가중).
  - 뒤에 덧붙기만 한 턴(60.5%)은 91.2% 를 읽었다.
- 나머지 층은 첫 요청의 턴 문맥이다. 계약을 선언한 모델(`reasoning_replay = "turn_scoped_system_context_preserve_always"`)에서는 `clear_at` system 메시지로 간다.
- Anthropic 레인은 지난 턴 문맥을 이력에 `Historical_system_context` 로 남겨 제자리에 다시 보낸다. 앞부분이 늘기만 하게 하려는 설계다(`message_origin_lowering.ml`). `clear_at` 계약 모델에서는 API 가 그 글을 입력에서 뺀다.

L5 에서 정하는 것:
- 쓴 사람: 「호스트」 층만 `Host_state` 다. 한 바이트라도 남이 쓴 글이 섞이면 `Outside_text` 다.
- 도착 방식은 새 표를 만들지 않고 `resend_on_resume` 을 쓴다. 공식 클라이언트 재개와 Agent Core User 자리가 같은 분류를 따른다.
  - 「바뀔 때」 층은 창이 이미 든 바이트면 싣지 않는다. 줄 단위 층은 창이 든 줄을 뺀다(#45131 과 같은 규칙).
  - 「도착」 층은 매번 싣는다. 그 턴에 온 것이라 이력에 같은 글이 쌓이지 않는다.
  - 예외는 `Pending_mentions` 다. 답할 때까지 같은 mention 을 매 턴 다시 그린다. User 자리로 옮기기 전에 줄 단위로 바꾸고, 창이 든 줄을 뺀다.
- 줄의 sha 는 줄 바이트의 sha 다. 그래서 사건을 담은 줄(mention, Fleet 방송)은 원본 id 를 줄 바이트에 넣는다.
  - 지금 mention 줄은 화자와 본문만 그린다. ack 커서인 `pending_message.message_id` 는 줄에 없다.
  - 그대로 줄 단위로 바꾸면, 전에 답한 mention 과 화자·글이 같은 새 mention 이 창이 든 옛 줄로 보인다. 구획이 「안 바뀜」으로 빠져 Keeper 가 새 질문을 못 본다.
  - 공식 클라이언트 재개에서 `Pending_mentions` 를 「바뀔 때」로 바꿔도 같다. `held_context` 는 그 구획이 없는 턴에도 옛 줄을 들고 가고, `held_run` 은 든 끝 줄과 지금 첫 줄을 견준다.
  - Fleet 줄(`fleet_message`)은 id 를 버린다. 원본 `Keeper_chat_store.chat_message` 의 `id` 를 넣는다.
  - 상태를 담은 줄(`Own_recent_actions`)은 지금처럼 바이트가 곧 정체다.
  - id 를 그리지 않고 견주는 key 만 id 로 바꾸는 길도 있다. 바이트는 그대로지만 같은 글의 두 mention 을 모델이 가르지 못하고, 줄 sha 규칙이 둘로 갈린다. 그래서 고르지 않는다.
  - 대가: 사건 줄마다 id 바이트가 는다.
- 「창이 든 것」은 창 안 User 메시지가 실은 구획과 줄의 sha 다. 공식 클라이언트의 `held_context`(구획·줄 sha, `Keeper_official_client_session_store`)와 같은 모양이다.
- 「창이 든 것」은 따로 저장하지 않는다. 접두사 규칙 쪽과 2026-11-20 에 맞췄다.
  - 턴 문맥을 실은 User 메시지가 자기 구획과 줄의 sha 를 메시지 `metadata` 로 든다.
  - 그 칸은 타입이 있는 접근 모듈 하나로만 쓰고 읽는다. 지금의 `Conversation_metadata` 와 같은 방식이다.
  - `metadata` 는 provider 요청에 실리지 않는다. Anthropic 직렬화(`backend_anthropic.ml`)는 이 칸을 읽지 않고, OpenAI Responses 는 자기 키(`openai.responses.phase`)만 읽는다. 그래서 sha 를 들어도 캐시에 닿는 바이트는 그대로다.
  - `metadata` 로 요청 모양이 바뀌는 곳이 하나 있다. `api_common.ml` 이 tool result 뒤 User 메시지를 합칠 때 `Conversation_metadata.is_mergeable_followup` 으로 읽는다(speaker 말고 다른 키가 있으면 안 합친다). 그 합치기는 origin 이 `Recovery_instruction`·`Tool_result_followup` 인 메시지만 본다. 턴 문맥 메시지는 그 두 origin 을 쓰지 않는다.
  - 무엇을 실을지는 투영이 창 시작을 고른 뒤 정한다. 고른 창에 든 메시지의 `metadata` 를 읽고, 창이 든 구획과 줄을 뺀다.
  - 판정은 투영이 창 시작을 고를 때마다 다시 한다. 턴에 한 번이 아니다.
    - 턴 첫 요청의 크기 신호와 checkpoint 뒤 사다리(#53817)도 투영 안에서 창을 옮긴다. 사다리는 hook 없이 투영만 다시 돌린다.
    - 판정이 턴에 한 번이면, 창을 좁힌 요청이 그 턴 끝까지 빠진 구획 없이 나간다.
  - 창이 옮겨져 그 메시지가 빠지면, 그 창을 고른 요청부터 다시 싣는다. 창 밖에 사본이 없어서 둘이 어긋날 수 없다.
  - `Keeper_model_input_ledger` 에는 칸을 더하지 않는다.
- 바깥 글 메시지는 그 턴에 그린 바깥 글 층을 다 든 채 이력에 넣는다. 「무엇을 뺄지」는 저장하지 않는다.
  - 요청마다 투영이 창을 고른 뒤 그 메시지를 줄여서 보낸다. 창 안에서 앞선 바깥 글 메시지가 이미 든 구획과 줄을 뺀다.
  - 「바뀔 때」 구획만 뺀다. 「도착」 구획은 늘 보낸다.
  - 뺀 구획은 이름만 한 줄로 남긴다. 공식 클라이언트 재개가 「바뀌지 않음」으로 이름을 적는 것과 같다.
  - 창이 같으면 같은 바이트가 나간다. 같은 턴의 다음 요청에도, 다음 턴에도 앞부분이 그대로다.
  - 창 앞이 옮겨져 든 메시지가 빠지면, 창 안에서 그 구획을 가진 가장 앞 메시지가 다시 싣는다. 창 앞이 바뀐 요청은 어차피 앞부분을 다시 쓰므로 더 잃는 것이 없다.
- 바깥 글 메시지의 origin 은 `Outside_context` 다(2026-11-21 운영자 결정, #54238).
  - 모든 request 정책이 제자리 user 글로 보낸다. 호출자 질문 경계를 열지 않고, tool 결과에 붙지 않는다.
  - 초기 system 템플릿은 호출자 글처럼 JSON 문자열로 감싼다. system 틀로 끌어올리면 맨 앞 system 이 턴마다 바뀐다.
  - Librarian 관찰·질문과 회상 질의는 내용을 뺀다. 회상한 사실이 다시 관찰이 되어 Memory 로 돌아오지 않는다.
  - `Conversation` 에 metadata 를 붙이는 길은 고르지 않는다. metadata 를 안 읽는 소비자가 바깥 글을 사람 말로 읽는다.
- 바깥 글 메시지는 그 턴 호출자 메시지 바로 앞에 둔다.
  - 그러면 호출자 메시지가 첫 요청의 마지막 대화 행으로 남는다.
  - 초기 system 템플릿이 고르는 호출자, retained 도구 결과 carrier 자리, 요청 끝 호스트 상태 메시지 자리가 지금과 같다.
- 호스트 상태(`Host_state`) 층은 지금 자리에 둔다. 턴 첫 요청 끝에 한 번이다.
- 층이 아닌 출처(`World_frame`·`Host_workspace_recall`·`Direct_turn`·`Unprojected_input`)도 쓴 사람을 정한다. `World_frame` 만 호스트다. 회상 글은 기억 원장이 쓴 글이라 바깥 글이다.
- 대가: 바깥 글이 이력에 남아 그 턴의 다음 요청마다 캐시 값으로 실린다. 지금은 턴 첫 요청에만 실린다.
  - 턴 하나의 입력 값은 지금 `O` 이고, L5 뒤로는 `w·ΔO + c·O·(1+m)` 이다.
  - `O` 는 바깥 글 크기, `ΔO` 는 그 턴에 바뀐 몫, `m` 은 첫 요청 뒤 요청 수다. `w` 와 `c` 는 캐시 쓰기와 읽기 배수다.
  - `c` 가 0.1 이고 `ΔO` 가 작으면 `m` 이 8 이하인 턴은 싸진다. `m` 이 그보다 큰 턴은 비싸진다.
  - 잰 `m` 의 p50 은 Claude 레인 2~5, glm-5-3 3, openrouter deepseek 8, ollama deepseek 13 이다(§3.6). 레인별 `c` 는 확인하지 않았다.
  - 얻는 것: 모델이 도구 라운드 뒤에도 바깥 글을 본다. 바뀌지 않은 회상·mention 을 턴마다 다시 쓰지 않는다.
- `Active_goals` 는 바깥 글이다. System 꼬리에서 빼 「바뀔 때」 규칙으로 User 자리에 싣는다. 그러면 Goal 사건이 System 을 바꾸지 않는다.
- `Goals_awaiting_proof` 는 호스트 상태지만 System 꼬리에 있다. 턴 문맥으로 옮길지 같이 정한다.

### 3.5 같은 규범 목록을 두 번 싣지 않는다

지금:
- 원장에 격리된 기록이 있으면(`Isolated_history`) masc 가 그린 System 에도 `<norms_current>` 를 늘 덧붙인다. `<norms>` 가 지금 조항으로 그려졌어도 그렇다.
- `<norms_current>` 는 현재 조항 전체와 보류 안내다. 보류 안내는 「목록에 없는 조항이 승인된 삭제가 아니다」를 알린다(#50758).

`<norms_current>` 가 필요한 때:
- System 이 옛 조항으로 그려졌다. 변경분 안내는 보류된 조항을 「되돌린 조항」으로 보이게 하므로, 전체 목록이 변경분을 대신한다.
- 어느 조항으로 그렸는지 모른다. 기록된 System 을 다시 보내는 native 이어가기와, 다른 바이트로 System 을 덮어쓴 요청이다.
- 지금 조항으로 막 그린 System 은 아니다. `<norms>` 가 현재 조항 전체이고, 지난 턴의 변경분 안내는 모델에 안 보인다. Anthropic 레인은 `clear_at` 으로 지우고, 다른 레인은 보내지 않는다.

바꾸는 것:
- `Keeper_turn_system.t` 의 현재 조항 값을 닫힌 variant 로 둔다.
  - `Not_carried`: 격리된 기록이 없다.
  - `In_text`: System 이 지금 조항으로 그려졌다. 옆에 싣지 않고 블록만 들고 있다.
  - `Beside_text`: System 뒤에 싣는다.
- `issue` 가 원장의 투영 상태를 받아 정한다. 지금 조항으로 그렸거나 변경분이 없으면 `In_text`, 변경분이 있으면 `Beside_text` 다.
- `with_bytes` 가 다른 바이트로 덮어쓰면 `In_text` 를 `Beside_text` 로 바꾼다. 덮어쓴 System 은 조항을 모르기 때문이다.
- native 이어가기는 지금처럼 늘 `Beside_text` 다.

### 3.6 회상 글은 사실 하나가 줄 하나인 바깥 글 구획이다

2026-11-21 운영자가 정했다(§6 D4).

- 회상 글은 기억 원장이 쓴 바깥 글이다(§3.4). L5 의 바깥 글 메시지에 구획 하나로 싣는다.
- 사실 하나가 줄 하나다. 줄에는 사실 id 를 넣는다. 사건 줄이 원본 id 를 넣는 것과 같은 규칙이다(§3.4).
- 「바뀔 때」 구획이다. L5 투영이 창 안 앞선 바깥 글 메시지가 든 줄을 빼므로, 고른 집합이 그대로인 동안 새로 고른 사실만 실린다.
- 이번 턴에 빠진 사실은 창 안 옛 메시지에 남는다. 그래서 빠진 사실 id 를 한 줄로 적는다.
- 창 앞이 옮겨져 든 메시지가 빠지면, 창 안에서 그 줄을 가진 가장 앞 메시지가 다시 싣는다(§3.4).
- 그러면 「앞부분은 창이 옮겨질 때만 바뀐다」를 지키는 장치가 L5 투영 하나다.

잰 것(2026-11-21, 읽기만 하는 오프라인 스크립트, 값은 개수와 분위수만):

- 회상 집합은 크고 거의 그대로다. 회상 평가 기록이 있는 Keeper 넷의 판정된 턴(2026-11-18~21, 넷 합쳐 약 90턴, 턴 번호 간격 p50 1)을 셌다.
  - 고른 사실은 Keeper 마다 p50 84~251개다. 고른 claim 글은 p50 149~304KB 다.
  - t 턴에 고른 집합 가운데 t+k 턴에도 남은 몫의 p50 은 k=1 에서 0.96~1.00, k=16 에서 0.94~0.99 다.
  - 집합이 통째로 같은 쌍은 Keeper 와 k 에 따라 0~53% 다. 두 Keeper 는 쌍의 10% 에서 집합의 77% 넘게 바뀌었다(k=1 의 p10 0.17·0.23).
- 회상 Keeper 넷은 Anthropic 이 아닌 레인에서 돌았다. 비용 원장과 맞춘 판정된 턴 73개의 첫 요청이 모두 openrouter deepseek, glm-5.3-flash, glm-5-3, openai-responses 다.
- 레인별 턴 안 요청(비용 원장의 요청 행 121,311개, 턴 11,382개, 2026-11-14~21):
  - Claude 레인: 턴당 요청 p50 3~6, p90 5~22. 첫 요청 다음 요청의 입력은 p50 84k~187k, p90 172k~258k 토큰이고 가장 큰 값이 272k 다.
  - 다른 레인: 턴당 요청 p50 2~14, p90 8~57. 첫 요청 다음 요청의 입력은 가장 큰 값이 약 106만 토큰이다.
  - 턴 첫 요청에서 캐시로 읽은 몫(토큰 가중)은 레인마다 22~79% 다.

모르는 것과 대가:
- claim 글이 몇 토큰인지는 재지 않았다. e-masc-the-leader 는 claim 이 약 300KB 인 턴에도 첫 요청의 캐시 안 닿은 입력이 p10 에서 28,726 토큰이었다. 그 턴에는 회상 글이 캐시로 읽혔다. 그래서 「회상 글 전부가 매 턴 캐시에 안 닿는다」는 레인마다 따로 본다.
- 빠진 사실의 본문이 창 안 옛 메시지에 남는다. 모델이 「빠진 id」 줄을 따르는지는 오프라인 하네스로 잰다.
- 회상 글이 이력에 남아 턴 안 다음 요청의 입력 한도도 먹는다. 턴이 가장 커지는 곳이 안쪽 요청이라 창 옮김과 턴 가운데 넘침이 늘 수 있다. 레인별로 잰다(§8).
- 회상 Keeper 가 판정된 턴에 쓴 레인의 `m` p50 은 1~8 이다. §3.4 의 대가 식이 그대로 닿는다.

## 4. 논의 중

### 4.1 Fleet 방송

- 지금은 최근 10개를 매 턴 다시 싣는다. ack 커서와 무관한 상시 보기다.
- §3.4 로 User 자리에 옮기면 「한 번 도착」이어야 한다. 그러면 오래 쉰 Keeper 가 쌓인 방송을 한 번에 받는다.
- 둘 중 무엇을 고를지는 L5 설계에서 같이 정한다.
- 제안: 「바뀔 때」 분류는 그대로 두고 줄 단위로 바꾼다. 방송 하나가 줄 하나다.
  - 창이 든 줄은 빼므로 새 방송만 실린다.
  - 줄에는 방송의 원본 id 를 넣는다. 글이 같은 새 방송이 창이 든 옛 줄로 보이지 않는다(§3.4).
  - 보기 한도 10줄도 그대로다. 오래 쉰 Keeper 도 가장 새 10개까지만 받는다. 지금 매 턴 보는 범위와 같다.
  - ack 커서는 쓰지 않는다. 받은 범위를 바꾸는 결정이라 이 RFC 밖이다.

### 4.2 상주 도구 설명의 크기

- `keeper_skill` 스키마가 22KB 다. Skill 마다 한 줄 설명을 싣는다.
- Keeper 안내문 24KB 중 8.6KB 가 지연 도구의 사용 절차다. 그 도구는 요청의 0~8% 에만 실린다.
- 줄이면 Keeper 가 Skill·도구를 덜 찾을 수 있다. 행동 평가를 먼저 한다.

## 5. 고칠 것이 없는 것

| 감사 주장 | 까닭 |
|---|---|
| 로컬 응답 캐시 키가 잘게 나뉜다 | route 단계가 응답 캐시를 넘기지 않는다. 운영에서 안 도는 경로다 |
| loader 가 없으면 지연 도구를 다 싣는다 | 그 갈래에서 지연 목록은 빈 목록이다 |
| 공식 클라이언트가 held 블록 넷을 다시 보낸다 | 넷은 이번 턴에 도착한 것이다 |
| Connected surfaces 필터와 출력이 다르다 | 필터는 절을 낼지만 정한다. 시험이 출력을 고정한다 |
| 승인별 Gate 판정이 접두사를 못 나눈다 | 원인은 키 정렬이다. Gate 가 always_allow 라 판정 호출이 0번이다 |
| Anthropic 레인이 지난 턴 문맥을 이력에 쌓는다 | `clear_at` 계약 모델에서는 API 가 입력에서 뺀다. 운영 runtime 선언에 나오는 Claude 모델 이름 60번이 모두 그 다섯 모델이다(11-20). 계약이 없는 claude-fable-5·claude-sonnet-5 를 묶으면 쌓인다 |

## 6. 운영자가 정한 것 (2026-11-20~21)

| | 정할 것 | 결정 |
|---|---|---|
| D1 | 캐시 유지 시간 | 선언으로 고르고 TUI 에 손실을 보인다(§3.1, §3.2) |
| D2 | Anthropic 도구 불러오기 | `defer_loading` + `tool_reference` 로 바꾼다(§3.3) |
| D3 | 턴 문맥의 역할 | 쓴 사람에 따라 나눠 옮긴다(§3.4) |
| D4 | 회상 본문 자리 | L5 바깥 글 구획에 사실 줄로 싣는다(§3.6, 2026-11-21) |
| D5 | 바깥 글 메시지의 origin | 새 `Outside_context` 를 더하고 PR 을 둘로 나눈다(§3.4, 2026-11-21) |

## 7. 층

| 층 | 내용 | 조건 |
|---|---|---|
| L0 | 이 RFC | |
| L1 | §3.5 규범 목록 한 번 (#53753) | |
| L2 | §3.1 catalog 계약 (#53759), 모델 행의 1시간 값 (#53779), 가격 계산 (#53780), binding `cache-retention` 선언 (#53760) | D1 |
| L3 | §3.2 요청이 고른 유지 시간 기록(L3a), provider 기본 유지 시간 선언(L3b), 캐시 결과 투영과 TUI(L3c) | D1 |
| L4 | §3.3 Anthropic 도구 불러오기 | D2, 운영자 실제 호출 확인 |
| L5 | §3.4 역할 나눔과 층별 도착 방식, 사건 줄의 원본 id, §3.6 회상 사실 줄. origin 은 #54238 | D3, D4, D5, §3.4 층별 표 리뷰 |

## 8. 검증

- L1: 격리된 기록이 있는 원장에서 지금 조항으로 그린 System 에는 `<norms_current>` 가 없다. 변경분이 있는 System, native 이어가기, 다른 바이트로 덮어쓴 System 에는 현재 조항 전체가 있다.
- L2: 설정 파서가 `"5m"`·`"1h"` 만 받는다. catalog 계약이 없는 provider 와 다른 wire 의 선언은 불러올 때 거절한다. 1시간 binding 으로 돈 턴은 응답의 `cache_creation.ephemeral_1h_input_tokens` 가 0 보다 크고, 비용 행의 캐시 쓰기 몫이 2배 값이다. 5~60분 쉰 뒤 첫 요청이 앞부분을 읽는다.
- L3: 이 RFC §1.3 의 표를 투영으로 다시 낸다. 같은 기록이면 같은 표가 나온다. 비용 행의 `cache_write_lifetime` 이 그 요청 binding 의 선언과 같다. 선언을 바꾼 앞뒤 턴은 각자의 값으로 센다.
- L4: 운영자가 실제 호출로 본다. 불러오기 직후 요청이 앞 요청의 입력을 캐시에서 읽는다.
- L5: 층마다 실린 역할을 요청 캡처로 센다. 이력에 같은 글이 두 번 쌓이지 않는다.
- L5: 답한 mention 과 화자·글이 같은 새 mention 은 새 줄로 실린다. 공식 클라이언트 재개와 Agent Core User 자리를 둘 다 본다.
- L5 전후: #53938 의 `prefix_rows_with_hits.py` 로 「앞 턴과 처음 달라진 곳」 표를 다시 낸다. system 의 Goal 절 줄(배포 뒤 4.3%, 적중 40.2%)에 `Goals_awaiting_proof` 가 바뀐 턴만 남는지 본다. 요청 끝 문맥 줄(9.6%, 84.9%)이 덧붙기만 한 줄로 옮겨 가는지 본다.
  - L5 전 기준선(2026-11-20 14:00Z~11-21 02:00Z, 같은 서버 프로세스 안 1,316턴): 덧붙기만 70.6%(첫 요청 적중 87.3%), 요청 끝 user 행 8.3%(89.4%), 앞 tool·답 행이 짧은 표지로 바뀜 7.9%(73.7%), 도구 이름 바뀜 6.5%(49.0%)다. system 의 Goal 절은 이 구간 같은 프로세스 안에서 0턴이다.
- L5 회상: 회상 Keeper 의 안 닿은 입력, 창 옮김 비율, 턴 가운데 넘침을 레인별로 전후 견준다. 「빠진 id」 줄을 모델이 따르는지 오프라인 하네스로 잰다.

## 9. 모르는 것

- GLM 캐시 유지 시간. 5분 넘어도 읽혔다는 관측만 있다.
- `tool_result` 하나에 글 블록과 `tool_reference` 블록을 섞을 수 있는지. L4 에서 실제 호출로 본다.
- 지연 도구 정의를 더하거나 빼도 캐시가 남는지. 문서는 지연 도구를 앞부분에서 뺀다고만 적는다.
- `tool_reference` 가 이력 창 밖으로 나간 뒤, 남은 과거 `tool_use` 를 API 가 어떻게 다루는지.
