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
| 턴의 `effective_budget`(`lib/keeper/keeper_context_runtime.ml:181`) | 입력과 견주지 않는다. binding max-context 와 override 가운데 작은 값이고, 턴은 lane 후보 가운데 가장 작은 값을 쓴다(`lib/keeper/keeper_unified_turn_pre_dispatch.ml:151-192`). 이벤트, OTel span, 요청·턴 기록에 실린다 | 해당 없음 |
| Librarian 레인(`lib/keeper/librarian_memory_lane.ml:58-71`, `102-112`) | masc 에서는 견주지 않는다. 창과 레인 선언의 `max_output_tokens` 를 slot 열쇠에 싣기만 한다 | HTTP slot 은 레인 선언을 그 요청의 `max_tokens` 로 싣는다(`lib/runtime/runtime_exact_output_registry.ml:684-694`). 미리 세는 slot 은 agent-core `admit` 이 빼고, 그 밖은 provider 가 자기 창으로 거절한다. CLI slot 열쇠에는 예약이 없다 |

출력 예약을 빼는 곳은 agent-core `admit` 하나다. Librarian 레인은 예약 값을 자기 선언으로 정할 뿐 빼지 않는다.

### 1.3 넘친 두 요청 (11-19, 리뷰 Keeper 하나)

