---
rfc: "a-turn-closes-at-a-typed-end"
title: "턴은 모델이 typed 로 알린 끝에서 닫힌다"
status: Draft
created: 2026-11-16
updated: 2026-11-16
author: claude
related: ["a-keeper-takes-every-waiting-message-in-one-turn", "arrived-stimuli-reach-the-running-turn", "backlog-never-preempts-a-running-turn"]
---

# RFC: 턴은 모델이 typed 로 알린 끝에서 닫힌다

11-15 code-reviewer-uncle 의 턴은 일을 18:06Z 에 마쳤다. 그 뒤 6.6시간 동안 같은 응답을 177번 냈다.
응답마다 "이 턴 종료(도구 호출 없음)" 로 시작하는 글을 쓰고 `keeper_lane_status({})` 를 불렀다.
Agent Core 는 도구 호출이 있는 응답을 다음 라운드로 보낸다. 모델은 끝내겠다고 썼지만, 그 뜻을 시스템이 받을 통로가 없었다.
그동안 그 Keeper 의 채팅 줄과 이벤트 큐는 함께 기다렸다.

이 RFC 는 끝을 알리는 도구 `keeper_turn_end` 를 Agent Core 경로에 더하자고 제안한다.
모델이 이 도구를 응답에 넣으면, 같은 응답의 다른 호출은 지금 규칙대로 처리하고 모델을 다시 부르지 않고 턴을 닫는다.

- 다루는 것: Agent Core 경로의 끝 행동, 닫은 뒤 정산, 프롬프트와 도구 설명.
- 다루지 않는 것: 공식 클라이언트 경로(§7-1), 시간·라운드 상한, 글을 읽는 판정, 도는 턴 선점.
- 근거 기준: 코드는 main `9037df00892f` 에서 읽었다.
- 측정: [`docs/evidence/repeated-tool-rounds-2026-11-16/`](../evidence/repeated-tool-rounds-2026-11-16/README.md).

## 0. 요약

- **[사실]** 11-10~16 에 한 도구를 같은 입력으로 10번 넘게 연달아 부른 실행이 41개다. 4,708 라운드, 50.7시간이다. 모두 Agent Core 실행이다(glm-5.3-flash 36개 47.7시간, kimi-k3-1-pro 5개 3.0시간).
- **[사실]** provider 가 정상 끝(`stop`)을 알려도 응답에 도구 블록이 있으면 Agent Core 는 도구 요청(`StopToolUse`)으로 바꾸고 다음 라운드를 돈다. 도구 호출을 잃지 않으려는 처리다.
- **[결정]** 턴은 모델이 typed 로 알린 끝에서 닫힌다. 글을 읽어 판정하지 않고, 시간이나 라운드 수로 끊지 않는다(운영자, 11-16).
- **[제안]** `keeper_turn_end`. 같은 응답의 다른 호출을 처리하고 결과를 저장한 뒤, 모델을 다시 부르지 않고 턴을 닫는다. 끝 행동이 없으면 지금과 같다.

## 1. 운영자 결정 (2026-11-16)

1. 턴은 모델이 typed 로 알린 끝에서 닫힌다.
2. 글을 읽어 끝을 판정하지 않는다(constitution `string_matching`). 시간이나 라운드 수로 끊지 않는다(`no_wall_clock_death`, `magic_number`, `budget_gate`).
3. 끝나지 않는 턴을 미리 알아내거나 lane 을 나누는 것보다, 모델이 끝을 알릴 통로를 주는 쪽이 싸다.

## 2. 지금 모양

### 2.1 Agent Core 턴이 끝나는 길

