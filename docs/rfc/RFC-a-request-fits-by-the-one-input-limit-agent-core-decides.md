---
rfc: "a-request-fits-by-the-one-input-limit-agent-core-decides"
title: "요청이 들어가는지는 agent-core 가 정한 입력 한도 하나로 본다"
status: Draft
created: 2026-11-19
updated: 2026-11-20
author: claude
supersedes: []
superseded_by: null
related: ["a-sent-request-prefix-changes-only-when-the-window-moves", "keeper-context-window-in-tokens"]
---

# RFC: 요청이 들어가는지는 agent-core 가 정한 입력 한도 하나로 본다

## 0. 요약

리뷰 Keeper 하나의 요청이 보내기 전에 거절된다.
입력 272,780 에 출력 예약 128,000 을 더하면 창 400,000 을 넘는다(11-19 19:39 KST).

agent-core 는 「입력 ≤ 창 − 출력 예약」으로 보낼지 정한다.
masc 는 창을 옮길지 정할 때 「입력 ≤ 창」으로 본다.
두 기준은 출력 예약만큼 어긋나고, 그 사이에서 masc 는 창을 붙잡은 채 보낸다.

이 RFC 는 입력 한도를 agent-core 의 함수 하나로 정한다.
입력과 견주는 곳은 agent-core 와 masc 모두 그 값만 받는다.
이슈 #53504.

## 1. 지금

### 1.1 agent-core 가 보낼지 정하는 기준

- `admit` 은 `input_tokens > max_context_tokens - reserved_output_tokens` 이면 거절한다(`packages/agent_core/lib/llm_provider/prepared_completion_request.ml:363-381`). 거절은 typed `ContextOverflow` 로 올라온다(`pipeline/pipeline_stage_route.ml:166-180`).
- 이 확인은 `Require_exact_fit` 이거나 모델에 serving constraint 가 있을 때만 한다(`pipeline_stage_route.ml:300-304`). 다른 요청은 provider 가 자기 한도로 거절한다.
- 창은 masc 가 넘긴 binding 의 max-context 다(`lib/runtime/runtime_adapter.ml:749-758`).
- 출력 예약은 codec 마다 같은 정책으로 정한다(`backend_openai_request.ml:265-300`).
  - 호출자가 값을 주지 않으면 보내지 않는다(`Omitted`).
  - Anthropic Messages 는 값이 꼭 있어야 한다. 그래서 모델 카탈로그의 최대 출력을 채운다(`backend_anthropic.ml:360`).
- 리뷰 Keeper 의 binding 은 `max_tokens` 를 선언하지 않는다(`runtime_schema.mli:348`).
  - 그래서 예약은 카탈로그의 최대 출력 128,000 이다(`packages/agent_core/models.toml:278-288`, 창 1,000,000 에 맞춘 값).
  - binding 이 창을 400,000 으로 잡아서 입력 한도는 272,000 이다.

### 1.2 masc 가 견주는 곳

| 곳 | 견주는 값 | 출력 예약 |
|---|---|---|
| 창 옮김 신호 `past_max_context`·`held_window`(`lib/keeper/keeper_turn_driver_try_provider.ml`, 값은 2140-2144) | binding max-context | 빼지 않는다 |
| 다음 요청 예측(`lib/keeper/keeper_next_request_forecast.ml:501`) | 같은 값을 따로 읽는다 | 빼지 않는다 |
| 턴의 `effective_budget`(`lib/keeper/keeper_context_runtime.ml:172`) | binding max-context 와 override 가운데 작은 값 | 빼지 않는다(쓰는 곳은 §6) |
| Librarian 레인(`lib/keeper/librarian_memory_lane.ml:58-71`, `102-112`) | masc 에서는 견주지 않는다. 창과 레인 선언의 `max_output_tokens` 를 slot 열쇠에 싣기만 한다 | HTTP slot 은 레인 선언을 그 요청의 `max_tokens` 로 싣는다(`lib/runtime/runtime_exact_output_registry.ml:684-694`). 미리 세는 slot 은 agent-core `admit` 이 빼고, 그 밖은 provider 가 자기 창으로 거절한다. CLI slot 열쇠에는 예약이 없다 |

