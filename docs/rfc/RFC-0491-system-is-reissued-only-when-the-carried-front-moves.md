---
rfc: "0491"
title: "System 은 범위 앞부분이 움직일 때만 다시 만들고, 그 사이 바뀐 세계 상태는 끝 문맥으로 보낸다"
status: Active
created: 2026-11-05
updated: 2026-11-09
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
2. 조항이 바뀌어도 System 은 그 Keeper 가 마지막으로 보낸 조항으로 렌더한다. 그 뒤 바뀐 조항은 끝 문맥 블록 `Constitution_amendments` 로 보낸다. 범위 앞부분이 움직이면 System 을 지금 조항으로 다시 만든다(§3.2).
3. System 의 Goal 순서는 바뀌지 않는 키로 정한다. 증명 대기 표시는 Agent Core에서는 그 턴의 System 관측으로, official client에서는 턴별 입력으로 보낸다. 같은 상태를 매 도구 뒤 새 User 발화처럼 붙이지 않는다(§3.3).

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

System 을 만든 조항을 기준점이라 한다. 기준점은 두 값이다. 그 조항을 읽은 조항 원장의 위치(바이트 길이와 그 바이트의 SHA-256)와, 그 조항으로 렌더한 System 의 digest 다. 원장은 덧붙이기만 하므로, 그 위치의 조항은 지금 원장의 앞 바이트를 접어서 다시 얻는다. 앞 바이트의 digest 가 다르면 얻지 못한 것으로 본다(`World_constitution_store.load_articles_at`).

Keeper 세션은 기준점을 runtime 마다 하나씩 든다. 앞부분을 runtime 마다 견주기 때문이다. 턴의 System 은 이렇게 고른다.

| 조건 | System | 끝 문맥 `Constitution_amendments` |
|---|---|---|
| 이번 턴 첫 요청의 예상 앞부분이 그 runtime 의 직전 요청 앞부분과 같고, 그 runtime 의 기준점 조항으로 렌더한 System 의 digest 가 기준점의 digest 와 같다 | 기준점 조항으로 렌더한 것 | 지금 조항과 기준점 조항의 차이 |
| 그 밖: 앞부분이 다르다, 직전 요청이 없다, 지시문이나 `keeper.md` 가 바뀌었다, 기준점이 없다, 원장 앞 바이트가 바뀌었다 | 지금 조항으로 렌더하고 그 runtime 의 기준점을 새로 둔다 | 없음 |

