---
rfc: "official-client-spend-resolved-on-every-attempt"
title: "Resolve an official client's spend from every attempt, failed ones included"
status: Draft
created: 2026-09-25
updated: 2026-09-25
author: vincent + claude
related: ["official-client-conversation-in-masc"]
---

# RFC: official client 의 사용량은 실패한 시도까지 모든 시도에서 계산한다

- 상태: Draft. #38970(관측값 기록)을 딛고 서는 다음 단계다.
- 기준: 코드 origin/main c996b77511 + #38970 브랜치, codex-cli 0.156.1(rust-v0.156.1 소스), 실측 `~/me/.masc` 2026-09-23~25.
- 논의: MASC board `p-99a5912884ef0eec9a5a8bdcbe4a139a`.

## 1. 요약

**사실**

1. `masc cost` 와 inference metrics 는 `Resolved_delta` 행만 더한다. 이 행은 Keeper 턴이 **성공했을 때, 이긴 시도 하나로만** 쓴다(`Keeper_unified_turn_success.handle`).
2. 그래서 실패한 턴의 사용량과, 한 턴 안에서 실패한 앞 시도의 사용량은 어느 합계에도 없다. 2026-09-24 official client 실패 턴 332개가 그랬다(대부분 quota 소진).
3. Codex 는 성공한 턴도 적게 잡힌다. 사용량을 마지막 요청(`last`, `Per_request`)으로 계산하기 때문이다. 9/23~25 Codex 세션을 vendor 기록과 이어 보니, 기록된 입력은 vendor 합계의 약 5.4% 였다.
4. #38970 이후 세 client 는 알려 준 값을 scope · 대화 id · 위치(Fresh/Resumed)와 함께 raw 행으로 남긴다. 계산에 필요한 재료는 생겼지만, 계산은 아직 없다.

**결정**

- 한 Keeper 턴의 사용량은 **그 턴의 모든 시도**의 마지막 보고를 각각 계산해 더한 값이다. 이긴 시도 하나가 아니다.
- 실패한 턴도 같은 계산을 하고, 같은 meta commit 안에서 `Resolved_delta` 행을 쓰고 누적 커서를 옮긴다.
- Codex 사용량은 `total`(스레드 누적)을 누적 커서로 계산한다. `last` 는 마지막 요청이 차지한 context 크기로만 쓴다.

## 2. 지금 흐름

| 단계 | 위치 | 하는 일 |
|---|---|---|
| 기준 고르기 | `keeper_agent_run_finalize_response.ml` 414-442 | 이긴 시도의 `usage_scope` 와 `session_resumed` 로 `basis` 를 정한다. `Conversation_cumulative` 인데 `session_resumed = None` 이면 `Unavailable` 이다 |
| 계산 | `keeper_usage_resolution.ml` `resolve` | `Per_request`·`Turn_total` 은 관측값 그대로, `Conversation_counter` 는 커서와의 차이. 커서가 다른 대화면 `Baseline_missing`, 줄었으면 `Counter_regressed` |
| 성공 기록 | `keeper_unified_turn_success.ml` 617-739 | 계산 → metrics 행 → `Resolved_delta` 행 → meta(합계·커서) commit |
| 실패 기록 | `keeper_unified_turn.ml` 1411-1451 | `update_metrics_from_failure` 는 턴 수만 올린다. usage·커서는 그대로다 ("A failed turn has no provider usage observation") |
| direct lane 실패 | `keeper_turn.ml` 949-962 | meta 갱신도 commit 도 없다 |

누적 커서는 Keeper 마다 한 칸이다(`meta.runtime.usage_cursor : cursor option`).

- Codex 와 Claude 는 지금 `session_resumed = None` 을 넘긴다. 커서를 쓰지 않는다.
- Antigravity 만 `Some turn.resumed` 를 넘긴다.
  - 9/23~25 Antigravity 턴 699개 중 `baseline_missing` 이 8개(약 1.1%)였다. 커서가 다른 대화를 가리켜서 그 턴은 계산되지 않았다.
  - 실패 뒤 다음 성공 턴이 같은 대화를 이어 쓴 경우가 18번, 새 대화를 연 경우가 21번이었다.
  - 같은 대화를 이어 쓰면 실패한 턴의 사용량이 다음 턴 delta 에 늦게 얹힌다. 새 대화를 열면 사라진다.

## 3. 결정

### D1. 시도마다 마지막 보고를 결과에 싣는다

- `Keeper_run_tools_hooks` 의 관찰자는 시도(`routing_run_id`, `lane_attempt_index`)마다 **마지막** `Keeper_client_usage_report.t` 를 들고 있는다.
- 누적값은 마지막 값이 그 시도의 최종 관측이다. 턴 합계(Claude)는 보고가 하나뿐이다.
- 이 값을 `agent_setup` 으로 내보내고, `Keeper_agent_run` 이 성공 결과와 실패 settlement 모두에 싣는다.
- Agent Core 시도는 지금처럼 `after_turn` 이 응답마다 보는 usage 가 재료다.

### D2. 턴의 사용량은 시도별 계산의 합이다

- 턴이 끝나면 시도마다 `resolve` 를 부른다. 이긴 시도의 계산은 지금과 같다. 진 시도(실패, failover 로 넘어간 시도)의 계산이 새로 더해진다.
- 각 계산이 `Resolved_delta` 행 하나를 쓴다. 행은 지금처럼 keeper turn id 로 묶인다. 한 턴에 행이 여럿일 수 있다.
- meta 합계에는 모든 delta 를 더한다. 커서는 마지막으로 계산한 누적 시도의 값으로 옮긴다.
- 계산할 수 없는 시도(`Baseline_missing`, `Usage_missing`)도 상태를 남긴다. 조용히 0 이 되지 않는다.

