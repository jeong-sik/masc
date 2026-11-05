---
rfc: "0491"
title: "System 은 범위 앞부분이 움직일 때만 다시 만들고, 그 사이 바뀐 세계 상태는 끝 문맥으로 보낸다"
status: Draft
created: 2026-11-05
updated: 2026-11-06
author: claude
supersedes: []
superseded_by: null
related: ["0442", "goal-observations-leave-the-system-prompt", "0488"]
---

# RFC-0491: System 은 범위 앞부분이 움직일 때만 다시 만든다

- 날짜는 UTC 다.
- 코드는 `origin/main` `6d2e30248b7` 기준이다.

## 0. 요약

에이전트 코어로 도는 Keeper 요청은 System, 대화 기록, 끝 문맥 순서로 간다. System 이 바뀐 턴의 첫 요청은 대화 기록까지 캐시를 놓친다. 11-05 에 System 만 바뀐 턴의 첫 요청 미적중률은 74.4~98.6% 였고, 아무 블록도 바뀌지 않은 턴은 33.0% 였다(§1.2). provider 문서는 이 규칙을 적지 않는다(§1.4).

2026-11-05 00:00~11:00Z 에 턴 첫 요청이 놓친 토큰의 25.1% 가 System 이 바뀐 턴에서 나왔다(§1). 바뀐 블록은 셋이다.

- `keeper_instructions`: 세계 조항(RFC-0442)이 하나 붙을 때마다 모든 Keeper 의 System 이 바뀐다.
- `completion_authority`: 이번 턴의 Task 승인·거절 관측이 System 끝에 붙었다가 다음 턴에 빠진다.
- `active_goals`: Goal 이 생기거나 고쳐지거나 단계가 바뀐다.

그런데 System 이 바뀐 쌍의 대부분은 요청 범위의 앞부분(`model_input_front`)이 그대로였다. 앞부분이 움직이는 턴은 어차피 대화 기록 캐시가 깨진다. 이 RFC 는 System 을 그때만 다시 만든다.

결정은 셋이다.

1. `Completion_authority` 는 System 에 붙이지 않는다. 그 턴의 끝 문맥 블록으로 보내고, 같은 턴의 뒤 round 에도 다시 싣는다(§3.1).
2. 조항이 바뀌어도 System 은 그 Keeper 가 마지막으로 보낸 조항으로 렌더한다. 그 뒤 바뀐 조항은 끝 문맥 layer `Constitution_amendments` 로 보낸다. 범위 앞부분이 움직이면 System 을 지금 조항으로 다시 만든다(§3.2).
3. `Active_goals` 도 2 와 같은 규칙을 따른다. 2 를 배포한 뒤 다시 재고 층을 연다(§3.3).

## 1. 측정

### 1.1 방법

- 턴 기록 `<base-path>/.masc/keepers/<name>/turn-records/YYYY-MM/DD.jsonl` 의 `blocks` 는 System 블록마다 `bytes` 와 `digest` 를 남긴다. 같은 Keeper 의 연속한 두 턴에서 digest 가 다른 블록을 "바뀐 블록"으로 본다.
- 같은 두 턴의 `model_input_front`(`kind`, `digest`)가 다르면 "앞부분이 움직였다"고 본다.
- 비용 원장 `<base-path>/.masc/costs/YYYY-MM/DD.jsonl` 의 `usage_scope = per_request` 행에서 `(agent, trace_id, keeper_turn_id)` 마다 가장 이른 행을 그 턴의 첫 요청으로 본다. `keeper_turn_id` 는 턴 기록의 `absolute_turn` 이다. 뒤 턴 첫 요청의 `cache_miss_input_tokens` 를 바뀐 블록 조합에 더한다.
- 원장 행과 이어지는 쌍만 토큰을 센다. official client Keeper 는 `per_request` 행이 없어서 빠진다.

### 1.2 결과

