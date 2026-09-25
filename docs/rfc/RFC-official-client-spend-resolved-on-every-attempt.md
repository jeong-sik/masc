---
rfc: "official-client-spend-resolved-on-every-attempt"
title: "Resolve a Keeper turn's spend from every attempt, failed ones included"
status: Draft
created: 2026-09-25
updated: 2026-09-25
author: vincent + claude
related: ["official-client-conversation-in-masc"]
---

# RFC: Keeper 턴의 사용량은 실패한 시도까지 모든 시도에서 계산한다

- 상태: Draft. #38970(관측값 기록) 위에 서는 다음 단계다. 1단계는 #39000 이다.
- 기준: 코드 origin/main c996b77511 + #38970 브랜치, codex-cli 0.156.1(rust-v0.156.1 소스), 실측 `<base-path>/.masc` 2026-09-23~25.
- 논의: MASC board `p-99a5912884ef0eec9a5a8bdcbe4a139a`. 적대적 리뷰 1회(16건)를 반영했다.

## 1. 요약

**사실**

1. `masc cost` 는 `Resolved_delta` 행만 더한다. inference metrics 는 decision 행의 usage 를 턴 값으로 쓰고, 짝이 없는 cost 행을 더한다. 둘 다 **성공한 턴의 이긴 시도 하나**의 값이다(`Keeper_unified_turn_success.handle`).
2. 그 값도 턴 전체가 아니다.
   - Agent Core: 결과의 usage 는 마지막 응답 하나다(`keeper_agent_run.ml` 1890·1928, `runtime_agent.ml` 1446-1452). 응답마다의 usage 는 raw 행으로만 남고, 두 reader 모두 raw 행을 건너뛴다.
   - Codex: 마지막 요청(`last`)이다. 9/23~25 Codex rollout `token_count` 와 `costs/` 를 turn_id 로 이어 보니, 기록된 입력은 vendor 합계의 약 5.4% 였다.
   - Claude Code 만 턴 합계(`Turn_total`)다.
3. 실패한 턴과, 한 턴 안에서 진 시도(실패 뒤 failover)의 사용량은 어느 합계에도 없다. 같은 join 에서 Codex 중단 턴 384개가 vendor 입력 542.9M, 종료 기록 없는 턴 35개가 161.8M 을 썼는데 합계에는 0 이었다.
4. #38970 이후 세 official client 는 알려 준 값을 scope · 대화 id · 위치(Fresh/Resumed) · vendor total 과 함께 raw 행으로 남긴다. 계산 재료는 생겼지만 계산은 아직 없다.

**결정**

- 한 Keeper 턴의 사용량은 그 턴의 **모든 시도**를 시작 순서대로 접어(fold) 계산한 delta 의 합이다.
- 이긴 시도의 계산은 지금처럼 턴 하나의 해석으로 쓴다. 진 시도는 자기 `Resolved_delta` 행으로만 합계에 들어간다.
- 실패한 턴도 같은 계산을 한다. 커서와 합계는 턴의 meta commit 으로 옮기고, 행은 commit 이 성공한 뒤에 쓴다.
- Codex 사용량은 `total`(스레드 누적)을 누적 커서로 계산한다. `last` 는 마지막 요청의 점유량으로만 쓴다.

## 2. 지금 흐름

| 단계 | 위치 | 하는 일 |
|---|---|---|
| 기준 고르기 | `keeper_agent_run_finalize_response.ml` 413-442 | 이긴 시도의 `usage_scope` 와 `session_resumed` 로 `basis` 를 정한다. `Conversation_cumulative` 인데 `session_resumed = None` 이면 `Unavailable` 이다 |
| 계산 | `keeper_usage_resolution.ml` `resolve` 381-437 | `Per_request`·`Turn_total`: 관측값 그대로, 커서 그대로. `Conversation_counter Fresh`: 관측값 전체를 쓰고 커서를 그 값으로 바꾼다. `Resumed`: 같은 (runtime, 대화) 커서와의 차이. 커서가 없거나 다른 대화면 `Baseline_missing`, 줄었으면 `Counter_regressed`(둘 다 `Resumed` 에서만 유효, 285-291) |
| 성공 기록 | `keeper_unified_turn_success.ml` 617-763 | 계산(617) → metrics(670) → decision(708) → `Resolved_delta` 행(732-739) → meta commit(758-763). 행이 commit 보다 먼저 써진다 |
| autonomous 실패 | `keeper_unified_turn.ml` 1411-1451 | `update_metrics_from_failure` 는 턴 수·마지막 턴 시각·지연만 바꾼다. usage·커서는 그대로다 |
| direct lane 실패 | `keeper_turn.ml` 949-962 | meta 갱신도 commit 도 없다. keeper turn id(`total_turns + 1`, 596)를 쓰지 않으니 다음 턴이 같은 id 를 다시 쓴다 |