### D3. 실패한 턴도 같은 commit 에서 기록한다

- autonomous lane: 실패 분기(`keeper_unified_turn.ml` 1411-1451)에 이미 이전 meta, 갱신 meta, keeper turn id, Owner commit 한 번이 있다. D2 의 계산을 여기서 하고 같은 `updated_meta` 에 넣는다. 새 commit 은 만들지 않는다.
- direct lane: 실패 시 commit 이 없다. 턴 수도 올리지 않는다. 여기에는 `commit_turn_runtime` 을 새로 부른다(3단계).

### D4. Codex 사용량은 스레드 누적값으로 계산한다

- `Keeper_codex_runtime` 성공 결과를 Claude 와 같은 모양으로 바꾼다.
  - `response.usage = total`, scope `Conversation_cumulative`
  - `request_context = last` 의 입력 쪽(inclusive, 캐시 두 칸)
  - `session_id = thread id`, `session_resumed = Some turn.resumed`
- 그러면 기준이 `Conversation_counter { runtime_id; thread; Fresh|Resumed }` 가 되고, 재전송 프레임은 차이가 0 이다.
- 점유량을 읽는 곳(TUI, dashboard, context 투영, `last_input_tokens`)은 `request_context` 를 먼저 보니 그대로 동작한다.
- 대가: turn record 의 `output_tokens` 가 비게 된다. `turn_output_tokens` 가 `Turn_total` 일 때만 채워지기 때문이다. 누적값의 턴 출력은 계산 뒤에야 알 수 있어서 turn record 를 쓰는 시점에는 없다. 출력은 metrics 행과 resolved 행에 남는다.

### D5. Codex 누적값의 빈틈은 이름을 붙여 남긴다

rust-v0.156.1 소스로 확인한 빈틈이다.

1. context overflow 는 `total` 을 "입력·출력 0, `total_tokens` = 창 크기"로 바꾼다. 커서보다 줄었으니 `Counter_regressed` 로 다시 기준을 잡는다. 그 턴에서 overflow 전에 쓴 양은 잃는다. `vendor_total_tokens` 로 이 경우를 진짜 0 과 구분할 수 있다.
2. remote compaction 요청의 사용량은 `total` 에 들어가지 않는다. 이 RFC 로도 보이지 않는다.
3. 프레임이 기록되기 전에 app-server 가 멈추면 그 응답은 이후 `total` 에도 없다.

셋 다 vendor 가 주지 않는 값이다. 추정해서 채우지 않는다.

## 4. 단계

| 단계 | 내용 | 바뀌는 합계 |
|---|---|---|
| 1 | D4: Codex 성공 결과를 누적값 + `request_context` 로 | Codex 성공 턴 사용량이 마지막 요청에서 턴 전체로 |
| 2 | D1·D2·D3(autonomous): 시도별 보고를 싣고, 성공·실패 모두 시도마다 계산 | 실패 턴과 진 시도의 사용량이 `masc cost` 에 들어감 |
| 3 | D3(direct lane): 실패 시 commit | direct lane 실패 턴 |
| 4 | (측정 뒤) 커서를 (런타임, 대화)마다 | `baseline_missing` 으로 잃는 턴 |

- 1단계는 2단계 없이도 옳다. 성공 경로만 바꾼다.
- 4단계는 조건부다. 2단계 뒤 `baseline_missing` 비율을 다시 재서, lane 을 번갈아 쓰는 Keeper 에서 의미 있게 늘었을 때만 한다. meta 스키마를 바꾸는 일이라 따로 판단한다.
- 1·2단계는 운영 합계를 바꾼다. 각 PR 에 `### Upgrade notes` 로 "이 버전 앞뒤 합계는 바로 비교할 수 없다"를 적는다.

## 5. 검증

- 단위: `Keeper_usage_resolution` 에 시도 여러 개의 합, 실패 시도, overflow 초기화(0 입력·출력, vendor total > 0 → `Counter_regressed`), 재전송(같은 값 → delta 0)을 넣는다.
- 실제 Keeper 경로: Codex fixture 로 "여러 응답 → 성공", "응답 두 번 → 사용량 한도"를 돌려 `Resolved_delta` 합이 마지막 `total` 과 커서의 차이와 같은지 본다. failover(Codex 실패 → 다른 lane 성공)는 행 두 개를 본다.
- 실측: 배포 뒤 #38970 과 같은 join(Codex rollout `token_count` ↔ `costs/` 의 `response_id`)으로 같은 턴 집합을 다시 잰다. 남는 차이는 D5 의 빈틈으로 설명할 수 있어야 한다. 설명되지 않는 차이가 있으면 이 RFC 의 전제를 다시 본다.

## 6. 하지 않는 것

- 에러 variant 마다 usage 를 싣지 않는다. 보고는 읽는 순간 관찰자로 가고(#38970), 계산은 턴 경계에서 한다.
- 빈틈을 추정으로 채우지 않는다(D5).
- raw 행을 다시 읽어 합계를 만들지 않는다. 계산은 메모리의 시도별 마지막 보고와 meta 커서로 한다. raw 행은 증거다.

## 7. 열린 질문 (운영자 판단)

1. #38970 은 scope 가 없는 옛 raw 행을 `unavailable` 로 읽는다. 그래서 옛 행과 "client 가 scope 를 말하지 않은 새 행"을 구분할 수 없다. 옛 행을 따로 표시하는 생성자를 둘지, 옛 raw 행을 보관하고 hard cut 할지 정해야 한다.
2. Claude result 에 usage 는 있는데 측정된 모델 응답이 없으면, 지금은 로그로만 남는다. 같은 프레임의 `modelUsage` 로 모델을 붙일지 정해야 한다. 이 경우가 실제로 얼마나 나오는지부터 잰다.