11-05 00:00~11:00Z. 턴 쌍 1,532개, 그중 원장과 이어진 쌍 479개. 이어진 쌍의 첫 요청 미적중 토큰은 105,280,801개다.

| 바뀐 System 블록 | 앞부분 | 쌍 | 이어진 쌍 | 첫 요청 미적중 토큰 | 몫 | 미적중률 |
|---|---|---|---|---|---|---|
| `keeper_instructions` | 그대로 | 42 | 35 | 14,523,399 | 13.8% | 96.5% |
| `completion_authority` | 그대로 | 31 | 14 | 8,089,197 | 7.7% | 74.4% |
| `active_goals` | 그대로 | 14 | 7 | 2,761,337 | 2.6% | 96.9% |
| `keeper_instructions` + `completion_authority` | 그대로 | 2 | 1 | 723,499 | 0.7% | 98.6% |
| 위 블록 중 하나 이상 | 움직임 | 10 | 3 | 293,705 | 0.3% | 87.9% |
| 없음 | 그대로 | 1,274 | 379 | 72,931,741 | 69.3% | 33.0% |
| 없음 | 움직임 | 159 | 40 | 5,957,923 | 5.7% | 82.8% |

11-04 하루. 턴 쌍 3,283개, 이어진 쌍 892개, 첫 요청 미적중 토큰 122,370,214개.

| 바뀐 System 블록 | 앞부분 | 쌍 | 이어진 쌍 | 첫 요청 미적중 토큰 | 몫 |
|---|---|---|---|---|---|
| `active_goals` | 그대로 | 55 | 39 | 7,320,410 | 6.0% |
| `keeper_instructions` | 그대로 | 44 | 22 | 7,863,772 | 6.4% |
| `completion_authority` | 그대로 | 36 | 27 | 8,817,598 | 7.2% |
| 위 블록 중 하나 이상 | 움직임 | 44 | 15 | 1,206,293 | 1.0% |

앞부분이 그대로인데 System 이 바뀐 쌍의 몫은 11-05 24.8%, 11-04 19.6% 다. 이 RFC 가 없애려는 몫이 이것이다. 앞부분이 움직인 턴은 System 과 상관없이 미적중률이 80% 를 넘는다.

### 1.3 `keeper_instructions` 가 바뀐 이유

연속한 두 턴의 `keeper_instructions` 바이트 차이로 원인을 가른다. 조항 하나가 붙으면 그 조항 길이만큼 늘고, 모든 Keeper 가 다음 턴에 같은 차이를 보인다.

| 날짜 | 차이 | 쌍 | 원인 |
|---|---|---|---|
| 11-05 | +318 | 24 | 07:40Z 조항 추가 |
| 11-05 | +320 | 24 | 08:41Z 조항 추가 |
| 11-05 | +377 | 2 | 11-04 23:49Z 조항 추가 |
| 11-05 | −2,195 | 1 | pr-updater 지시문 수정 |
| 11-04 | +480 | 24 | 18:04Z 조항 추가 |
| 11-04 | +377 | 10 | 23:49Z 조항 추가 |
| 11-04 | −3,006 | 24 | 모든 Keeper 가 같이 바뀜. 배포의 `config/prompts/keeper.md` 수정으로 본다(확인 필요) |
| 11-04 | −2,526 | 1 | Keeper 한 명의 지시문 수정 |

조항 원장(`<base-path>/.masc/constitution/articles.jsonl`)은 10-08~11-05 사이 하루 0~7번 바뀌었다. 지금 조항은 34개, 본문은 9,373B 다.

### 1.4 provider 문서

2026-11-06 에 읽었다. 측정 기간(11-05 00:00~11:00Z)의 `per_request` 행은 9,148개다. 미적중 토큰은 opencode Go `deepseek-v4.1-flash` 가 44.4%, GLM `glm-5.3-flash` 가 38.1%, `glm-5.3` 이 10.9%, 나머지 opencode Go 모델이 6.6% 다.