계산을 거치지 않는 다른 출구도 있다.

- direct lane: gate session full(866-884), gate 중단 에러(905-910), gate 중단(`Ok true`, 911-923), 미뤄 둔 runtime 이어가기(926-948)
- autonomous lane: 입력 요청 에러(1171-1189), 마지막 실행 없음(1235)
- 두 lane 모두: Eio 취소(운영자 중지)는 두 분기를 지나쳐 다시 던져진다

누적 커서는 Keeper 마다 한 칸이다(`meta.runtime.usage_cursor : cursor option`). Keeper 하나에는 한 번에 턴 하나만 돈다(`keeper_owner.mli` 88-91). 그래서 owner reducer 의 "마지막 쓰기가 이김"(285, 379)이 안전하다. 이 RFC 는 이 전제에 기댄다.

누적값을 쓰는 lane 은 지금 Antigravity 뿐이다(Codex·Claude·Agent Core 는 `session_resumed = None`).

- 9/23~25 Antigravity 턴 699개 중 `baseline_missing` 이 8개(약 1.1%)였다.
- 실패 뒤 다음 성공 턴이 같은 대화를 이어 쓴 경우가 18번, 새 대화를 연 경우가 21번이었다. 이어 쓰면 실패한 턴의 사용량이 다음 턴 delta 에 늦게 얹히고, 새로 열면 사라진다.

## 3. 결정

### D1. 계산 재료는 (시도, 대화, client 턴) 단위로 든다

`Keeper_run_tools_hooks` 의 관찰자가 시도(`routing_run_id`, `lane_attempt_index`)마다 재료를 든다. 한 시도 안에서도 대화가 바뀔 수 있다. Codex·Claude 의 shrink retry 는 `Restart_fresh` 로 새 스레드·세션을 연다.

| scope | 재료 |
|---|---|
| `Conversation_cumulative` (Codex, Antigravity) | 대화마다 마지막 보고 |
| `Turn_total` (Claude Code) | client 턴마다 보고 |
| `Per_request` (Agent Core) | 응답마다 `AfterTurn` usage 의 합. `agent.state.usage`(`pipeline.ml` 229-235)를 결과에 `Turn_total` 로 실어도 같다 |

`agent_setup` 이 이 재료를 내보내고, `Keeper_agent_run` 이 성공 결과와 실패 settlement 모두에 싣는다.

### D2. 시도를 순서대로 접는다

- 재료를 시도 시작 순서대로 `resolve` 에 넣는다. 각 `resolve` 가 돌려준 커서가 다음 재료의 입력 커서다.
- 불변식: 한 대화의 delta 합 = 그 대화의 마지막 관측 − 턴 시작 커서. 단위 테스트로 고정한다. `keeper_usage_resolution.ml` 427-428 의 "one settled turn at a time" 주석도 이에 맞게 고친다.
- **이긴 시도**의 해석은 지금처럼 `t` 하나를 받는 곳에 간다: `update_metrics_from_result`(`last_usage_resolution`), metrics 행, activity graph, decision 행, usage log, broadcast, `wall_tokens_per_second`, dashboard `last_*`.
- **진 시도**는 자기 `Resolved_delta` 행으로만 합계에 들어간다. decision 행이 없으니 inference metrics 에서는 "짝 없는 cost 행"으로 더해진다. 이긴 시도와 겹치지 않는다.
- 진 시도 행은 자기 ordinal · model · `runtime_attempt` 를 싣는다. official client ordinal 은 recovery 뒤 1 로 돌아가므로(`keeper_official_client_session_store.ml` 967-981) `(trace_id, keeper_turn_id, ordinal)` 가 겹칠 수 있다. 겹치면 reader 가 그 턴 전체를 버린다(`model_inference_metrics_reader.ml` 224-232). 그래서 `inference_identity` 에 `lane_attempt_index` 를 넣는다. resolved 행의 hard cut 이다.
- resolved 행에 해석 상태(`resolution_status`)를 적는다. 행은 dispatch 된 시도에만 쓴다. `masc cost` 의 `usage_missing_entries` 는 턴이 아니라 시도를 세게 되니 이름과 설명을 바꾼다.

