---
rfc: "0507"
title: "레인을 바꿔도 지난 턴의 다른 제공자 추론이 기록 전체를 막지 않는다"
status: Draft
created: 2026-11-06
updated: 2026-11-06
author: claude
supersedes: []
superseded_by: null
related: []
---

# RFC-0507 — 레인을 바꿔도 지난 턴의 다른 제공자 추론이 기록 전체를 막지 않는다

## 0. 요약

- 11-06 에 Keeper 셋이 Claude API 레인(`claude.claude-sonnet-5-5`)으로 옮겨진 뒤 매 턴 같은 문장으로 실패한다.
  `Invalid config 'reasoning_replay': stored reasoning source is incompatible at history index N`.
- 거절된 추론은 앞선 레인의 qwen·deepseek·glm 이 남긴 것이다. 실패한 위치는 모두 이미 끝난 턴이다(§1.1).
- 원인은 admission 규칙이다. `Exclude_unselected` 는 대상이 다시 보내지 않는 외래 추론만 뺀다.
  Anthropic 방언은 `All_assistant_messages` 라서 모든 assistant 를 고른다. 그래서 기록 어디에든 외래 추론이 하나 있으면 요청 전체를 거절한다.
- 그 추론은 기록에 계속 남아 있으므로 거절도 매 턴 되풀이된다. 거절은 `InvalidConfig` 로 나가고 Keeper 는 이를 종단 `Config_mismatch` 로 읽어 다음 후보로 넘어가지 않는다.
- Anthropic 문서는 tool-use 턴 안의 thinking 만 필수로 돌려 달라고 한다. 앞선 턴의 thinking 은 생략해도 된다(§2).
- 제안:
  1. 대상 방언이 "반드시 돌려받아야 하는 범위"를 닫힌 합타입 `replay_obligation` 으로 밝힌다. Anthropic Messages 만 `Open_exchange_messages`, 나머지는 지금과 같은 `Every_selected_message` 다.
  2. `Exclude_unselected` 는 의무 범위 밖의 외래 추론을 기록된 drop 으로 빼고 보낸다. 그 메시지의 text·tool_use·tool_result 는 그대로 간다.
  3. 의무 범위 안의 외래 추론은 지금처럼 보내지 않는다. 다만 `InvalidConfig` 가 아니라 `Api (InvalidRequest { reason = Attempt_rejected })` 로 거절한다.
     "이 후보는 이 기록을 이어 갈 수 없고, 선언된 다른 후보는 이어 갈 수 있다"는 뜻이다. Keeper 는 이 거절을 이미 다음 후보로 넘기는 `Admission` 으로 다룬다.
     `Every_selected_message` 대상의 거절도 같은 사실이라 같은 타입으로 바뀐다.
- checkpoint·기록 스키마는 바꾸지 않는다. canonical history 와 추론 출처 표시는 그대로 남는다.
- 같은 증상을 다른 세션이 jeong-sik/masc#49164 로 올렸다. 그 이슈의 측정과 제안 방향은 §1.1, §4.5 에 인용한다.

## 1. 지금

### 1.1 운영 증거

`~/me/.masc/keepers/<name>.decisions.jsonl` 의 현재 파일(회전된 `.1` 제외)에서 `.error` 에 `reasoning_replay` 가 든 줄을 셌다. 2026-11-06 06:57Z 에 읽었다.

| Keeper | 실패 | 처음 | 마지막 | history index | 저장된 추론 출처 |
| --- | ---: | --- | --- | ---: | --- |
| msx-retro-mania | 104 | 04:51:37Z | 06:53:27Z | 2 | `openai_compat` `qwen3.8-flash` |
| context-reviewer | 12 | 06:07:11Z | 06:55:26Z | 199 | `glm` `glm-5.3-flash` |
| code-reviewer | 3 | 05:44:48Z | 06:51:01Z | 2 | `deepseek-v4.1-flash` |