출력 예약을 빼는 곳은 agent-core `admit` 하나다. Librarian 레인은 예약 값을 자기 선언으로 정할 뿐 빼지 않는다.

## 2. 규칙

### 2.1 한 문장

요청이 들어가는지는 agent-core 가 정한 입력 한도 하나로 본다.
입력 한도는 창에서 그 요청이 보낼 출력 예약을 뺀 값이다.

### 2.2 agent-core

- 입력 한도를 타입 하나로 둔다. 값은 int 지만 밖에서 만들 수 없다(private).
- 만드는 함수는 하나다. `Provider_config.t` 를 받아 창과 출력 예약을 읽는다.
  - 창은 `Provider_config.context_window` 다.
  - 출력 예약은 그 config 의 codec 이 보낼 값이다. codec 에서 envelope 을 고르는 일도 함수 하나가 하고, backend 는 그 함수가 고른 예약을 쓴다. 그래서 예약이 두 곳에서 따로 정해지지 않는다.
  - 예약을 보내지 않으면(`Omitted`) 예약은 0 이다.
- 실패는 타입으로 돌려준다: 창이 없다, 창이 0 이하다, 꼭 있어야 할 예약이 없다, 예약이 창 이상이다.
- `admit` 은 이 값과 입력을 견준다.

### 2.3 masc

- 입력과 견주는 곳은 입력 한도 타입만 받는다. 컴파일러가 빠진 곳을 짚는다.
- 창 원값은 화면 표시와 agent-core 설정에 넘길 때만 쓴다.
- 창 옮김 신호: 그 자리에 그 요청의 `provider_config` 가 이미 있다(`keeper_turn_driver_try_provider.ml:1992`). 거기서 입력 한도를 구한다.
- 다음 요청 예측: 그 runtime 의 API 선언(`Runtime_account_access.api_declaration`, 키와 header 를 뺀 config)으로 같은 함수를 부른다(`input_limit_of_runtime`). 공식 클라이언트 런타임은 §2.5 다.
- Librarian 레인: masc 에는 레인이 입력과 한도를 견주는 곳이 없어서 지울 계산도 없다.
  - Librarian RFC §6.3 이 masc 쪽 비교를 하나 둔다. 미리 세지 않는 slot 이 `usage.input_tokens + R > W(s)` 인 질문에 답하면, 답은 반영하고 카운터만 올린다. 그 비교는 입력 한도 타입을 받는다.

### 2.4 값을 모를 때

입력 한도를 못 구하면 창 옮김 신호가 없다. sent prefix RFC §4 의 「값 하나라도 모르면 신호가 없다」와 같다.
agent-core 도 그 요청을 보내지 않는다.

### 2.5 공식 클라이언트 런타임

공식 클라이언트 런타임(`Codex_app_server`·`Antigravity_cli`·`Claude_code`·`Muse_serve`·`Vibe_cli`)에는 입력 한도가 없다.
`input_limit_of_runtime` 이 `None` 을 돌려준다(`.mli` 계약: official-client owned).
그래서 그 턴의 다음 요청 예측에는 창 옮김 신호(`past_max_context`·`held_window`)가 없다. §2.4 와 같은 규칙이다.

옛 신호원 `Runtime.resolve_max_context_of_runtime_id` 는 런타임 종류를 가리지 않았다.
바인딩·provider·model 의 `max_context` 를 capability 상한으로 깎아 돌려줘서, 공식 클라이언트 턴의 다음 요청 예측에도 신호가 켜졌다.
이 RFC 를 구현하면 그 신호가 꺼진다. 공식 클라이언트 턴의 예측 동작이 바뀐다.

## 3. 고르지 않은 것