### D3. 실패한 턴도 같은 commit 에서 기록한다

- autonomous lane 실패 분기(1411-1451)에는 이미 이전 meta, 갱신 meta, keeper turn id, Owner commit 한 번이 있다. D2 의 계산을 여기서 하고 같은 `updated_meta` 에 합계와 커서를 넣는다.
- `Resolved_delta` 행은 commit 이 성공한 **뒤에** 쓴다. 지금 성공 경로는 행을 먼저 쓰고 commit 한다(732-739 → 758-763). 그러면 commit 이 실패했을 때 커서는 그대로인데 행만 남는다. 다음 턴이 같은 사용량을 다시 계산해서 이중으로 더한다. 성공 경로도 같은 순서로 바꾼다.
- direct lane: 실패 시 `commit_turn_runtime` 을 새로 부르고, preempted 분기(`keeper_unified_turn.ml` 1207-1226)처럼 keeper turn id 를 쓴다(3단계).
- §2 의 다른 출구는 각각 "계산한다 / 하지 않는다"를 정한다. 기본은 계산한다. 운영자 중지(취소)는 계산하지 않고, 재료는 raw 행으로만 남는다.

### D4. Codex 사용량은 스레드 누적값으로 계산한다 (1단계, #39000)

- `Keeper_codex_runtime` 성공 결과
  - `request_context` 는 Claude 처럼: `last` 의 입력 쪽. OpenAI 의 `inputTokens` 는 이미 캐시를 포함하므로 `request_context.input_tokens = last.input_tokens` 이고 더하지 않는다.
  - scope · resumed 는 Antigravity 처럼: `response.usage = total`, `Conversation_cumulative`, `session_resumed = Some turn.resumed`, `session_id = thread id`.
- 그러면 기준이 `Conversation_counter { runtime_id; thread; Fresh|Resumed }` 가 되고, 재전송 프레임은 차이가 0 이다.
- 그대로 동작하는 곳: `last_input_tokens`, context 투영(turn record 의 per-request 점유량), `ctx_composition`.
- 누적값이 되는 곳(Antigravity 는 이미 이렇다): meta `last_output_tokens` · `last_total_tokens`(heartbeat presence 가 복사하고 투영이 대체값으로 씀), `AfterTurn` 로그 `tokens`, `wall_tok_s`, SSE `keeper_turn_observation` 의 입출력, untrusted-usage 로그.
  - 앞의 둘은 `request_context` 에 선택 출력(`output_tokens : int option`)을 더해 고친다. Codex `last.output_tokens` 는 응답마다 확정값이니 오늘의 turn record 출력이 그대로 남는다. Claude 의 assistant 프레임 출력은 스트리밍 중간값이라 `None` 이다.
  - 나머지는 해석된 delta 를 읽게 하거나, 누적값이라고 표시한다.
- 커서가 한 칸이라 Codex 가 커서를 쓰기 시작하면, 한 Keeper 가 Codex 와 Antigravity 를 번갈아 쓸 때마다 한 턴이 `baseline_missing` 이 된다. 지금은 Antigravity 커서가 Codex 턴을 건너 살아남는다. 9/23~25 에 이런 전환은 누적값 lane 턴 1,455개 중 6번(약 0.4%)이었다. 1단계가 고치는 Codex 과소 기록(약 94.6%)보다 훨씬 작아서 1단계를 먼저 한다. 4단계에서 전환 비율을 다시 잰다.

### D5. 누적값의 빈틈에 이름을 붙인다

`resolve` 가 알아볼 수 있는 것은 타입으로, 없는 값은 추정하지 않는다.

1. **Codex overflow 초기화**: context overflow 는 `total` 을 "입력·출력 0, `total_tokens` = 창 크기"로 바꾼다(rust-v0.156.1 `fill_to_context_window`).
   - `sample` 에 `vendor_total_tokens : int option` 을 더해 `resolve` 가 받게 한다.
   - `Resumed` 에서는 지금처럼 `Counter_regressed` 로 다시 기준을 잡는다.
   - `Fresh` 에서는 지금 정확한 0 delta 로 해석된다. 그런데 `Counter_regressed` 는 `Fresh` 에서 유효하지 않다(285-291). 그래서 새 상태 `Counter_reset`(0 입력·출력 + vendor total 있음)을 둔다.
   - 둘 다 그 턴에서 overflow 전에 쓴 양은 잃는다.
