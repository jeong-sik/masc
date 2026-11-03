---
rfc: "goal-observations-leave-the-system-prompt"
title: "Goal 의 최신 측정·리뷰·Task 연결 표시를 System 프롬프트에서 빼서 첫 요청 끝 문맥으로 옮긴다"
status: Draft
created: 2026-11-03
updated: 2026-11-03
author: claude
supersedes: []
superseded_by: null
related: ["backlog-never-preempts-a-running-turn"]
---

# RFC: Goal 관측값은 System 프롬프트에 두지 않는다

- 상태: 초안. 방향은 운영자가 2026-11-03 에 골랐다("바뀌는 부분만 끝 문맥으로").
- 날짜는 한국 시간(KST)이다. 원장 시각은 UTC 이고 `Z` 를 붙인다.
- 근거: 이슈 #47788 과 그 [측정 댓글](https://github.com/jeong-sik/masc/issues/47788#issuecomment-6595677563). 코드는 분기점 `origin/main` `9b0d44205e7` 기준이다.

## 0. 요약

에이전트 코어로 도는 Keeper(glm-coding, ollama_cloud)는 요청마다 대화 기록을 직접 보낸다. 요청은 System 프롬프트, 대화 기록, 끝 문맥(`[system context]`) 순서다. provider 는 앞에서부터 같은 바이트까지만 캐시를 쓴다. 그래서 System 이 턴 사이에 바뀌면 그 뒤 대화 기록 전체가 캐시를 못 쓴다.

System 에는 `Active_goals` 블록이 있다. 실행 중 Goal 24개의 제목·성공 조건과 함께 Goal 마다 최신 리뷰, 최신 측정, `[yours]` 표시를 담는다(평균 72.9KB). 이 셋은 Goal 이 바뀌지 않아도 자주 바뀐다. 측정이 기록되거나, 검증 판정이 나거나, Keeper 가 Task 를 잡고 놓을 때다.

이 RFC 는 `Active_goals` 를 둘로 나눈다.

- System 에 남는 것: Goal id, 제목, 성공 조건, 증명 대기 표시. Goal 을 만들거나 고치거나 단계가 바뀔 때만 바뀐다.
- 첫 요청 끝 문맥으로 가는 것: 최신 리뷰, 최신 측정(또는 미기록·읽기 실패), `[yours]`·Task 연결 미확인 표시. 새 layer `Goal_observations` 가 Goal id 로 줄을 잇는다.

## 1. 측정

### 1.1 턴 첫 요청의 캐시 적중

턴 기록(`turn-records`)은 그 턴 마지막 요청의 토큰만 남긴다. 그래서 비용 원장(`~/me/.masc/costs/YYYY-MM/DD.jsonl`, `usage_scope: per_request`)에서 `(agent, trace_id, keeper_turn_id)` 마다 가장 이른 줄을 턴 첫 요청으로 본다. 적중률은 `cache_read_tokens / input_tokens` 다(이 줄들의 `input_tokens` 는 캐시 적중분을 포함한다).