- 19:29 KST(옛 빌드): 서버가 19:27 에 다시 떴고 턴 경계는 0 이었다.
  - 요청은 마지막 턴 기록(seed)의 atom 2,191 부터 191 개를 실었다. 경계가 0 이라 끝난 턴이 없다고 보였고, 끝난 턴의 결과를 표시로 바꾸지 않았다(sent prefix RFC §3.1 의 마커). 입력 529,914 로 거절됐다.
  - 그 run 은 아직 checkpoint 전이라, 거절된 요청의 tool 결과를 표시로 바꿔 한 번 더 보냈다(`current_turn_demotion_sequence`).
  - 지금은 턴 경계를 턴 기록의 마지막 단위에서 읽는다(#53461).
- 19:39 KST: §0 의 거절이다. 한 Keeper 턴 안에서 안쪽 요청이 40 번 넘게 받아들여지며 약 185,000 에서 269,780 token 까지 커졌다. 다음 요청 272,780 이 입력 한도 272,000 을 넘어 보내기 전에 거절됐다.
  - 안쪽 요청마다 checkpoint 를 셋 저장했다(`after_assistant_collected`, `after_tool_results_appended`, `after_context_injection`).
  - 그래서 같은 run 의 재시도가 닫혀 크기 거절 사다리가 돌지 않았다(§4.1). 턴은 실패했고 다음 cycle 은 그대로 돈다.

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

### 4.1 지금

- 신호는 턴 첫 요청에서, ledger 가 시작된 뒤 가장 크게 자란 턴만큼 다음 턴이 자란다고 본다. 그보다 많이 자라는 턴은 턴 가운데 넘친다(§1.3 의 19:39 KST).
- 크기 거절 사다리는 세 단이다(`lib/keeper/keeper_turn_driver_try_provider.ml:3588-3700`).
  - 턴 경계로 옮긴다(`turn_boundary_resend_sequence`).
  - 거절된 요청의 tool 결과를 표시로 바꾼다(`current_turn_demotion_sequence`).
  - 이 턴이 시작한 곳으로 옮긴다(`this_turn_start_resend_sequence`).
- 단마다 attempt 를 처음부터 다시 돌린다. 그래서 셋 모두 `same_run_retry_authorized` 가 열려 있을 때만 돈다.
  - agent-core 가 이 run 에서 checkpoint 단계에 닿으면 닫힌다(`same_run_retry_allowed`, `:844`).
  - 처음부터 다시 돌리면 이미 저장된 진행 위에 이번 턴 입력을 다시 넣는다(`lib/keeper/keeper_unified_turn_execution.ml:437`).
- 안쪽 요청은 매번 checkpoint 를 저장한다. 그래서 턴 첫 요청 뒤의 거절에는 사다리가 없다.

### 4.2 규칙

크기 거절에서는 답이 나오지 않았다.
그래서 run 안에서 더 좁은 요청을 보내도 tool 을 다시 돌리지 않고, checkpoint 도 되돌리지 않는다.

크기 거절은 둘이고, agent-core 밖으로는 둘 다 `Retry.ContextOverflow` 로 나간다.

- 보내기 전 거절: `admit` 이 입력 한도를 넘는다고 본 요청이다(`Complete.Context_window_exceeded`, `packages/agent_core/lib/pipeline/pipeline_stage_route.ml:166-171`).
- provider 거절: provider 가 넘침으로 돌려준 요청이다(`packages/agent_core/lib/provider_failure_attribution.ml:65-78`).
  - 빈 completion 으로 끝난 넘침도 여기 든다. 이때는 provider 가 입력을 읽어서 값이 매겨진다.

투영(`model_input_projection`, `packages/agent_core/lib/agent/agent_types.mli:57`)은 요청 하나 대신 후보 목록을 돌려준다.

- 첫 후보는 지금 요청이다. 창을 붙잡는다.
- 다음 후보들은 크기 거절 사다리의 단이고, 순서도 §4.1 과 같다.
  - 후보는 누적이다. 앞 단이 붙잡은 front 와 표시 바꾸기를 안고 한 단을 더 쓴다.
  - 지금 사다리도 그렇다(`turn_boundary_resend_sequence` 의 `restore_front` 조건, `this_turn_start_resend_sequence` 의 「whatever demotion [first] chose」).
  - 좁아지지 않는 단은 후보를 내지 않는다. 조건은 지금 단의 조건이다.
- 목록은 유한하다. 첫 후보 뒤의 단은 thunk 다. 목록 길이가 다시 보내는 횟수의 상한이라 따로 세지 않는다.
- route 는 후보를 차례로 견주고, 처음 받아들여진 후보를 보낸다. provider 가 그 후보를 넘침으로 거절하면 다음 후보로 간다.
- 후보가 다하면 지금처럼 `Retry.ContextOverflow` 로 턴을 끝낸다. lane 을 돌리는 것도 지금과 같다. 다음 턴 첫 요청에서 신호가 창을 옮긴다.
- 받아들여진 후보의 좁힘은 run 의 다음 요청으로 이어진다.
  - 턴 가운데 요청은 ledger 의 마지막 요청이 연 곳을 붙잡는다(`held_window`, `lib/keeper/keeper_turn_driver_try_provider.ml:1429`). ledger 는 응답 때 바뀐다(`:2770`).
  - 표시 바꾸기는 attempt 가 들고 있는 상태다(`:2108`).

agent-core 계약이 바뀐다.

- 지금: 「Route exactly once. … AGENT_CORE does not mutate the transcript or retry implicitly」(`packages/agent_core/lib/pipeline/pipeline.ml:847`).
- 바뀐 뒤: route 는 caller 가 준 후보마다 많아야 한 번 보낸다. transcript 는 바꾸지 않는다. 다시 보내는 것은 caller 가 후보로 적은 것뿐이다.
  - thunk 는 앞 후보가 크기로 거절된 뒤에만, 앞에서부터, 하나에 한 번만 부른다. thunk 가 attempt 상태를 바꾸므로, 이 순서가 깨지면 누적이 틀어진다.

run 안 후보가 checkpoint 앞뒤의 크기 거절을 모두 먼저 받는다.

- attempt 를 다시 돌리는 API 레인 사다리 셋은 지운다. 단이 attempt 상태를 바꾸는 부분(front 붙잡기, 표시 바꾸기)만 후보 thunk 로 옮긴다.
- 공식 클라이언트 런타임 둘이 부르는 `context_overflow_shrink_sequence` 는 이 RFC 가 다루지 않는다.

다른 도구는 넘치면 한 번 줄여 다시 보내고, 줄일 것이 없으면 끝낸다.

- pi: 「one compact-and-retry recovery attempt」. 그것도 실패하면 다시 보내지 않는다.
- OpenClaw: 줄여서 다시 보낸다. 그래도 안 들어가면 /reset, /new, 더 큰 창의 모델을 권한다.
- Hermes: provider 가 거절한 뒤에는 「one bounded attempt」(`max_compression_attempts`)만 다시 줄인다. https://hermes-agent.nousresearch.com/docs/developer-guide/context-compression-and-caching
  - 보내기 전에 줄일 것이 없는데 창을 넘으면 보내지 않는다. 새 세션(`/new`)을 권하며 턴을 끝낸다. https://hermes-agent.nousresearch.com/docs/user-guide/configuration

여기서는 단 수가 상한이다. 단은 모델을 부르지 않고 범위만 다시 자른다.

## 5. 층

1. agent-core: 입력 한도 타입과 만드는 함수, envelope 을 고르는 함수 하나. `admit` 과 backend 가 쓴다.
   - 시험: codec 마다 예약과 한도. `admit` 의 경계값.
2. masc 창 옮김 신호와 다음 요청 예측이 입력 한도를 받는다. sent prefix RFC §4 의 비교 대상을 바꾼다.
   - 시험: 창 400,000, 예약 128,000 에서 다음 턴 예측이 272,000 을 넘으면 신호가 켜진다.
3. 턴의 `effective_budget`. 고칠 코드는 없다. 입력과 견주는 곳이 없다(§1.2).
4. Librarian 레인. 지금 고칠 코드는 없다. Librarian RFC §6.3 의 비교를 만드는 층이 입력 한도 타입을 받는다. Librarian 담당이 한다.
5. 넘칠 때 run 안에서 후보로 좁히기(§4.2). agent-core 의 투영 타입과 route, masc 의 투영과 사다리를 고친다.
   - 시험: 턴 가운데 안쪽 요청이 입력 한도를 넘으면 같은 run 에서 다음 후보가 받아들여진다. tool 은 다시 돌지 않고 checkpoint 수도 그대로다.
   - 시험: 거절된 후보는 ledger 를 바꾸지 않는다.
   - 시험: 좁힌 뒤의 안쪽 요청은 거절 없이 첫 후보로 들어간다.
   - 시험: 받아들여진 후보 뒤의 thunk 는 불리지 않는다.
   - 시험: provider 가 넘침으로 거절하면 다음 후보를 보낸다.
   - 시험: 후보가 다하면 턴이 끝나고 lane 을 돌리는 것은 지금과 같다. 다음 턴 첫 요청에서 신호가 창을 옮긴다.

## 6. 조사할 것

- exact 경로에서 admitted target 이 받는 창과 레인 slot 열쇠의 `window` 가 같은 값에서 오는지. 같아야 Librarian RFC §6.3 의 비교가 이 RFC 의 함수를 쓸 수 있다.

## 7. 모르는 것

- 예약을 보내지 않는 provider 가 서버에서 따로 잡는 출력 몫. agent-core 가 모르니 한도는 창 그대로다. 그 provider 의 거절은 지금처럼 provider 가 한다.