2. **remote compaction**: 요청의 사용량이 `total` 에 들어가지 않는다. 보이지 않는다.
3. **기록 전 중단**: 프레임이 기록되기 전에 app-server 가 멈추면 그 응답은 이후 `total` 에 없다.
4. **host stop**: MASC 가 도구 경계에서 턴을 끝내면, 그 도구를 부른 응답의 프레임은 도구가 끝난 뒤에 오므로 오지 않는다. vendor 가 아니라 MASC 쪽 빈틈이다. #38970 은 이 경우 "사용량 없음" 행을 남긴다.
5. **한 시도 안의 스레드 전환**: D1 이 대화 단위로 재료를 들어서 다룬다.
6. **fork**: fork 한 스레드는 부모의 `total` 을 이어받는다. MASC 는 fork 하지 않는다. D4 는 `Start` 스레드가 0 에서 시작한다고 전제한다.

## 4. 단계

| 단계 | 내용 | 바뀌는 합계 |
|---|---|---|
| 1 (#39000) | D4: Codex 를 누적값 + `request_context` 로. `request_context` 선택 출력과 누적값 필드 정리 | Codex 성공 턴이 마지막 요청에서 턴 전체로 |
| 2 | D1·D2·D3(autonomous): 재료 운반, fold, 진 시도 행, commit 뒤 행 쓰기, identity 에 attempt, D5.1 `Counter_reset`. Agent Core 도 응답 합으로 | 실패 턴 · 진 시도 · Agent Core 앞 응답이 합계에 |
| 3 | D3(direct lane): 실패 commit 과 turn id | direct lane 실패 턴 |
| 4 | (측정 뒤) 커서를 (런타임, 대화)마다 | `baseline_missing` 으로 잃는 턴 |

- 4단계 판단 기준: 2단계 배포 뒤 1주일 동안 Keeper 별 `baseline_missing` 턴 수와 그 턴들의 raw 행 입력 합. 이 값이 D4 의 전환 비율보다 커졌으면 한다. meta 스키마를 바꾸는 일이라 따로 정한다.
- 1·2단계는 운영 합계를 바꾼다. 각 PR 에 `### Upgrade notes` 로 "이 버전 앞뒤 합계는 바로 비교할 수 없다"를 적는다. 2단계의 identity 변경은 `### Fresh state required` 다.

## 5. 검증

- 단위(`Keeper_usage_resolution`)
  - fold 불변식: 한 대화의 delta 합 = 마지막 관측 − 시작 커서.
  - 시도 여러 개(같은 대화, 다른 대화, 누적과 턴 합계 섞임).
  - overflow: `Resumed` 는 `Counter_regressed`, `Fresh` 는 `Counter_reset`.
  - 재전송: 같은 값은 delta 0.
- 실제 Keeper 경로
  - Codex fixture 로 "여러 응답 → 성공", "응답 두 번 → 사용량 한도"를 돌려 `Resolved_delta` 합을 본다.
  - failover(Codex 실패 → 다른 lane 성공): 행 두 개, identity 가 겹치지 않는지 본다.
  - commit 실패를 주입해 행이 쓰이지 않는지 본다.
- 실측: 배포 뒤 #38970 과 같은 join(Codex rollout `token_count` ↔ `costs/` 의 `response_id`)으로 같은 턴 집합을 다시 잰다. 남는 차이는 D5 의 빈틈으로 설명할 수 있어야 한다. 설명되지 않는 차이가 있으면 이 RFC 의 전제를 다시 본다.

## 6. 하지 않는 것

- 에러 variant 마다 usage 를 싣지 않는다. 보고는 읽는 순간 관찰자로 가고(#38970), 계산은 턴 경계에서 한다.
- 빈틈을 추정으로 채우지 않는다(D5).
- raw 행을 다시 읽어 합계를 만들지 않는다. 계산은 메모리의 재료와 meta 커서로 한다. raw 행은 증거다.

## 7. 정한 것과 열린 질문

- 정함: scope 가 없는 옛 raw 행은 hard cut 한다. #38970 에서 raw 행의 `usage_scope` 를 필수로 바꿨다(constitution `legacy_residue`, projects.md "과거 버전 데이터를 위한 reader 금지").
- 열림: Claude result 에 usage 는 있는데 측정된 모델 응답이 없으면, 지금은 로그로만 남는다. 같은 프레임의 `modelUsage` 로 모델을 붙일지 정해야 한다. 이 경우가 실제로 얼마나 나오는지부터 잰다.