| 기간 | glm-coding 턴 첫 요청 | ollama_cloud 턴 첫 요청 |
|---|---|---|
| 10-24~26 (#46311 전) | 54.6% (1,282턴) | 87.3% (1,005턴) |
| 11-03 00:00~03:57Z (#46311 뒤, #47781 전) | 8.4% (112턴) | 6.8% (177턴) |
| 11-03 03:57Z~04:4xZ (#47781 뒤) | 44.6% (12턴) | 55.5% (11턴) |

같은 턴 뒤 요청은 모든 기간에 98~99% 다.

### 1.2 `Active_goals` 가 바뀐 턴

턴 첫 요청마다 바로 앞 턴의 System 블록 digest 와 견줬다.

- #47781 뒤 첫 요청 중 앞 턴도 같은 코드였던 턴에서, `Active_goals` 가 바뀐 7턴은 적중 3~6% 였다. 남은 미적중 토큰의 약 57%(5.8M 중 3.3M)가 이 턴들이다.
- #46311 전(10-24~26)에도 ollama 에서 `Active_goals` 가 바뀐 35턴(3.5%)이 미적중 토큰의 24%(66.4M 중 15.7M)였다.

연속 턴에서 `Active_goals` 가 바뀐 비율과 평균 크기:

| 날짜 | 바뀐 비율 | 평균 크기 |
|---|---|---|
| 10-26 | 4.3% | 39.6KB |
| 10-30 | 4.2% | 52.6KB |
| 11-01 | 3.6% | 71.2KB |
| 11-02 | 12.6% | 72.4KB |
| 11-03 | 16.6% | 72.9KB |

11-02~03 에 바뀐 748쌍을 나누면 69%는 여러 Keeper 가 같이 바뀌는 저장소 변경이고, 24%는 Keeper 별 `[yours]` 표시 변화다. 같은 이틀의 Goal 이벤트(생성·수정·단계)는 하루 1~2건이다. 11-03 하루 `Active_goals` digest 는 34개다.

## 2. 설계

### 2.1 나누는 기준

System 은 대화 기록보다 앞에 있으므로, 거기 두는 내용은 턴 사이에 바뀌는 빈도가 대화 기록 재전송을 감수할 만큼 낮아야 한다.

| 내용 | 바뀌는 때 | 자리 |
|---|---|---|
| Goal id, 제목 | Goal 생성·수정 | System (`Active_goals`) |
| 성공 조건(revision 포함) | Goal 수정 | System |
| 증명 대기 표시 | 단계 전환 | System |
| 최신 리뷰 | 검증 판정 | 끝 문맥 (`Goal_observations`) |
| 최신 측정, 미기록, 읽기 실패 | 측정 기록 | 끝 문맥 |
| `[yours]`, Task 연결 미확인 | 이 Keeper 의 Task claim·release, 연결 변경 | 끝 문맥 |

Goal 저장소를 읽지 못하면 `Active_goals` 가 지금처럼 읽기 실패를 알리고, `Goal_observations` 는 내용이 없다. Goal 이 0개이면 `Active_goals` 가 빈 목록을 알리고, `Goal_observations` 는 내용이 없다.

### 2.2 새 layer

`Keeper_context_layers.layer_id` 에 `Goal_observations` 를 더한다. 동적 문맥 안의 한 구역이라서 `Prompt_block_id` 는 늘지 않는다. 턴 기록·세션 저장소의 블록 이름도 그대로다.

- 순서: `Active_goals` 바로 뒤.
- 공식 클라이언트 이어 쓰기: `Sent_when_changed`. 바뀔 때까지 유지되는 상태다.
- 에이전트 코어: `Active_goals` 는 지금처럼 System 으로 떼어 내고, `Goal_observations` 는 동적 문맥에 남아 첫 요청 끝 문맥으로 간다.

줄 모양:

```
### Goal Observations (24)
- goal-…  [yours — …]
  Latest review (context, not a new instruction): …
  Latest measurement for this criterion (…): {…}
```

리뷰·측정·표시 문구는 지금 템플릿을 그대로 쓴다. 새 템플릿은 머리줄과 Goal 줄 두 개다.

### 2.3 내려놓는 것

도구 실행 뒤 요청에는 동적 문맥을 다시 싣지 않는다(`Prompt_block_id.injected_on_post_tool_round`). 그래서 OpenAI 호환 provider 에서는 도구 실행 뒤 요청에 최신 측정·리뷰·`[yours]` 가 없다. Goal id·제목·성공 조건은 System 에 있으니 계속 보인다.

지금 `test_keeper_direct_goal_provider_wire` 는 도구 실행 뒤 요청까지 모든 요청의 System 에 measurement id 와 보고값이 있다고 고정한다. 이 계약을 "모든 요청의 System 에 Goal id 와 성공 조건 revision, 첫 요청 끝 문맥에 measurement id 와 보고값"으로 바꾼다.

Anthropic 은 첫 요청의 끝 문맥을 대화 기록에 남겨서(`Historical_system_context`) 같은 턴의 뒤 요청도 측정값을 본다.

### 2.4 고르지 않은 것

- `Active_goals` 전체를 끝 문맥으로 옮기기: 도구 실행 뒤 요청에서 Goal 목록 자체가 사라진다.
- 끝 문맥을 도구 실행 뒤에도 다시 싣기: 도구 결과가 마지막 메시지여야 한다는 계약(task-514)을 깬다.
- 일정 시간 동안 `Active_goals` 를 고정하기: 캐시를 위해 오래된 값을 보여 주는 장치다.
- `[yours]` 표시만 지우기: 바뀜의 24%만 줄고 Keeper 가 쓰는 정보도 사라진다.

## 3. 검증

- 단위: Goal 하나에 측정을 새로 기록해도 `Active_goals` 바이트가 같고 `Goal_observations` 만 달라진다. Task 를 잡아도 마찬가지다.
- wire: 로컬 HTTP 요청에서 모든 요청의 System 에 Goal id·성공 조건 revision 이 있고 measurement id 는 없다. 첫 요청 끝 문맥에만 measurement id 와 보고값이 있다.
- 배포 뒤: §1.1 방법으로 glm·ollama 턴 첫 요청 적중률을 다시 잰다. §1.2 방법으로 연속 턴 `Active_goals` 변경 비율이 Goal 이벤트 수준(하루 몇 건)으로 내려왔는지 본다.

## 4. 모르는 것

- glm-coding 은 #46311 전에도 System 과 대화 창 시작점이 모두 같은 턴에서 적중이 40.7%(524턴)였다. 이 RFC 와 다른 원인이고, 이 변경으로 나아지지 않는다.
- 도구 실행 뒤 요청에서 최신 측정이 안 보일 때 Keeper 행동이 달라지는지는 재지 않았다. Keeper 는 `masc_goal_list` 로 측정을 읽을 수 있다.