- 대상은 셋 다 `anthropic` `claude-sonnet-5-5`, `replay_policy = All_assistant_messages` 다.
- 줄의 `terminal_reason_code` 는 `config_error` 다. roster 는 `Provider runtime error from <runtime> (config_error): provider configuration failed` 만 보였다. 이 고정 문구는 L1(같은 스택 아래층)이 지운다.
- #49164 는 같은 날 system log(`system_log_2026-11-06.jsonl`, 오류 줄 646개)를 셌다.
  - 04:51Z~06:4xZ 에 턴 106개가 이렇게 끝났다. 자율 Keeper 하나는 99턴 연속이다.
  - 저장된 추론 → 대상 쌍은 `qwen3.8-flash` → anthropic 392줄, `glm-5.3-flash` → anthropic 28줄, `deepseek-v4.1-flash` → anthropic 12줄이다.
  - 위치는 history index 2 가 404줄, 199 가 28줄이다. 10-27~11-05 system log 에는 0줄이다.
  - 실패한 턴의 시도 목록은 `[claude.claude-sonnet-5-5@rejected_before_dispatch]` 하나다. 다른 후보로 넘어가지 않았다.
- 자율 턴도 caller 질문(`User`, `Conversation`)으로 시작한다.
  - msx-retro-mania 의 실패한 raw trace(`turn-1793951007398-65be-000382.jsonl`)는 `run_started` 에 "지금은 자율 턴입니다…" prompt 를 싣는다.
  - checkpoint 를 이어 가는 턴이 아니면 Keeper 는 그 prompt 를 `New_input` 으로 넘긴다(`keeper_turn_driver_try_provider.ml:2617-2623`).
  - Agent Core 는 새 입력을 `origin = Conversation` 인 `User` 로 붙인다(`agent_input.ml:97-104`).
  - #49164 는 "예약 턴에는 `Conversation` 메시지가 없다"고 적었다. 위 코드 경로와 맞지 않는다. 그래서 이 RFC 는 caller 질문을 경계로 쓴다(§4.5).
- index 2 와 199 는 그 caller 질문 앞, 앞선 턴의 자리라고 본다. #49164 도 보낼 범위가 턴 경계 바로 앞 atom 에서 시작한다고 적었다(`first_atom=5138`, `turn_boundary=boundary:5139`). 실제 요청 본문은 저장되지 않아 직접 보지 못했다.

### 1.2 코드 경로

이 RFC 의 `file:line` 좌표는 모두 이 스택이 바꾸기 전 base `b66a03b4b93` 기준이다. L3 가 바꾼 파일에서는 L3 뒤에 줄이 옮겨진다.