- Z.AI 문서는 캐시가 요청의 어느 자리를 맞추는지 말하지 않는다(https://docs.z.ai/guides/capabilities/cache).
  - "Context caching works by computing input message content and identifying content that is identical or highly similar to previous requests."
  - "Minor formatting differences may affect cache effectiveness."
  - 캐시는 설정 없이 걸린다. "Caching is automatically triggered based on content similarity, no manual configuration required"
- opencode Go 문서는 캐시 규칙을 적지 않는다(https://opencode.ai/docs/go). 적힌 것은 `Cached Read`·`Cached Write` 가격과 다음 한 문장이다. "Send a stable session ID in `x-opencode-session` for each conversation so we can optimize routing and prompt caching."
- OpenAI 문서는 앞부분 규칙을 적는다(https://developers.openai.com/api/docs/guides/prompt-caching). "Cache reuse requires the entire rendered prefix to match. If content or a relevant setting changes before a breakpoint, the prefix after that change cannot match the existing cache entry." 측정한 행에 OpenAI 요청은 없다.

그래서 GLM·opencode Go 에서 System 이 바뀌면 뒤 대화 기록의 캐시도 놓친다는 것은 문서가 아니라 §1.2 측정으로 본다.

## 2. 지금 코드

- System 은 턴마다 `Keeper_run_context.prepare_run_context` 가 새로 만든다. `Keeper_unified_prompt.build_system_prompt` 가 Keeper 지시문과 `World_constitution_store.load_articles` 로 읽은 조항(`World_constitution_render.articles`)을 넣는다(`lib/keeper/keeper_unified_prompt.ml:1195-1198`).
- `Keeper_run_prompt.assemble_request_context` 가 dynamic context partition 에서 `Active_goals`·`Completion_authority` layer 를 떼어 System 끝에 붙인다(`lib/keeper/keeper_run_prompt.ml:39-74`, `Keeper_context_assembly.with_system_observations`).
- 끝 문맥은 요청 끝의 `[system context]` User 메시지다. Anthropic 이 아닌 provider 에서는 그 요청에만 실리고 대화 기록에 남지 않는다(`packages/agent_core/lib/agent/agent_turn.ml:44` `context_message`). 그래서 끝 문맥이 바뀌어도 그 앞의 캐시는 깨지지 않는다.
- 같은 턴의 뒤 round 는 `Dynamic_context` 를 다시 싣지 않는다(`lib/types/prompt_block_id.ml:97` `injected_on_post_tool_round`). #45853 이 `Completion_authority` 를 System 에 넣은 이유가 이것이다. 뒤 round 에서 승인·거절 관측이 사라졌다. System 관측값은 뒤 round 에서 앞 assembly 의 것을 그대로 쓴다.
- `Prompt_block_id.Completion_authority` 와 `Active_goals` 는 이미 뒤 round 에도 싣는 블록 id 다(같은 함수의 `true` 갈래).
- `Keeper_carried_front` 는 (Keeper, runtime) 마다 마지막 요청의 앞부분을 프로세스 메모리에 든다. 없으면 가장 최근 턴 기록에서 읽는다(`lib/keeper/keeper_carried_front.mli:16-25`).

## 3. 결정

### 3.1 `Completion_authority` 는 끝 문맥 블록이다

- 첫 round: `assemble_request_context` 가 partition 에서 `Completion_authority` layer 를 떼어 `Prompt_block_id.Completion_authority` 블록으로 둔다. System 에는 붙이지 않는다.
- 뒤 round: 앞 assembly 의 `Completion_authority` 블록을 그대로 다시 싣는다. #45853 이 지킨 "같은 턴의 뒤 요청도 그 관측을 본다"는 그대로다.
- `Keeper_context_assembly.system_observation` 에서 `Completion_authority` 생성자를 지운다.
- official client 가 이 관측을 받는 자리는 그대로다. Start 에서는 Start prompt 앞, Resume 에서는 매번 User 다(#45853). 바뀌는 것은 떼어 내는 곳이다.
  - official client 는 System 역할 carrier 를 vendor 가 세션 내내 쥐는 System 에 넣는다. Claude Code 는 첫 실행 때 기록한 `--system-prompt` 를, Codex 는 `developerInstructions` 를 계속 쓴다.
  - 그 carrier 에 authority 블록이 남으면 판정이 그 턴을 넘어 남는다. #45853 이 막은 결함이다.
  - 그래서 official turn 은 `prepare_turn` 에서 carrier 의 authority 블록을 한 번 떼어 낸다(`Keeper_context_assembly.split_block`). 나머지 carrier 와 조립은 그 블록 없이 다시 만든 것이다.
  - 떼어 낸 블록의 출처 증명은 원래 carrier 의 그 블록 span 이다. 지금은 issued System 의 span 이다.
  - 표시 머리는 `USER:` 에서 `SYSTEM:` 으로 바뀐다. Resume 이 carrier 블록에 붙이는 머리와 같다.

관측이 있는 턴은 요청마다 블록 바이트(11-05 평균 2,285B, 11-04 평균 817B)를 캐시 없이 보낸다. 지금은 블록이 생긴 턴과 빠진 턴의 첫 요청이 대화 기록 전체를 다시 읽는다.

### 3.2 조항은 System 을 만든 때의 것을 쓴다

Keeper 마다 세 값을 프로세스 메모리에 든다. System 을 만들 때 쓴 조항 목록, 그 System 의 digest, 그때의 범위 앞부분이다. 턴의 System 은 이렇게 고른다.

| 조건 | System | 끝 문맥 `Constitution_amendments` |
|---|---|---|
| 범위 앞부분이 든 것과 같고, 든 조항으로 렌더한 System 의 digest 가 든 digest 와 같다 | 든 조항으로 렌더한 것 | 지금 조항과 든 조항의 차이 |
| 그 밖: 앞부분이 다르다, 지시문이나 `keeper.md` 가 바뀌었다, 든 값이 없다 | 지금 조항으로 렌더하고 세 값을 새로 든다 | 없음 |

- 둘째 줄의 지시문 수정은 그 턴에 바로 반영된다. 그 턴은 어차피 System 바이트가 달라져 캐시가 깨지므로, 조항도 지금 것으로 맞춘다.
- 차이는 조항 id 로 낸다. 추가된 조항은 id 와 본문을, 지운 조항은 id 를 적는다. 본문은 `World_constitution_render` 와 같은 escape 를 거친다.
- 범위 앞부분은 이번 요청이 쓸 값이다. `Keeper_turn_driver_try_provider.choose_range_start` 가 정하고, `Keeper_next_request_forecast` 도 같은 함수로 미리 구한다. System 을 고르는 자리도 이 값을 쓴다.
- 든 값은 저장하지 않는다. 조항 원장과 Keeper 지시문이 SSOT 이고, 든 값은 그 투영이다. 서버가 다시 뜨면 첫 턴은 지금 조항으로 만든다. 그 사이 조항이 바뀌었으면 그 턴 한 번 캐시가 깨진다.

`Constitution_amendments` 는 끝 문맥이라 System 보다 뒤에 읽힌다. 뒤에 온 글이 지금 상태로 읽힌다는 것은 RFC-0366 이 운영자 메모를 맨 뒤에 둔 근거와 같다(`lib/keeper/keeper_run_tools_hooks.ml` `Operator_note` 주석). 끝 문맥은 런타임이 조립하는 `[system context]` 다. 모델이 쓴 글은 조항 본문뿐이고, 그 본문은 System 에서와 같은 escape 를 거친다.

### 3.3 `Active_goals` 는 같은 규칙을 따른다

- System 의 `Active_goals` 관측도 "만들 때 쓴 Goal 목록"으로 렌더하고, 그 뒤 바뀐 Goal 은 끝 문맥 layer 로 보낸다. 범위 앞부분이 움직이면 지금 목록으로 다시 만든다.
- Goal 하나의 렌더는 조항보다 크다(11-05 `active_goals` 평균 31,799B). 차이 layer 가 매 요청 커질 수 있으므로, 3.2 를 배포한 뒤 같은 방법으로 다시 재고 층을 연다.

## 4. 검토한 대안

- **조항을 System 에서 빼서 매 요청 끝 문맥으로 보낸다.** 하지 않는다. 11-04 `per_request` 요청은 15,030건이다. 조항 본문 9,373B 가 요청마다 캐시 없이 나간다. 조항이 바뀌어서 놓친 토큰(§1.2)보다 크다.
- **조항을 대화 기록에 덧붙인다.** 하지 않는다. 기록은 agent_core 의 checkpoint 가 소유하고 Librarian 이 읽는다. 런타임이 만든 조항이 기록 atom 이 되면 같은 사실이 조항 원장과 기록 두 곳에 생긴다.
- **조항 원장 쓰기를 모아서 늦춘다.** 하지 않는다. 원장은 일어난 일을 적는 곳이다. 쓰기를 늦추는 장치는 행동을 통제하는 gate 가 된다.
- **System 기준점을 턴 기록에 저장한다.** 하지 않는다. 턴 기록에 새 필드가 생기고, 그 필드 없이도 durable truth 는 손상되지 않는다. 프로세스 메모리로 충분하다. 재시작 뒤 한 번 깨지는 비용은 §5 에 적는다.
- **provider 캐시 breakpoint 로 System 을 따로 캐시한다.** 해당 없다. Z.AI 문서는 캐시가 설정 없이 걸린다고 쓰고, opencode Go 문서에는 breakpoint 가 없다(§1.4).

## 5. 영향

- 조항이 바뀐 뒤 범위 앞부분이 움직일 때까지, Keeper 는 System 의 옛 조항과 끝 문맥의 차이를 함께 읽는다. 11-05 범위 앞부분은 턴 쌍의 11.0% 에서 움직였다. 평균 9턴쯤 뒤에 System 이 지금 조항으로 다시 만들어진다.
- 끝 문맥은 요청마다 차이 바이트만큼 커진다. 조항 하나는 300~500B 다.
- 서버 재시작 뒤 첫 턴은 지금 조항으로 만든다. 직전 System 을 만든 뒤 조항이 바뀌었으면 그 턴의 첫 요청이 기록 전체를 다시 읽는다. 지금은 조항이 바뀔 때마다 모든 Keeper 가 그렇다.
- official client Keeper 는 §3.1 의 authority 를 지금과 같은 자리에서 받는다. §3.2·§3.3 의 System 기준점은 에이전트 코어 경로만 바꾼다. official client 는 vendor 세션이 System 을 따로 쥔다.

## 6. 검증

- 시험: `assemble_request_context` 가 `Completion_authority` 를 System 이 아닌 블록으로 내고, 뒤 round 에도 같은 블록을 싣는다. official Start 의 System 과 carrier 에는 그 블록이 없고, Start prompt 앞과 Resume 마다 carrier span 증명과 함께 실린다. 조항이 바뀐 턴에서 범위 앞부분이 같으면 System 바이트가 같고 차이 layer 가 생긴다. 앞부분이 다르면 System 이 지금 조항을 담고 차이 layer 가 없다. 지시문이 바뀌면 System 이 바로 바뀐다.
- 배포 뒤: §1.1 과 같은 방법으로 "앞부분 그대로, System 바뀜" 쌍과 그 몫을 다시 센다. 기대값은 `completion_authority` 쌍 0, 조항 추가로 바뀐 `keeper_instructions` 쌍 0 이다. 지시문 수정과 배포로 바뀐 쌍은 남는다.

## 7. 층

1. 이 문서.
2. §3.1 `Completion_authority` 를 끝 문맥 블록으로.
3. §3.2 조항 기준점과 `Constitution_amendments`.
4. §3.3 `Active_goals`. 3 을 배포하고 다시 잰 뒤 연다.