- 둘째 줄의 지시문 수정은 그 턴에 바로 반영된다. 그 턴은 어차피 System 바이트가 달라져 캐시가 깨지므로, 조항도 지금 것으로 맞춘다.
- 차이는 System 이 렌더하는 조항 id 와 본문으로 낸다. 추가된 조항은 id 와 본문을, 지운 조항은 id 를 적는다. 원장은 들고 있는 id 를 다시 추가하면 그 자리에서 고친 것으로 접는다(`World_constitution_store.apply`). 그래서 본문이 바뀐 조항은 옛 줄을 지우고 새 줄을 더한 것으로 낸다. 본문은 `World_constitution_render` 와 같은 escape 를 거친다.
- 견주는 앞부분은 직전 요청의 것이다. provider 캐시에 남은 것은 직전 요청의 System 과 그 앞부분부터의 기록이다(§1.2). System 을 만든 때의 앞부분과 견주면, 턴 중간에 앞부분이 움직인 다음 턴은 캐시가 맞을 자리에서 System 을 다시 만든다.
- 직전 요청의 앞부분은 (Keeper, runtime, session) 원장 `Keeper_model_input_ledger.Table` 이 든 값이다. 원장이 지금 기록을 덮지 않으면(`holds` 가 아니면) 직전 요청이 없는 것으로 본다.
- 예상 앞부분은 `Keeper_next_request_forecast.carry` 로 구한다. 이 함수는 `Keeper_turn_driver_try_provider.choose_range_start` 와 `project_range_start` 를 그대로 거친다. 입력은 턴 driver 가 첫 요청에서 읽는 것과 같다. 원장 front(없으면 turn record seed), Librarian continuity, 턴 시작점, 이번 턴의 기록이다.
- 실제 요청의 앞부분으로는 고르지 못한다. Agent Core 는 요청마다 System 을 먼저 정하고(`packages/agent_core/lib/pipeline/pipeline_stage_prepare.ml:207-213`), 그 뒤 `prepare_turn_for_agent`(같은 파일 236행)가 부르는 projection 이 앞부분을 정한다. System 은 턴마다 한 번 만들고, 그 턴의 모든 lane·시도·round 가 같이 쓴다.
- 예상과 실제가 다를 수 있다. 크기 거절로 앞부분이 턴 경계로 옮겨지거나 다른 lane 으로 넘어갈 때다. 그 요청은 어차피 기록 캐시를 놓친다. 조항은 System 과 끝 문맥을 합쳐 늘 지금 것이 실린다. 예상은 캐시가 맞을지만 정하고, 무엇이 실리는지는 정하지 않는다.
- 기준점은 세션 checkpoint 의 context(`Agent_core.Context` 의 Session scope, 키 `keeper_turn_system`)에 둔다. 이번 턴이 낸 System 의 기준점과 runtime 별 기준점을 같이 적는다. 다음 턴은 불러온 checkpoint 에서 읽는다. 조항 본문은 적지 않고 원장 위치만 적으니, 조항 원장과 Keeper 지시문이 그대로 SSOT 다. 기준점은 그 투영이다.
- native 이어가기는 재시작 등으로 끊긴 direct 턴을 seed 가 기록한 System 으로 다시 보낸다. seed 의 checkpoint context 에 그 System 의 기준점이 있으므로, 그 조항과 지금 조항의 차이를 다시 내서 블록으로 보낸다. 기록된 System 의 digest 가 기준점과 다르거나 기준점이 없으면 어느 조항으로 만들었는지 모르므로 블록 없이 보낸다.
- 한 턴의 walk 는 맨 앞 runtime 으로 경로를 정한다. 같은 walk 의 다음 후보도 같은 System 과 블록을 받는다. Claude Code 는 실행마다 System 을 넘기고, Codex 는 resume 에서 System 이 바뀌었으면 다시 보낸다. 그래서 둘 다 블록이 고치는 System 을 든다. 블록의 줄 하나하나는 받는 System 이 무엇이든 지금 세계에 대해 맞다.

`Constitution_amendments` 는 `Prompt_block_id` 블록이다. world state 의 layer 가 아니다. world state 는 턴이 System 을 고르기 전에 렌더되고, 조항 차이는 System 을 고를 때 정해지기 때문이다. §3.1 의 `Completion_authority` 블록처럼 같은 턴의 뒤 round 에도 싣는다. 든 조항으로 만든 System 과 그 차이는 한 값으로 다녀서, 차이 없이 그 System 만 쓰는 호출자는 생기지 않는다.

`Constitution_amendments` 는 끝 문맥이라 System 보다 뒤에 읽힌다. 뒤에 온 글이 지금 상태로 읽힌다는 것은 RFC-0366 이 운영자 메모를 맨 뒤에 둔 근거와 같다(`lib/keeper/keeper_run_tools_hooks.ml` `Operator_note` 주석). 끝 문맥은 런타임이 조립하는 `[system context]` 다. 모델이 쓴 글은 조항 본문뿐이고, 그 본문은 System 에서와 같은 escape 를 거친다.