| 경로 | 동작 |
|---|---|
| provider 종단 응답 | `EndTurn`, `MaxTokens`, `Refusal` 등은 `Complete` 가 된다(`packages/agent_core/lib/pipeline/pipeline.ml:724`). |
| 도구 요청 | `StopToolUse` 면 도구를 실행하고 다음 라운드로 간다(`pipeline.ml:672`). |
| 정상 끝 + 도구 블록 | `finish_reason=stop` 이어도 완성된 도구 블록이 있으면 `StopToolUse` 로 바꾼다(`packages/agent_core/lib/llm_provider/stop_reason_wire.ml:51-90`). |
| 종단 도구 | `Terminal_after_success` 도구가 성공하면 `TerminalToolCompleted` 로 끝난다(`packages/agent_core/lib/agent/agent_tool_terminal_boundary.ml:40`). |
| 그 밖 | yield, 입력 대기, 오류, 운영자 중단. |

Keeper 가 쓰는 `Advanced` 루프에는 라운드 상한이 없다(`packages/agent_core/lib/agent/agent.ml:900`). 정상 무도구 응답은 글이 비어 있어도 완료로 받는다(`lib/keeper_tooling/response.ml:13-18`).

### 2.2 끝 행동으로 쓸 수 없는 기존 장치

- **종단 도구 분류.** `keeper_surface_post` 같은 종단 도구는 다른 도구와 섞인 응답을 통째로 거절한다(`packages/agent_core/lib/agent/agent_tool_batch_plan.ml:95`). 이 사건의 응답은 끝 의사와 다른 호출이 섞여 있다.
- **`Terminal_effect_settled`.** 종단 도구가 배달을 맡았다고 보고 같은 응답의 글을 공개 답에서 뺀다(`lib/server/server_routes_http_keeper_stream.ml:932`, `:1225`). 끝 행동과 같이 쓴 글이 답에서 사라진다.
- **정상 끝 정규화를 되돌리기.** 도구 블록이 있는 `stop` 을 끝으로 받으면 같은 응답의 도구 호출이 결과 없이 남는다.
- **이전 시도.** #47962 는 빈 정상 종료를 실패로 보던 `progress-required` 종료 정책과 `quiet-final` fallback 을 지웠다. 이 RFC 는 정상 무도구 종료를 그대로 둔다.

### 2.3 이 버릇을 고치지 않기로 한 이전 결정

`RFC-arrived-stimuli-reach-the-running-turn` 은 "닫는 말 + 도구 호출" 을 되풀이하는 버릇을 고치지 않는다고 정했다(§4, 그 문서의 범위). 그 문서는 도는 실행에 새 소식을 보여 주는 일만 다뤘다.
이 RFC 는 버릇을 고치지 않는다. 모델이 끝을 알릴 통로를 줄 뿐이다. 끝 행동을 부르지 않으면 같은 버릇은 그대로 남는다(§5).

## 3. 측정

### 3.1 uncle 턴

raw trace `code-reviewer-uncle/raw-traces/turn-1794762495928-88eb-000000.jsonl`.

- 처음 runtime(claude_code)은 한도로 바로 실패했고, Agent Core 의 glm-5.3-flash 로 넘어갔다.
- 일을 한 마지막 호출은 18:06:46Z 다. 그때까지 `Execute` 를 8번, `masc_schedule_note_add` 를 1번 불렀다.
- 18:11:09Z~00:44:50Z 에 응답 177개를 냈다. 간격은 평균 134초다.
  - 글 177개가 모두 "이 턴 종료" 로 시작한다. 서로 다른 글은 84가지다.
  - 호출은 모두 `keeper_lane_status({})` 다. 결과는 `probe.observed_at_unix`, `last_dispatch.at_unix` 를 빼면 모두 같다.
- raw trace 의 마지막 오류는 00:59:51Z 의 admission 대기열 시간 초과다. 턴 기록은 01:00:26Z 다.

### 3.2 같은 모양의 다른 실행

모양을 가른 것은 아래 글을 사람이 읽은 결과다. 이 RFC 의 장치는 글을 가르지 않는다.