- `lib/runtime/runtime_agent_context.ml:255` 가 Keeper 에이전트에 `Exclude_unselected` 를 건다(#46082).
- `packages/agent_core/lib/llm_provider/reasoning_history_projection.ml:338-345` 는 `Provider_dispatch` 에서 외래 추론이 대상의 선택 밖일 때만 받는다.
- 같은 파일 `:263` 에서 `All_assistant_messages` 는 모든 assistant 를 고른다. 그래서 Anthropic 대상에서는 외래 추론이 언제나 선택 안에 있다.
- `packages/agent_core/lib/pipeline/pipeline_stage_route.ml:34-40` 이 거절을 `Config (InvalidConfig { field = "reasoning_replay" })` 로 바꾼다. 설정은 틀린 것이 없다.
- `lib/keeper_runtime/keeper_runtime_failure_route.ml:424` 는 `Config _` 를 종단 `Config_mismatch` 로 보낸다. 같은 턴에 다음 후보로 가지 않는다.
- 같은 projection 의 `project`(`:401-413`)는 이미 호환되지 않는 추론을 `Incompatible_reasoning_source` drop 으로 빼고 직렬화한다. 실제로 막는 것은 보내기 전 admission 뿐이다.

### 1.3 앞선 결정

- #45798 은 checkpoint 를 다시 열 때와 보낼 때 호환되지 않는 추론을 기본으로 거절하게 했다. 기본 정책 `Reject_incompatible` 은 이 RFC 에서 바뀌지 않는다.
- #46082 는 MASC 가 고르는 `Exclude_unselected` 를 더했다. 이때 "대상이 고르는 추론 = 반드시 보내야 하는 추론"으로 보았다.
  `test_session_resume.ml` 의 `test_binding_source_change_respects_active_replay` 는 다음 caller 질문 뒤에도 all-history·opaque·request-tools 대상이 외래 추론을 거절한다고 단언한다.
- 이 RFC 는 그 등식을 대상별로 나눈다. 고르는 것(다시 보내면 좋은 것)과 반드시 보내야 하는 것은 Anthropic 에서 다르다.

## 2. 제공자 계약

Anthropic 문서를 2026-11-06 06:45Z 무렵 직접 읽었다.
`https://platform.claude.com/docs/en/build-with-claude/extended-thinking` 는 공통 규칙을 `https://platform.claude.com/docs/en/build-with-claude/thinking` 로 넘긴다. 인용은 뒤 문서에서 했다.

"Preserving thinking blocks" 절:

> In short:
> * **Required:** within a tool-use turn, pass thinking blocks back.
> * **Recommended:** across turns, pass everything back.
> * **Allowed:** outside tool use, omit prior turns’ thinking.

> Within the latest assistant message, the sequence of consecutive `thinking` blocks must match what the model generated in the original request: you can’t rearrange, edit, or partially drop them.

"Thinking with tool use" 절:

> **A tool-use loop is one assistant turn.** From the model’s perspective, an assistant turn ends only when Claude completes its full response, which might include multiple tool calls and results.

> In extended (manual) mode, the API additionally enforces that the final assistant turn of a thinking-enabled request starts with a thinking block. Adaptive mode relaxes this: no assistant turn needs to start with one.

"Thinking encryption" 절:

> It is only strictly necessary to send back thinking blocks when using tools with thinking. Otherwise you can omit thinking blocks from previous turns.

"Thinking block preservation by model" 절:

> A thinking block is readable only by the model that produced it and certain other models, and the API ignores or drops the blocks the target model can’t read.

이 문장들에서 MASC 가 쓰는 사실은 넷이다.

1. 끝난 턴의 thinking 은 보내지 않아도 요청이 성립한다.
2. 진행 중인 tool-use 턴 안에서는 모델이 낸 thinking 을 그대로 돌려줘야 한다.
3. MASC 의 Anthropic 요청은 `"adaptive"`, `"disabled"`, `"between_tools"` 중 하나를 보내거나 `thinking` 을 비운다(`backend_anthropic.ml:236-251`). `"enabled"` 는 Kimi 분기뿐이다(`:229`). 그래서 "마지막 assistant 가 thinking 으로 시작해야 한다"는 manual 규칙은 걸리지 않는다.
   위 Required·Allowed 규칙은 모드를 가리지 않는 "Preserving thinking blocks" 절에 있다. `disabled`·`between_tools` 에 대해서는 같은 문서가 이렇게만 더한다.
   > The entire turn runs in a single thinking mode: you can’t toggle thinking in the middle of a turn, including during the tool-use loop.

   > Pass the blocks back unchanged: a progress-update block you send back gives the model the full note it wrote, not the summary. (`between_tools`, Claude Sonnet 5.5)

   둘 다 Claude 가 낸 블록과 모드 전환에 대한 말이다. 끝난 턴의 다른 회사 추론을 빼는 일에 다른 조건을 걸지 않는다. 2026-11-06 07:50Z 무렵 같은 페이지에서 다시 읽었다.
4. qwen·deepseek·glm 의 추론에는 Anthropic 서명이 없다. Anthropic thinking 블록으로 보낼 수 없다.

## 3. 제안

### 3.1 의무 범위를 타입으로 밝힌다

`Reasoning_replay_contract` 에 대상 쪽 결정을 하나 더한다. `rotation_policy` 처럼 저장되는 추론 출처(`Reasoning_replay_contract.t`)에는 넣지 않는다. 넣으면 저장된 모든 출처의 동일성이 바뀐다.

```ocaml
type replay_obligation =
  | Every_selected_message
  (** The wire rejects or misreads a selected assistant message whose
      reasoning is missing. Every selected foreign artifact is refused. *)
  | Open_exchange_messages
  (** The wire requires reasoning only inside the exchange the latest caller
      query opened. Earlier selected reasoning may be omitted. *)
```

`Reasoning_dialect.replay_obligation : t -> replay_obligation` 는 `rotation_policy` 와 같이 방언의 typed wire 사실에서 고른다.

| `toggle_wire` | 의무 범위 | 근거 |
| --- | --- | --- |
| `Anthropic_thinking` | `Open_exchange_messages` | §2 |
| 나머지 전부(`Gemini_thinking_config` 포함) | `Every_selected_message` | 지금과 같다. 이 RFC 에서 문서를 다시 확인하지 않았다(§7) |

match 는 빠짐없이 쓴다. 새 toggle wire 는 자기 답을 적어야 컴파일된다.

### 3.2 admission 규칙

`validate_replay_continuity_for_provider_config` 의 `Exclude_unselected` 갈래만 바뀐다. 열린 교환은 지금 코드의 경계를 그대로 쓴다. 가장 최근 caller 질문(`User` + `Conversation`) 뒤의 assistant 이고, caller 질문이 하나도 없으면 모든 assistant 다(`reasoning_history_projection.ml:268-272` 의 보수 규칙).

이 경계는 `[tool_use, tool_result, 새 caller 질문]` 의 `tool_use` 를 끝난 턴으로 센다. `Tool_call_assistant_messages_latest_user_turn` 의 선택도 같은 규칙이다(`:265-272`).

Anthropic 쪽에서 이 모양을 직접 다룬 문장은 찾지 못했다. 가장 가까운 문장은 같은 페이지 "Thinking with tool use" 절의 이것이다.

> **Mid-turn conflicts degrade gracefully.** If you toggle thinking mid-turn (for example, between sending a tool call and returning its result), the API doesn’t error. Instead, it silently disables thinking for that request. To preserve model quality, the API might strip thinking blocks that would create an invalid turn structure, or disable thinking when the conversation history is incompatible with thinking being enabled.

이 문장은 thinking 설정을 턴 중간에 바꾸는 경우와 thinking 과 맞지 않는 기록에 대한 것이다. 답이 온 다른 회사 tool_use 에서 추론을 빼고 새 질문을 붙인 요청을 API 가 받는지는 문서로 확인하지 못했다(확인 필요). MASC 쪽은 그 요청이 thinking 없이 tool_use·tool_result·새 질문을 싣는다는 것만 시험으로 고정한다(§6). 서명 없는 다른 회사 추론은 어느 경계에서도 Anthropic 에 보낼 수 없으므로 이 경계를 바꾸지 않는다.

| 경계 | 의무 범위 | 외래 추론의 위치 | 지금 | 제안 |
| --- | --- | --- | --- | --- |
| `Checkpoint_restore` | 무관 | 무관 | 잠정 허용 | 같음 |
| `Provider_dispatch` | 무관 | 대상이 고르지 않음 | drop | 같음 |
| `Provider_dispatch` | `Every_selected_message` | 대상이 고름 | 거절 | 같음(거절 타입만 §3.3) |
| `Provider_dispatch` | `Open_exchange_messages` | 고르지만 열린 교환 밖 | 거절 | drop |
| `Provider_dispatch` | `Open_exchange_messages` | 열린 교환 안 | 거절 | 거절(거절 타입만 §3.3) |

- drop 은 지금 쓰는 `Source_change_admitted [{ message_index; reason = Incompatible_reasoning_source stored }]` 그대로다. 요청을 만드는 `project` 는 이미 그 블록을 뺀다(§1.2). 새 projection 코드는 없다.
- 출처가 없거나 깨진 추론(`Unbound_reasoning_artifact`, `Invalid_reasoning_source`, 역할이 틀린 추론)은 지금처럼 거절한다. 이것들은 출처를 모르는 것이지 다른 출처가 아니다.
- `Reject_incompatible`(Agent Core 기본값)은 그대로다.

### 3.3 의무 범위 거절의 타입

projection 오류에 생성자를 하나 더한다.

```ocaml
| Required_reasoning_unreadable of
    { message_index : int
    ; stored : Types.Reasoning_source.t
    ; target : Types.Reasoning_source.t
    }
```

`Exclude_unselected` 의 `Provider_dispatch` 에서 의무 범위 안의 외래 추론을 만나면 이 오류를 낸다. 두 의무 범위 모두 같다.
`Incompatible_reasoning_artifact` 는 호출자가 고른 `Reject_incompatible` 의 거절로만 남는다.

`pipeline_stage_route` 는 이 오류만 `Api (InvalidRequest { reason = Attempt_rejected; message })` 로 바꾸고, 귀속은 `of_request_validation_error ~binding` 으로 단다. 다른 거절은 지금처럼 `InvalidConfig` 다.

`Attempt_rejected` 의 문서 뜻은 "선택된 binding 이 보내기 전에 요청을 거절했다. 같은 binding 을 다시 시도해도 결과는 같고, 순서 있는 레인의 다른 binding 은 될 수 있다"(`retry.mli:10-13`)다. 그 추론을 낸 원래 생산자 후보는 그 기록을 이어 갈 수 있으므로 뜻이 맞는다.

이 변경으로 `Every_selected_message` 대상(예: DeepSeek latest-turn)이 외래 추론을 거절할 때도 Keeper 는 종단으로 멈추지 않고 다음 후보로 간다. 보내지 않는 것은 그대로다.

Keeper 쪽은 바꿀 것이 없다. 이미 exhaustive match 가 있다.

- `keeper_turn_driver.ml:1784-1795` 의 `provider_attempt_dispatch` 는 직렬화 전 `Attempt_rejected` 를 `Rejected_before_dispatch` 로 기록한다.
- `keeper_turn_driver_try_runtime.ml:115-138` 의 `attempt_rejected_should_try_next` 가 같은 턴에 다음 후보로 넘긴다.
- 실패 route 는 `Admission` 회전이다(`keeper_runtime_failure_route.mli` 의 `rotate_class`).

다음 caller 질문이 오면 그 교환은 끝난 턴이 되고, §3.2 에 따라 drop 되어 Anthropic 후보도 이어 간다.

### 3.4 관측

- dispatch 의 `Source_change_admitted drops` 는 이미 `reasoning source change admitted: boundary=provider_dispatch excluded_message_count=N` 을 남긴다.
- 직렬화 쪽 `observe` 는 drop 이유별 집계를 남긴다. 한 메시지 단위 증거는 projection 값의 `reasoning_replay_drops` 에 index 와 원래 생산자로 남는다.
- 새 로그나 카운터는 더하지 않는다.

### 3.5 바뀌지 않는 것

- 저장된 기록, checkpoint, 추론 출처 표시. canonical history 의 추론 블록은 지워지지 않는다. 같은 출처의 후보로 돌아가면 다시 보내진다.
- `Every_selected_message` 대상(GLM keep-all, DeepSeek request-tools, Responses opaque, Gemini, Kimi)의 admission.
- Anthropic 대상에서 Claude 자신이 낸 thinking 의 prefix 검사(`verify_prefix_binding`).

### 3.6 결정

1. 열린 교환의 경계는 가장 최근 caller 질문이다. 그 경계 앞에서 무엇을 빼도 되는지는 대상의 typed `replay_obligation` 이 정한다. dispatch 경계에 이번 턴 시작 index 를 넘기는 채널은 두지 않는다(§4.5).
2. 대상이 반드시 돌려받아야 하는데 읽지 못하는 외래 추론은 이 binding 의 사실이다. `Api (InvalidRequest { reason = Attempt_rejected })` 로 거절하고, Keeper 는 같은 턴에 다음 후보로 간다.
3. `Config` 는 설정이 틀렸을 때만 쓴다. 이 RFC 는 binding 마다 답이 다른 거절 하나를 `Config` 에서 꺼낸다. 남은 `reasoning_replay` 거절은 §7 에 적는다.
4. 열린 교환 안의 외래 추론은 빼지 않고 거절한다(§4.2).

## 4. 대안

### 4.1 추론 계열이 바뀌면 새 기록 경계를 연다 (채택하지 않음)

레인이 다른 추론 계열로 바뀌면 그 앞 기록을 요약이나 새 세션으로 끊는다.

- 장점: 어떤 대상에도 외래 추론이 닿지 않는다. 의무 범위를 대상별로 밝힐 필요가 없다.
- 단점: Keeper 가 앞선 턴의 text·tool_use·tool_result 를 잃는다. 헌법 failure_conditions 의 "이전 턴과 다음 턴의 기억이 이어지지 않는다"가 된다.
- 단점: 요약은 새 비결정 단계다. 레인 failover 가 잦을수록 기억이 더 많이 깎인다.
- 단점: 끊는 기준이 "계열이 바뀌었다"는 출처 비교인데, 그 비교는 이미 rotation 정책이 typed 로 한다. 같은 사실로 두 번째 결정을 만든다.

### 4.2 열린 교환에서도 외래 추론을 빼고 보낸다 (채택하지 않음)

adaptive 모드는 마지막 assistant 가 thinking 으로 시작할 필요가 없다. 그래서 API 는 이 요청도 받을 것이다(§2 의 3번). 문서는 모델을 바꿀 때 API 가 읽을 수 없는 블록을 스스로 버린다고도 한다.

- 장점: 열린 교환에서도 Anthropic 후보가 같은 턴에 이어 간다.
- 단점: 문서가 tool-use 턴 안에서 "Required" 라고 한 연속성을 버린다. 모델은 자기가 보지 못한 추론으로 고른 tool_use 를 이어받는다.
- 단점: 같은 레인의 원래 생산자 후보가 그 교환을 온전히 이어 갈 수 있는데, 그 기회를 Anthropic 후보가 먼저 지운다.
- 단점: 문서의 "ignores or drops" 는 Claude 모델끼리 서명된 블록에 대한 문장이다. 서명 없는 다른 회사 추론에 대한 약속은 아니다.
- 거절해도 다음 caller 질문에서 그 턴은 §3.2 로 풀린다. 막히는 범위는 한 턴이다.

### 4.3 `InvalidConfig` 를 종단 설정 오류로 보인다 (채택하지 않음)

`Turn_configuration_error` 는 fleet 에서 config-blocked 로 세고 "operator configuration change is required" 라고 쓴다. #32106 은 넓은 `InvalidConfig` 를 그렇게 부르지 않게 일부러 막았다. 생산자가 60곳 넘고 그중 다수는 설정 고장이 아니다. 이 거절도 설정 고장이 아니다.

### 4.4 Agent Core 오류에 새 최상위 생성자를 둔다 (채택하지 않음)

- 장점: 오류 이름만으로 "추론 때문에 못 이어 간다"를 읽는다.
- 단점: `Attempt_rejected` 가 이미 같은 결정(다음 후보로)을 typed 로 가진다. 새 생성자는 `Retry.invalid_request_reason` 를 보는 lib 파일 16곳에 같은 답을 한 번 더 적게 한다.
- 단점: 헌법은 새 상태를 durable truth 가 다칠 때만 더하라고 한다. 원인 문장은 `message` 와 projection 오류 값에 남는다.

### 4.5 이번 턴 시작 index 를 dispatch 경계로 넘긴다 (#49164 의 제안, 채택하지 않음)

#49164 와 그 설계 질문에 대한 Keeper code-reviewer-father 의 답(main `e1001bccf3a` 를 읽고 쓴 것)은 이렇게 제안했다.

- `continuity_boundary` 를 `Provider_dispatch { tools_present; turn_start : int option }` 로 넓힌다. `pipeline_stage_route.validate_replay_continuity` 가 이미 `~tools_present` 를 내려보내는 길에 얹는다.
- `admissible` 에 `message_index < turn_start ||` 를 더한다. `project` 는 이미 rotation 이 받지 않는 추론을 빼므로 검증과 전송이 같은 결정을 한다. `None` 이면 지금 규칙이다.
- 거절은 `Attempt_rejected` 로 옮기고, 열린 교환 안의 외래 추론은 계속 거절한다. `Config` 는 진짜 설정 오류에만 쓴다.

뒤의 두 가지는 이 RFC 의 §3.3, §4.2 와 같다. 다른 것은 경계 하나이고, 이 RFC 는 다음 이유로 caller 질문 경계를 고른다.

- 제안의 전제는 "예약·자율 턴에는 caller 질문이 없다"다. §1.1 의 raw trace 와 코드 경로는 반대다. 시험도 있다. `test/test_runtime_provider_auth_headers.ml` 의 `test_runtime_trimmed_reasoning_boundary` 는 실제 `Runtime_model_input_tail_window.project_from_atom` 을 지난 뒤에도 `run_blocks` 의 새 질문만 `User`·`Conversation` 으로 남는다고 단언한다("only a genuine new query supplies caller-boundary evidence"). 측정된 실패는 새 채널 없이 경계가 선다.
- `message_index < turn_start ||` 는 모든 대상 방언에 걸린다. DeepSeek request-tools·all-history, Responses opaque, Gemini 는 끝난 턴의 추론을 빼도 된다는 문서를 이 RFC 가 읽지 않았다(§7). 이 RFC 는 빼는 범위를 문서가 허락한 wire 로 좁힌다(`replay_obligation`).
- `turn_start` 는 Keeper 의 atom 위치다. Agent Core 의 `effective_messages` index 는 tail window preamble, working state, unread 첨부를 지나며 달라진다. 호출자가 그 번역을 맞게 해야 하고, 한 경계에 진실이 둘 생긴다.
- 남는 틈: checkpoint 를 이어 가는 턴(`Continue_from_checkpoint`)에서 window 가 그 턴의 caller 질문을 잘라 내면 경계가 없다. 그때는 기록 전체를 열린 교환으로 보고 `Attempt_rejected` 로 다음 후보에 넘긴다. 멈추지 않는다. 이 경우가 측정되면 그때 제안된 typed 필드(`turn_start`)를 더한다.

## 5. 장단점

- 장점: 레인을 바꾼 Keeper 가 다음 턴부터 그 레인에서 돈다. 앞선 턴의 대화와 도구 결과를 그대로 본다.
- 장점: 의무 범위 거절이 같은 턴에 다음 후보로 넘어간다. 지금은 종단으로 멈춘다.
- 장점: 결정은 타입 둘(`replay_obligation`, 새 projection 오류)과 match 로 끝난다. 문자열 비교나 숫자 비교가 없다.
- 단점: `Exclude_unselected` 를 쓰는 다른 호출자도 이 거절을 `InvalidConfig` 대신 `Attempt_rejected` 로 받는다. MASC 안에서는 `runtime_agent_context.ml` 한 곳이다.
- 단점: Anthropic 후보는 끝난 턴의 외래 추론을 못 본다. 문서상 "Recommended" 인 맥락이 줄어든다. 다만 그 추론은 지금도 직렬화에서 빠진다(§1.2). 줄어드는 것은 이미 보내지 않던 것이다.
- 단점: `Every_selected_message` 대상은 여전히 끝난 턴의 외래 추론으로 막힐 수 있다. 각 대상의 문서를 확인한 뒤 한 줄씩 옮긴다(§7).

## 6. 층

| 층 | 내용 | 확인 |
| --- | --- | --- |
| L1 | roster 실패가 `InvalidConfig` 의 field 이름을 고정 문구 뒤에 싣는다. detail 은 #32106 대로 가린다. 분류는 비종단 그대로다 | `test_keeper_turn_disposition` |
| L2 | 이 RFC | 문서 |
| L3 | `replay_obligation`, admission 규칙, `Required_reasoning_unreadable`, `Attempt_rejected` 변환 | Agent Core `test_session_resume`: 끝난 턴에 qwen·deepseek·glm 추론이 남은 기록으로 Anthropic 요청이 나간다. 열린 교환의 외래 추론은 transport 전에 `Attempt_rejected` 로 거절된다 |

### 6.1 변형과 그것을 잡아야 할 시험

아래 변형은 이 스택의 마지막 head 에서 돌리지 않았다. 빌드와 시험은 사용자가 돌린다. 각 줄은 "되돌릴 코드 → 실패해야 할 시험"이다.
시험 이름은 Alcotest 시험 이름이다. `resume` 은 `packages/agent_core/test/test_session_resume.exe`, `replay` 는 `packages/agent_core/test/test_provider_agnostic_reasoning_replay.exe`, `disposition` 은 `test/test_keeper_turn_disposition.exe`, `auth` 는 `test/test_runtime_provider_auth_headers.exe` 다.

표는 독립 리뷰가 코드를 읽어 짝지은 것에, 이 스택이 그 뒤에 더한 시험을 적은 것이다. 앞선 head 에서 몇 개를 돌린 기록은 L3 PR 본문에 있다.

| # | 되돌릴 코드 | 실패해야 할 시험 |
| --- | --- | --- |
| 1 | `Reasoning_history_projection.validate_replay_continuity_for_provider_config` 의 `Exclude_unselected` admission 에서 `required` 를 `selected` 로 | resume "source-change exclusion protects active replay and control boundaries"(새 질문 뒤 drop `[1]`), "Anthropic sends finished turns other providers produced", "Anthropic sends an answered tool call before a new query" |
| 2 | 같은 함수 `required` 의 `None -> true` 를 `false` 로 | resume "source-change exclusion protects active replay and control boundaries"(caller 질문 없는 기록 줄) |
| 3 | 같은 `required` 의 `message_index > user_message_index` 를 `>=` 로 | 못 잡는다. caller 질문 자리는 `User` 라 추론이 없으므로 동치 변형이다 |
| 4 | `Reasoning_dialect.replay_obligation` 의 `Anthropic_thinking` 을 `Every_selected_message` 로 | replay "replay obligation declared per dialect", 그리고 1번의 resume 시험들 |
| 5 | 같은 함수에서 다른 wire 하나를 `Open_exchange_messages` 로 | replay "replay obligation declared per dialect" 가 그 시험의 config 7개가 닿는 wire 만 잡는다. 어느 `toggle_wire` 에 닿는지는 확인하지 않았다 |
| 6 | admission 거절 생성자를 `Required_reasoning_unreadable` 에서 `Incompatible_reasoning_artifact` 로 | resume "source-change exclusion protects active replay and control boundaries", 그리고 `Attempt_rejected` 를 기대하는 시험 넷(7번) |
| 7 | `Pipeline_stage_route.validate_replay_continuity` 의 `Required_reasoning_unreadable` 갈래를 지워 `InvalidConfig` 로 | resume "explicit provider/model failover preserves canonical history and tool effects", "source-change admission follows actual tools and hook suppression in both dispatch modes", "Anthropic refuses an open exchange another provider produced", auth "trimmed caller boundaries protect resumed and fresh tool exchanges" |
| 8 | `Incompatible_reasoning_artifact` 도 `Attempt_rejected` 갈래에 넣기 | resume "hook cannot silently re-enable incompatible replay" |
| 9 | `Checkpoint_restore` 도 `not (required …)` 로 | resume "Anthropic refuses an open exchange another provider produced"(resume 이 먼저 실패해서 잡는다) |
| 10 | `Reasoning_history_projection.error_to_string` 의 `Required_reasoning_unreadable` 에서 차원 하나를 빼거나 뒤집기, stored·target 바꾸기, 생성 때 `target = stored` | resume "source-change exclusion protects active replay and control boundaries" 의 endpoint 문장 단언, "the refusal carries the stored producer", "the refusal carries the target that cannot read it", "the refusal names the provider change from stored to target" |
| 11 | 새 갈래에서 `notify_attribution` 을 빼거나 `of_request_validation_error ~binding` 을 `of_provider_configuration_error` 로 | resume "Anthropic refuses an open exchange another provider produced" 의 `continue_detailed` 귀속 단언(`Request_validation`, `binding = Some _`) |
| 12 | L1 `Keeper_unified_turn_types.registry_failure_reason_of_terminal_reason` 의 `InvalidConfig` 갈래를 고정 문구로 되돌리거나 detail 을 싣기 | disposition "typed configuration error stays typed"(field 문구, `secret` 이 요약에 없음, marker 모양 field) |

10번의 stored·target 단언 셋과 11번의 귀속 단언, "Anthropic sends an answered tool call before a new query" 는 독립 리뷰 뒤에 더한 시험이다. 리뷰 때는 10번의 stored·target 바꾸기와 11번을 아무 시험도 잡지 못했다.

## 7. 남은 질문

- Gemini `thoughtSignature` 는 현재 턴만 검증한다는 문서가 있는지 확인하지 않았다. 확인되면 `Gemini_thinking_config` 도 `Open_exchange_messages` 로 옮긴다.
- DeepSeek(request-tools, all-history)는 지난 tool-call 턴의 `reasoning_content` 를 계속 요구하는지 이 RFC 에서 다시 확인하지 않았다. `Every_selected_message` 로 둔다.
- Responses opaque state 와 GLM keep-all 도 같다.
- 운영 Keeper 셋이 L3 배포 뒤 실제로 도는지는 배포 뒤 decisions.jsonl 로 본다. 이 스택은 서버를 다시 띄우지 않는다.
- 남은 `reasoning_replay` 거절은 이 RFC 에서 `InvalidConfig` 로 둔다.
  - `Invalid_reasoning_target` 은 대상 방언을 풀지 못한 것이라 설정 오류가 맞다.
  - `Unbound_reasoning_artifact`, `Invalid_reasoning_source`, `Reasoning_source_on_non_assistant`, `Invalid_reasoning_artifact_role`, `Invalid_response_replay`, `Unsupported_reasoning_block`, `Invalid_control_lowering` 은 기록의 출처나 모양이 깨진 것이다. 어느 후보도 받지 않으니 `Attempt_rejected` 로 옮기면 모든 후보를 헛돈다. 그렇다고 설정 오류도 아니다. 기록 무결성 오류의 자리는 따로 정한다.
  - `Incompatible_reasoning_artifact` 는 호출자가 고른 `Reject_incompatible` 의 거절이다. MASC 는 이 정책을 쓰지 않는다.