현재 조항 전체 목록(`norms_current`, RFC-0504 §2.4)을 싣는 턴은 이 절의 차이를 쓰지 않는다. native 재개와, 접은 이력에 격리 줄이 있는 세계의 턴이 그렇다. 에이전트 코어는 그 목록을 System 뒤에 붙는 관측으로 보낸다(#50882). 기준점 조항으로 렌더한 System(`keeper_instructions`)은 그대로다. 하지만 요청이 보내는 System 은 조항이 쓰일 때 뒷부분이 바뀌고, 그 요청은 대화 기록 캐시를 놓친다. 목록을 끝 문맥에 두었을 때는 도구 결과 뒤 요청마다 같은 목록이 새 발화로 읽혔고 Keeper 가 매번 답했다. 그래서 이 비용을 받아들였다.

### 3.3 Goal 단계와 순서는 System 을 바꾸지 않는다

3층이 들어간 서버(2026-11-06 03:10:41Z 부팅)에서 §1.1 과 같은 방법으로 07:20Z 까지 다시 쟀다(`docs/evidence/2026-11-06-rfc-0491-system-cache/README.md` 「3층 배포 뒤」). 앞부분이 그대로인데 `active_goals` 만 바뀐 쌍이 70개다. 첫 요청 미적중 토큰의 45.7% 이고, 미적중률은 97.6% 다. 아무 블록도 바뀌지 않은 쌍은 30.5% 다.

같은 시간에 Keeper 별 `active_goals` digest 가 바뀐 78건을 바이트 차이로 나눴다.

| 원인 | 건 |
|---|---|
| 증명 대기 표시(56B)가 붙거나 떨어졌다 | 60 |
| Goal 이 늘었다 | 15 |
| 바이트는 같고 순서만 바뀌었다 | 3 |

- 증명 대기 표시는 Goal 이 `Verifying` 일 때 System 의 Goal 줄 끝에 붙는다(`keeper_unified_prompt.ml` `format_goal_summaries`). 완료 요청(`Request_complete`)으로 붙고, verifier 의 반박(`Record_proof_refuted`)이나 `Reopen` 으로 떨어진다. 10-30 뒤 `Verifying` 으로 간 33건 중 30건이 masc-tui 운영자 요청이고, 다시 `Executing` 으로 돌아온 28건은 verifier 반박이다. 둘은 12~20분 간격으로 오간다. 한 번 오갈 때마다 모든 Keeper 의 System 이 두 번 바뀐다.
- 순서는 `updated_at` 내림차순이다. 반박을 쓰면 `updated_at` 이 바뀐다. 그래서 표시가 붙었다 떨어진 Goal 이 같은 priority 무리의 맨 앞으로 가고, 바이트가 같은 채 순서만 바뀐다.

11-06의 #49257은 이 표시를 매 요청 끝의 User-role 문맥으로 옮겼다. 11-09에는 `code-reviewer-brother`의 한 실행에서 도구 뒤 재주입 37회와 같은 Goal을 다시 언급한 응답 20개를 확인했다. 긴 도구 루프의 유일한 원인인지는 입증되지 않았지만, 같은 상태가 도구 결과보다 뒤의 새 발화로 보이는 전달 경로는 확인됐다. [실측과 수리 범위](../evidence/2026-11-09-keeper-proof-context-feedback/README.md)에 따라 전달 위치를 다음처럼 고친다.

- `Goals_awaiting_proof`에는 지금 `Verifying`인 Goal의 id와 표시 문구가 들어간다. 그런 Goal이 없으면 관측도 없다. `Active_goals`의 개별 줄에는 표시를 붙이지 않는다.
- Agent Core에서는 이 관측을 첫 요청의 System suffix에 넣고, 같은 실행의 도구 뒤 요청에는 정확히 같은 관측을 유지한다. 다른 새 문맥이 없으면 도구 결과가 요청의 마지막 메시지다. 새 턴에서는 현재 단계를 다시 읽으므로 증명 대기가 끝나면 관측도 빠진다. 이 상태 변화가 System 바이트를 바꾸는 비용은 감수한다.
- official client는 vendor System이 턴보다 오래 남으므로 기존처럼 현재 Start 입력과 매 Resume 입력에 이 블록을 보낸다. 실제 실행 주체인 `Runtime_execution.checkpoint_owner`가 전달 위치를 정하며, fallback으로 주체가 바뀌어도 같은 관측을 새 주체의 위치로 옮긴다. provider 이름이나 문장으로 분기하지 않는다.
- 뒤 요청에서 증명 대기 Goal이 다시 일반 일로 보이면 RFC-0387 P0-1의 회귀다. 이 수리는 관측을 생략하지 않는다. §3.1의 `Completion_authority` 전달도 유지한다.
- System 의 Goal 순서는 (priority, created_at, id) 다. System 줄에는 priority 가 없어서, 순서가 priority 를 보여 주는 유일한 신호다. 그래서 id 만으로 정렬하지 않는다. 이 정렬은 System 렌더에서만 한다. `Goal_store.list_goals_result` 의 순서를 쓰는 다른 곳은 그대로다.
- 11-06 설계는 78건 중 63건(81%)의 System 변경을 없애려는 것이었다. 11-09 수리 후에는 증명 대기 전환도 System을 바꾸므로 이 수치를 현재의 절감량으로 쓰지 않는다. Goal 목록을 기준점으로 드는 방법(§4)은 별도 측정 뒤 판단한다.

## 4. 검토한 대안

- **조항을 System 에서 빼서 매 요청 끝 문맥으로 보낸다.** 하지 않는다. 11-04 `per_request` 요청은 15,030건이다. 조항 본문 9,373B 가 요청마다 캐시 없이 나간다. 조항이 바뀌어서 놓친 토큰(§1.2)보다 크다.
- **조항을 대화 기록에 덧붙인다.** 하지 않는다. 기록은 agent_core 의 checkpoint 가 소유하고 Librarian 이 읽는다. 런타임이 만든 조항이 기록 atom 이 되면 같은 사실이 조항 원장과 기록 두 곳에 생긴다.
- **조항 원장 쓰기를 모아서 늦춘다.** 하지 않는다. 원장은 일어난 일을 적는 곳이다. 쓰기를 늦추는 장치는 행동을 통제하는 gate 가 된다.
- **System 을 만든 때의 앞부분과 견준다.** 하지 않는다. 턴 중간에 앞부분이 움직이면 캐시에는 움직인 앞부분부터의 기록이 남는다. 다음 턴 첫 요청이 그 앞부분에서 열리면 캐시가 맞을 자리인데, 만든 때의 앞부분과는 달라서 System 을 다시 만들고 캐시를 깬다.
- **Agent Core 가 앞부분을 정한 뒤 System 을 고르게 순서를 바꾼다.** 하지 않는다. System 은 턴의 lane·시도·round 가 같이 쓰는 값이다. agent_core 의 prepare 순서를 바꾸면 모든 provider 경로가 바뀐다. 예상 앞부분으로 같은 결정을 턴 시작에 낸다.
- **기준점을 프로세스 메모리에 둔다.** 하지 않는다. native 이어가기는 seed 가 기록한 System 을 다시 보낸다. 재시작으로 프로세스 메모리가 비면 그 System 이 어느 조항으로 만들어졌는지 모른다. 그러면 옛 조항 System 이 차이 블록 없이 나간다(#49004 리뷰 F1). 기준점은 그 System 과 같은 checkpoint 에 있어야 한다.
- **기준점에 조항 본문을 적는다.** 하지 않는다. 11-06 원장의 조항 34개를 JSON 으로 적으면 기준점 하나가 14,762B 다. checkpoint 중앙값은 7,907B 다(최근 세션 42개). runtime 마다 하나씩이면 checkpoint 가 몇 배로 커진다. 원장 위치로 적으면 이번 턴 기준점이 186B, runtime 하나가 226B 다.
- **System 기준점을 턴 기록에 저장한다.** 하지 않는다. native 이어가기는 checkpoint 를 복원한다. 턴 기록에 두면 seed 와 기준점이 다른 곳에서 따로 쓰인다.
- **증명 대기 표시를 `Goal_observations` 로 옮긴다.** 하지 않는다. 그 layer 는 `Dynamic_context` 라서 뒤 round 에 실리지 않는다(`prompt_block_id.ml` `injected_on_post_tool_round`).
- **Goal 목록을 기준점으로 든다(§3.2 와 같은 방식).** 지금은 하지 않는다. Goal 저장소(`goals.json`)는 덮어쓰는 파일이다. `goal_events.jsonl` 은 삭제를 적지 않고, 지금 Goal 59개 중 4개는 `goal_created` 가 없다. 그래서 원장 위치로 옛 목록을 얻을 수 없다. 기준점은 Goal 마다 criterion revision 을 렌더 순서대로 들면 된다(열린 Goal 30개 기준 약 1.1KB). 성공 기준이 바뀌면 revision 이 새로 생기므로, 같은 revision 의 Goal 은 같은 줄로 렌더된다. 다만 checkpoint 의 기준점 schema 를 바꿔야 하고, 고칠 코드가 +600줄 안팎이다. §3.3 의 두 변경이 81% 를 없애므로, 남은 Goal 추가·성공 기준 수정의 몫을 잰 뒤 정한다.
- **기준점에 Goal 줄 본문을 적는다.** 하지 않는다. 열린 Goal 30개면 기준점 하나가 약 38KB 로, checkpoint 중앙값 7,907B 의 다섯 배다.
- **provider 캐시 breakpoint 로 System 을 따로 캐시한다.** 해당 없다. Z.AI 문서는 캐시가 설정 없이 걸린다고 쓰고, opencode Go 문서에는 breakpoint 가 없다(§1.4).

## 5. 영향

- 조항이 바뀐 뒤 범위 앞부분이 움직일 때까지, Keeper 는 System 의 옛 조항과 끝 문맥의 차이를 함께 읽는다. 11-05 범위 앞부분은 턴 쌍의 11.0% 에서 움직였다. 평균 9턴쯤 뒤에 System 이 지금 조항으로 다시 만들어진다.
- 끝 문맥은 요청마다 차이 바이트만큼 커진다. 조항 하나는 300~500B 다.
- 서버가 다시 떠도 첫 턴은 불러온 checkpoint 의 기준점을 읽는다. 예상 앞부분이 같으면 기준점 System 을 다시 보낸다. 재시작 뒤 캐시가 실제로 맞는지는 배포 뒤 원장으로 잰다.
- checkpoint 마다 기준점이 실린다. runtime 둘을 쓰는 세션은 680B 다(이번 턴 기준점 186B, runtime 마다 226B).
- 턴을 준비할 때 원장을 읽는다. 기준점을 쓰는 턴은 원장을 한 번 더 읽고 앞 바이트의 SHA-256 을 계산한다. 11-06 원장은 43,236B 다.
- official client Keeper 는 §3.1 의 authority 를 지금과 같은 자리에서 받는다. §3.2·§3.3 의 System 기준점은 walk 맨 앞이 에이전트 코어인 턴만 바꾼다. official client 가 맨 앞인 턴은 지금 조항으로 만들고 runtime 별 기준점을 건드리지 않는다.

## 6. 검증

- 시험: `assemble_request_context` 가 `Completion_authority` 를 System 이 아닌 블록으로 내고, 뒤 round 에도 같은 블록을 싣는다. official Start 의 System 과 carrier 에는 그 블록이 없고, Start prompt 앞과 Resume 마다 carrier span 증명과 함께 실린다. 조항이 바뀐 턴에서 범위 앞부분이 같으면 System 바이트가 같고 차이 layer 가 생긴다. 앞부분이 다르면 System 이 지금 조항을 담고 차이 layer 가 없다. 지시문이 바뀌면 System 이 바로 바뀐다.
- 시험: native 이어가기가 재시작 뒤에도 seed checkpoint 의 기준점으로 차이 블록을 낸다. 기준점이 없는 seed 는 블록 없이 기록된 System 을 보낸다. 두 runtime 을 번갈아 쓰는 세션은 runtime 마다 자기 기준점을 받는다. 원장 위치는 그 뒤 덧붙인 조항과 제자리 수정에도 같은 조항을 돌려주고, 앞 바이트가 바뀌면 아무것도 돌려주지 않는다.
- 시험(4층 수리): Agent Core의 실제 HTTP 요청 세 개에서 `Verifying` Goal의 id·표시가 같은 System 관측으로 유지되고, 도구 뒤에는 그 표시를 담은 User 메시지가 없다. 새 턴의 단계 변화는 System에 반영된다. official Start/Resume와 실행 주체 fallback에서는 현재 단계가 전달되고 vendor System에 턴별 단계가 남지 않는다. 같은 priority의 Goal은 created_at, id 순이다.
- 수리 배포 뒤에는 동일 기준으로 단계 표시 반복 응답과 System 변경 비용을 각각 잰다. 소스·합성 API 비교 결과를 운영 Keeper의 회복이나 캐시 절감 증명으로 바꾸지 않는다.
- 배포 뒤: §1.1 과 같은 방법으로 "앞부분 그대로, System 바뀜" 쌍과 그 몫을 다시 센다. 기대값은 `completion_authority` 쌍 0, 조항 추가로 바뀐 `keeper_instructions` 쌍 0 이다. 지시문 수정과 배포로 바뀐 쌍은 남는다. 전체 목록을 싣는 턴이 보내는 System 의 변화는 `keeper_instructions` digest 에 잡히지 않아 이 수에 들어가지 않는다(§3.2 끝).

## 7. 층

1. 이 문서.
2. §3.1 `Completion_authority` 를 끝 문맥 블록으로.
3. §3.2 조항 기준점과 `Constitution_amendments`. 예상 앞부분은 forecast 의 `carry` 로 구한다.
4. §3.3 System의 Goal 순서를 (priority, created_at, id)로 한다. 11-06에는 증명 대기를 끝 문맥으로 옮겼고, 11-09 수리에서는 Agent Core의 System 관측과 official의 턴별 입력으로 나눈다.
5. §4 의 Goal 기준점. 4층을 배포하고 다시 잰 뒤 연다.