| Keeper | 같은 입력으로 부른 도구 | 라운드 | 시간 | 그 라운드의 글 |
|---|---|---:|---:|---|
| ocaml-agent-ic | `Execute {"command":"true"}` | 175 | 6.6 | "순찰 B 종료 — … 이 턴 종료 후 자체 턴으로" |
| code-reviewer-uncle | `keeper_lane_status {}` | 177 | 6.6 | "이 턴 종료(도구 호출 없음) — …" |
| wkbl-web-leader | `masc_schedule_note_add` (같은 본문 "…이번 턴 종료…") | 62 | 1.9 | "이번 턴을 종료합니다." |
| msx-retro-mania | `keeper_capability_search {"query":"masc_dos"}` | 96 | 3.3 | "이번 턴도 복구 감지 probe 한 번만 수행한다." |
| wkbl-web-leader | `masc_keeper_delegate_status_many` (작업 하나) | 1,000 | 2.0 | 진행 보고 |
| code-reviewer-sister | `keeper_lane_status {}` | 744 | 1.4 | "레인 상태 재확인 — 살아 있으면 …, 죽어 있으면 조용히 대기할게요." |

두 모양이 보인다.

- **끝을 말하고 도구를 붙인다.** 위 세 줄이다. ocaml-agent-ic 는 아무 일도 하지 않는 `true` 를 불렀다. wkbl-web-leader 는 "이번 턴 종료" 노트를 같은 본문으로 되풀이해 썼다. 이 모양은 끝 행동이 바로 받는다.
- **바뀌기를 기다리며 같은 조회를 되풀이한다.** 아래 세 줄이다. 끝 행동이 있으면 모델은 턴을 끝내고 다음 사건을 기다릴 수 있다. 다만 기다리는 대상이 바뀔 때 Keeper 를 깨우는 사건이 있어야 한다(§7-3).

## 4. 제안

### 4.1 `keeper_turn_end`

- 인자는 없다. 끝 행동은 "이 응답으로 턴을 닫는다" 는 뜻 하나다.
- 끝 행동은 batch plan 의 도구 목록에 들어가지 않는다. 그래서 종단 도구의 "섞인 응답 거절" 규칙에 걸리지 않는다. 같은 응답에 여러 번 있어도 한 번과 같다.
- 처리 순서는 다음과 같다.
  1. 응답을 받을 때 끝 행동을 닫힌 타입으로 읽는다.
  2. 같은 응답의 다른 호출은 지금의 순서, 충돌, 승인 규칙대로 실행한다.
  3. 다른 호출의 결과와 끝 행동을 transcript, journal, checkpoint 에 남긴다(`After_tool_results_appended`, `pipeline.ml:565`).
  4. checkpoint 저장과 Keeper finalize 저장이 모두 성공하면 provider 를 다시 부르지 않고 완료를 돌려준다.
- 종료 원인은 새 typed 값이다. 정상 무도구 끝(`EndTurn`)이나 종단 도구 완료(`TerminalToolCompleted`)와 구분한다.
- 끝 행동은 실패를 덮지 않는다. 저장 실패, 효과 불명, post-effect 실패, 운영자 중단이 있으면 그 결과가 이긴다. 다른 호출의 일반 도구 실패는 실패 결과 그대로 남기고 턴은 닫는다.
- 끝 행동의 결과는 모델에게 다시 보내지 않는다.

### 4.2 닫은 뒤 정산

- **채팅 작업.** 끝 행동과 같은 응답의 글이 답이다. `Completed` 와 `Visible_reply` 로 정산한다. Agent Core 의 최종 답은 마지막 응답의 글이므로(`lib/keeper/keeper_agent_run.ml:1810`) 지금 구조와 맞는다.
  `Terminal_effect_settled` 로 옮기지 않는다. 같은 응답에 글이 없으면 지금의 빈 정상 끝과 같은 규칙을 따른다.