- 신호마다 예약을 따로 빼는 계산. 두 계산이 어긋나면 같은 거절이 다시 난다.
- binding `max_tokens` 로 예약을 줄이는 설정. 한도가 어디서 오는지 헷갈린다.
  - Librarian 레인의 `max_output_tokens` 는 이 설정이 아니다. 켠 레인이 꼭 적는 선언이고, 없으면 레인 값을 만들지 않는다(`Reserve_undeclared`, `lib/keeper/librarian_memory_lane.ml:107`). 요청에 실리는 예약 그 자체다.
- 비율이나 여유분 숫자(예: 「창의 80%」). 근거가 없는 숫자다.
- provider 의 거절 문장을 읽어 한도를 짐작하는 것.

다른 도구도 기준을 「창 − 예약」 하나로 둔다.

- pi: 압축 조건이 `contextTokens > contextWindow - reserveTokens` 이고, 기본 `reserveTokens` 는 16384 다. https://docs.pi.dev/latest/compaction
- OpenClaw: 「75% of the active window」와 「the window minus its compaction reserve」 가운데 작은 값에서 시작한다. https://docs.openclaw.ai/concepts/compaction

## 4. 넘칠 때

기준을 맞춰도 한 턴 안에서 커지면 넘칠 수 있다.
지금은 checkpoint 뒤에 같은 run 의 줄이기 재시도가 막힌다(`same_run_retry_authorized`).

이 절은 조사가 끝나면 채운다(§6).
다른 도구는 provider 가 넘침으로 거절하면 한 번 줄여 다시 보낸다.

- pi: 「one compact-and-retry recovery attempt」. 그것도 실패하면 다시 보내지 않는다.
- OpenClaw: 줄여서 다시 보낸다. 그래도 안 들어가면 /reset, /new, 더 큰 창의 모델을 권한다.
- Hermes: provider 가 거절한 뒤에는 「one bounded attempt」(`max_compression_attempts`)만 다시 줄인다. https://hermes-agent.nousresearch.com/docs/developer-guide/context-compression-and-caching
  - 보내기 전에 줄일 것이 없는데 창을 넘으면 보내지 않는다. 새 세션(`/new`)을 권하며 턴을 끝낸다. https://hermes-agent.nousresearch.com/docs/user-guide/configuration

## 5. 층

1. agent-core: 입력 한도 타입과 만드는 함수, envelope 을 고르는 함수 하나. `admit` 과 backend 가 쓴다.
   - 시험: codec 마다 예약과 한도. `admit` 의 경계값.
2. masc 창 옮김 신호와 다음 요청 예측이 입력 한도를 받는다. sent prefix RFC §4 의 비교 대상을 바꾼다.
   - 시험: 창 400,000, 예약 128,000 에서 다음 턴 예측이 272,000 을 넘으면 신호가 켜진다.
3. 턴의 `effective_budget` 과 그 값을 쓰는 곳. §6 결과로 정한다.
4. Librarian 레인. 지금 고칠 코드는 없다. Librarian RFC §6.3 의 비교를 만드는 층이 입력 한도 타입을 받는다. Librarian 담당이 한다.
5. 넘칠 때 한 번 줄여 다시 보내기. §4 를 채운 뒤 정한다.

## 6. 조사할 것

- `effective_budget` 이 입력 한도로 쓰이는 곳. 투영과 `keeper_unified_turn_pre_dispatch.ml:174` 의 후보 비교가 있다.
- exact 경로에서 admitted target 이 받는 창과 레인 slot 열쇠의 `window` 가 같은 값에서 오는지. 같아야 Librarian RFC §6.3 의 비교가 이 RFC 의 함수를 쓸 수 있다.
- 옛 빌드에서 19:29 KST 에 거절된 입력 529,914 가 어디서 왔는지.
- checkpoint 뒤 줄이기 재시도를 막는 조건이 지키는 것.

## 7. 모르는 것

- 예약을 보내지 않는 provider 가 서버에서 따로 잡는 출력 몫. agent-core 가 모르니 한도는 창 그대로다. 그 provider 의 거절은 지금처럼 provider 가 한다.