- **자율 턴.** `Cycle.Completed` 와 같다. 그 턴이 admit 한 행만 ACK 한다. 도는 동안 도착한 행은 다음 턴에 간다(`lib/keeper/keeper_heartbeat_loop.ml:708`).
- **재시작.** 닫힌 직후 재시작해도 같은 응답의 도구 효과를 다시 실행하지 않는다. 저장된 종단 실행은 provider 를 다시 부르지 않고 복원한다(`packages/agent_core/lib/pipeline/pipeline_execution_resume.ml:232`).
- **요청별 답.** 끝 행동은 답을 요청에 묶지 않는다. `RFC-a-keeper-takes-every-waiting-message-in-one-turn` §4.3 의 요청별 답과 따로 간다. 답이 묶이지 않은 요청은 그 RFC 대로 `No_reply_emitted` 를 남긴다.

### 4.3 프롬프트와 도구 설명

`config/prompts/keeper.md` 는 Keeper runtime 프롬프트다. constitution 과 따로 고친다.

- 턴을 끝내는 법을 한 곳에 적는다. 할 일이 없으면 도구 없이 답하거나 `keeper_turn_end` 를 낸다. 다른 호출과 함께 내도 된다.
- 기다릴 것이 있으면 같은 조회를 되풀이하지 말고 턴을 끝낸다. 결과는 사건으로 다음 턴을 깨운다(§7-3 에서 깨우는 사건을 확인한 대상만 적는다).
- `keeper.md:88` 의 "실행 레인이 실패하면 `keeper_lane_status` 로 원인을 본다" 는 새로 관측한 레인 실패를 진단할 때로 좁힌다.
- `keeper_lane_status` 설명은 이미 "Nothing here probes or changes state. Call it once after a lane error" 라고 적는다. 끝이나 대기에 쓰는 도구가 아니라는 뜻을 새 도구 설명과 맞춘다.
- 새 도구 설명에는 이름만이 아니라 언제 닫히는지, 같은 응답의 다른 호출이 어떻게 되는지, 글이 답이 되는지를 적는다.

## 5. 바뀌지 않는 것과 보장하지 않는 것

- 끝 행동이 없으면 지금과 같다. 정상 무도구 끝은 지금처럼 끝나고, 도구만 있는 응답은 다음 라운드로 간다.
- 글에 "이 턴 종료" 가 있어도 제어 흐름은 바뀌지 않는다.
- 모델이 끝 행동을 부르지 않고 도구를 계속 부르면 같은 반복은 여전히 생긴다. 이 RFC 는 끝을 받을 통로를 만들 뿐, 모든 턴이 끝난다고 보장하지 않는다. 운영자 턴 중단은 그대로 남는다.
- 도는 턴을 밖에서 끊지 않는다. 채팅 대기가 생기면 자율 턴을 끊던 hand-off 를 지운 결정(#51221)을 되살리지 않는다.

## 6. 고르지 않은 안

- **운영자 턴 중단만으로 풀기.** 지금 있는 길이고 남는다. 사람이 지켜봐야 한다.
- **실행 lane 나누기.** 나눈 lane 도 같은 이유로 끝나지 않을 수 있다.
- **턴 시작점(`seed_checkpoint`)에서 다시 돌리기.** uncle 사례에서는 틀린 처리다. 일은 끝났으니 다시 돌리면 `Execute` 8번을 또 한다.
- **진전 없는 라운드를 결정론으로 판정하기.** 읽기 전용 도구만 불렀고, 입력과 결과가 직전 라운드와 같으면 끝내는 안이다. 도구마다 읽기 전용인지, 어느 칸이 관측 시각인지 선언해야 한다. ocaml-agent-ic 의 `Execute true` 처럼 쓰기 도구로 같은 일을 되풀이하면 잡지 못한다.
- **요청별 답이 모두 묶이면 닫기.** 자율 턴에는 요청 집합이 없다. 답을 다 골랐다고 도구 정산이 끝난 것도 아니다.

## 7. 열린 질문

1. **공식 클라이언트 경로.** 네 클라이언트 모두 `dynamic_tool_result.abort_turn` 통로가 있다(`lib/runtime/runtime_official_client_tool.mli:22`).
   그러나 호출이 하나씩 들어와 "같은 응답" 경계가 없다. 지금 host stop 은 내용이 빈 응답을 만든다(`lib/keeper/keeper_official_client_host.ml:129`). 각 vendor 의 typed 중단(Codex `turn/interrupt`, Claude Code `interrupt()`, Muse `turn/cancel`)도 MASC 가 아직 부르지 않는다.
   41개 사례가 모두 Agent Core 라 첫 단계에서 뺀다. 같은 모양이 공식 클라이언트에서 관측되면 그때 정한다.
2. **끝 행동과 continuation 이 같은 응답에 있을 때.** 영수증 대기(`keeper_receipt_wait`)나 gate 보류는 같은 턴을 이어 가겠다는 뜻이라 끝과 부딪친다. 끝 행동을 교정 결과로 돌려줄지, continuation 이 끝난 뒤 모델을 부르지 않고 닫을지 정한다.
3. **기다리는 대상을 깨우는 사건.** 위임 완료는 `Delegate_completed` 가 이벤트 큐로 깨운다. 레인 회복과 도구 재등장(msx-retro-mania 의 `masc_dos`)을 깨우는 사건이 있는지는 확인하지 못했다. 없으면 프롬프트에 "턴을 끝내고 기다린다" 고 적을 수 없다.
4. `RFC-arrived-stimuli-reach-the-running-turn` §4 에 이 RFC 를 잇는 한 줄을 더한다. 그 결정을 고쳐 쓰지 않는다.

## 8. 검증

feature 시험은 constitution `testing` 에 따라 기능 단위로 쓴다. 가짜 provider 로 응답을 만든다.

1. 응답이 글, `keeper_turn_end`, 일반 도구를 함께 담는다. provider 호출은 1번, 일반 도구의 효과와 결과는 각 1번, 답 배달은 1번인지 본다. 닫힌 checkpoint 에 모든 호출 결과가 있는지 본다.
   끝 행동을 일반 도구 앞, 뒤, 가운데에 놓아도 같아야 한다(`test/test_keeper_turn_driver_accept.ml`, `packages/agent_core/test/test_agent_advanced.ml`).
2. checkpoint 나 결과 저장이 실패하거나, 효과가 불명이거나, 운영자가 중단하면 성공으로 끝나지 않는지 본다.
3. 닫힌 직후 재시작해도 일반 도구를 다시 실행하지 않는지 본다.
4. 끝 행동 없이 글과 일반 도구만 있으면 다음 라운드로 가는지, 무도구 정상 끝은 지금처럼 끝나는지 본다.
5. 글에만 "이 턴 종료" 를 넣으면 제어 흐름이 바뀌지 않는지 본다.
6. 자율 턴이 끝 행동으로 닫히면 admit 한 행만 ACK 하는지 본다(`test/test_keeper_agent_core_result_outbox.ml`).
7. `keeper_surface_post` 와 끝 행동이 같은 응답에 있으면 surface post 규칙대로 처리되고 턴이 닫히는지 본다.

시험을 틀리게 만드는 변형도 돌린다. 다음 변형마다 위 시험 중 하나가 실패해야 한다.

- 끝 분기를 지운다.
- 끝 행동에서 바로 돌아가 뒤의 도구를 잃는다.
- 정산 뒤 모델을 한 번 더 부른다.
- checkpoint 저장 전에 완료를 돌려준다.
- `Terminal_effect_settled` 로 옮겨 답을 지운다.
- admit 하지 않은 행까지 ACK 한다.
- 저장 실패를 성공으로 넘긴다.

배포 뒤에는 같은 스크립트로 반복 라운드의 실행 수와 시간을 다시 잰다. 끝 행동으로 닫힌 턴의 수도 센다.
끝 행동을 많이 불렀다는 것만으로 성공이라 하지 않는다. 반복 라운드의 시간이 줄었는지를 본다.
