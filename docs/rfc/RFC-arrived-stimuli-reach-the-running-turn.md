---
rfc: "arrived-stimuli-reach-the-running-turn"
title: "도는 중에 큐에 도착한 행을 다음 요청에서 보여 준다 — 행은 큐에 그대로 둔다"
status: Draft
created: 2026-11-06
updated: 2026-11-06
author: claude
supersedes: []
superseded_by: null
related: ["backlog-never-preempts-a-running-turn", "keeper-async-fleet-continuity", "0290"]
---

# RFC: 도는 중에 큐에 도착한 행을 다음 요청에서 보여 준다 — 행은 큐에 그대로 둔다

Keeper 의 실행 하나는 모델 요청을 여러 번 보낸다. 큐는 턴 사이에만 비우고, 시계와 세계 상태는 첫 요청에만 실린다.
그래서 실행 중에 도착한 행은 실행이 끝날 때까지 모델 눈에 보이지 않는다. 실행이 몇 시간 도는 때도 있다.
이 RFC 는 도구 결과 뒤 요청에 "이 실행이 시작된 뒤 도착한 행" 블록을 더하자고 제안한다. 행은 큐에 그대로 남고, 실행이 끝난 뒤 자기 턴을 시작한다.

- 다루는 것: 도는 실행의 뒤 요청에 도착 행을 보이는 블록, 그 블록을 언제 한 번씩만 보이는지.
- 다루지 않는 것: 도는 실행을 끊는 일(`RFC-backlog-never-preempts-a-running-turn` 이 정했다), 행을 큐에서 지우거나 ack 하는 일, 비동기 도구(`RFC-0290`), 모델이 닫는 말을 쓰고 도구를 다시 부르는 버릇.
- 근거 기준: 이 브랜치의 base `f2d98655513`(2026-11-06).
- 측정: [`docs/evidence/runs-and-arrivals-2026-11/`](../evidence/runs-and-arrivals-2026-11/README.md). 2026-11-05T20:24Z 에 읽었어요. raw trace 는 오래된 순으로 지워져서 다시 재면 값이 달라져요.
- 되풀이하는 호출 측정: [`docs/evidence/repeated-calls-2026-11/`](../evidence/repeated-calls-2026-11/README.md). 2026-11-05T20:15Z 에 읽었어요.

## 0. 요약

- **[사실]** 실행 중에 큐에 도착한 행 1,773개가 실행이 끝나기 전에 확인(ack)된 적은 0번이다. 합쳐서 적어도 379.8시간을 기다렸다.
- **[사실]** 그중 1,374개는 같은 실행에 뒤따르는 요청이 있었다. 도착부터 그 요청까지는 중앙값 23.7초다. 실행 끝까지는 실행 크기에 따라 중앙값 1.6분(round 0~9개 실행)에서 25.0분(100개 이상)이다.
- **[사실]** 한 도구가 호출의 85% 이상인 실행 7개는 전체 round 의 10.5%인데 도착한 행은 2.2%(39개)이고, 3개 실행에는 도착한 행이 없었다. 이 RFC 는 블록이 그런 실행을 끝낸다고 주장하지 않는다.
- **[제안]** 도구 결과 뒤 요청에 `Arrived_stimuli` 블록을 싣는다. 행을 한 번씩만, 모델이 그 요청에 답한 뒤 "보였다"고 친다. 큐는 건드리지 않는다.
- **[사실]** 큐 snapshot 을 읽는 시간은 snapshot 복사본 4개로 쟀다. 파일이 그대로면 p50 0.03~0.04ms, 파일이 바뀐 뒤 첫 읽기는 p50 0.15~1.35ms 다(7.1).
- **[확인 필요]** 모델이 블록을 읽고 무엇을 하는지, 중복 처리가 생기는지, 쓰는 쪽이 lock 을 잡은 동안 읽기가 기다리는 시간은 재지 않았다. 배포하기 전이라 잴 수 없다.
- 이 RFC 는 비동기 `Execute` 와 Delegate 를 풀지 않는다. 그 둘의 결과가 도는 중에 도착하는 길(`keeper_delegate_completed`, 비동기 결과)만 이 블록으로 보인다.

## 1. 지금 모양

### 1.1 도는 중에 Keeper 가 보는 것

**[사실]** 도구 결과 뒤 요청에는 `Prompt_block_id.injected_on_post_tool_round` 가 참인 블록만 실린다. 지금은 Keeper 지시문, 활성 목표, 완료 권한, 운영자 메모(`Operator_note`)다.
시각 요약(`[Temporal] time=…`)과 세계 상태는 첫 요청에만 실린다. `masc_schedule_create` 설명이 같은 말을 한다. "A Keeper sees the current time only on its turn's first request, not after a tool round."
도구 루프의 매 요청에 세계 상태를 다시 실으면 모델이 그때마다 다시 답했다(task-514, `keeper_run_tools_hooks.ml` 주석). 그래서 뒤 요청에는 새로 생긴 것만 실어야 한다.

**[사실]** 큐는 턴을 시작할 때 읽고 admit 한다. urgency 는 행의 순서만 정하고 도는 실행을 끊지 않는다(`RFC-backlog-never-preempts-a-running-turn`).
도는 중에 도착한 행은 그 실행이 끝난 뒤 다음 턴의 intake 가 고른다.

### 1.2 이미 있는 길

`RFC-backlog-never-preempts-a-running-turn` 3.5 가 큐 요약을 보이는 길을 셋 적었다. 푸시, 풀, 도는 중 주입이다. 도는 중 주입은 "블록 종류 하나를 더한다"고 적었다.
같은 절은 요약을 턴 시작에 한 번만 만들자고 했다. "경계마다 읽으면 모델 요청 수만큼 읽기가 늘고 … 드는 비용은 재지 않았다."
운영자 메모는 이미 요청마다 한 번 싣는 블록이다(`Keeper_operator_note.pending` 과 `mark_consumed`). 이 RFC 는 그 모양을 따른다.

## 2. 측정

raw trace(`.masc/keepers/<keeper>/raw-traces`)와 reaction ledger(`reaction-ledger/v7`)를 읽었다. 도구는 `docs/evidence/runs-and-arrivals-2026-11/measure_runs_and_arrivals.py`, 시험은 같은 폴더에 있다. 값은 2026-11-05T20:24Z 에 읽은 `result.json` 이다.

| 값 | 측정 |
|---|---|
| 실행 / round 기록이 있는 실행 / round | 5,409 / 2,634 / 32,286 |
| 실행당 round | p50 5, p90 28, p99 111, 최대 903 |
| round 100개 이상인 실행 | 35개, 전체 round 의 22.7%, 39.63시간 |
| round 400개 이상인 실행 | 5개(모두 `glm-5.3-flash`), 전체 round 의 9.3%, 11.95시간 |
| 실행 중에 도착한 행 | 1,773개(범위 안의 확인된 행 3,534개의 50.2%) |
| 그중 실행이 끝나기 전에 ack 된 행 | 0개 |
| 막힌 시간(도착부터 실행 끝) 합 | 379.8시간 |
| 다음 요청이 있는 행 | 1,374개. 도착부터 다음 요청까지 중앙값 23.7초, p90 260.9초, 최대 1,795.3초 |
| 다음 요청이 없는 행 | 399개. 221개는 round 기록이 없는 실행 안에서, 178개는 마지막 요청 뒤에 도착 |
| 요청마다 처음 보이는 행 수(새 행이 있는 round 1,037개) | p50 1, p90 2, p99 7, 최대 16. 8개를 넘는 round 는 7개(행 89개) |

실행 크기별로 보면 막힌 시간의 중앙값은 round 0~9개 실행에서 1.6분, 10~49개에서 7.4분, 50~99개에서 16.6분, 100개 이상에서 25.0분이다. 합은 round 10~49개 실행 뒤가 193.6시간으로 가장 크다. 긴 실행만의 일이 아니다.
행 종류는 `board_attention` 745개, `board_signal` 737개(Immediate 293개), `schedule_due` 172개, `keeper_delegate_completed` 54개(Immediate 34개), `task_outcome` 17개(Immediate 17개) 순이다.

**[사실]** 1,614개(91.0%)는 11-04·11-05 에 도착했다. 그 두 날에 trace 가 가장 많이 남아 있다. 10-30~11-02 는 trace 가 거의 없어서 값이 없다.
**[사실]** 돌고 도는 실행(round 150개 이상, 한 도구가 호출의 85% 이상) 7개가 round 3,378개(전체의 10.5%)를 썼다. 3개는 사용량 한도 오류로, 2개는 모델이 답해서, 1개는 네트워크 오류로, 1개는 provider 시간 초과로 끝났다.
**[사실]** 그 7개 안에 도착한 행은 합쳐서 39개(전체 1,773개의 2.2%)다. `music-sensei`·`wkbl-data`·`wkbl-growth` 의 세 실행에는 ack 된 행이 한 개도 도착하지 않았다. 39개 중 33개는 `masc-productor-owner` 의 두 실행에서 왔다.
**[사실]** 같은 실행에서 직전 호출과 도구 이름·입력·결과가 모두 같은 호출은 호출 43,700개 중 1,663개(3.8%)다. 그중 86.6%가 `masc_board_list` 이고, `music-sensei` 한 실행이 897개, `masc-productor-owner` 의 두 실행이 427개와 104개로 합쳐서 85.9%를 가진다. 이 세 실행은 위 7개에 든다. 나머지 4개(`wkbl-data`, `wkbl-growth`, `goo-yang-bong`, `context-reviewer`)는 한 도구를 거의 매 round 불렀지만 되풀이가 9개 이하다.

## 3. 결정

### 3.1 `Arrived_stimuli` 블록

**[제안]** Agent Core 실행의 도구 결과 뒤 요청마다, 이 실행이 시작된 뒤 큐에 도착한 행을 블록으로 싣는다.

- 만드는 때: 도구 결과 뒤 요청에서만 만든다. 첫 요청은 만들지 않는다. 첫 요청을 조립할 때 큐를 이미 읽는다.
- 고르는 행: 큐의 대기 선택 중 `arrived_at` 이 실행 시작보다 늦고 이 실행이 아직 보이지 않은 행이다. 오래된 도착부터 한 요청에 8개까지 싣는다. 나머지는 "N more arrived; the next round lists them" 한 줄로 개수만 알린다. 행을 버리지는 않는다.
  8은 요청 하나에 실리는 글의 크기 상한이고 Keeper 의 행동을 정하지 않는다. 측정에서 새 행이 처음 보이는 round 1,037개 중 한 round 에 든 행은 p99 7개, 최대 16개였다. 8개를 넘는 round 는 7개이고, 그 행 89개 중 33개가 다음 요청으로 밀린다.
- 한 줄: `- <urgency>, <나이> ago: <한 줄 설명>`. 설명은 reaction ledger 가 쓰는 `stimulus_payload_preview` 와 같은 글이다. Board 글 제목은 256바이트에서 잘린다.
- 머리말: 도착한 행의 개수와 "그 행은 큐에 남고, 이 턴이 끝난 뒤 자기 턴을 시작한다"는 사실. 지시문이 아니라 상태다.
- "보였다"고 치는 때: 모델이 그 요청에 답한 뒤(`after_turn`)다. 요청이 답 없이 실패하면 다음 요청이 같은 행을 다시 싣는다.
- 읽기: `Keeper_registry_event_queue.pending_selections_result`. 읽기 전용이고 Keeper 소유자의 durable lock 을 잡고 디스크 상태를 읽는다. 읽지 못하면 그 요청은 블록 없이 가고 `Log.Keeper.warn` 한 줄을 남긴다. 읽은 값이 비면 블록이 없다.
- 순서: `cache_rank` 는 `Temporal_summary`(9) 다음 10이고, `Operator_note` 가 11로 밀린다. 운영자가 말하는 일이 가장 새 소식이라는 기존 약속을 지킨다.

타입: `Prompt_block_id.Arrived_stimuli` 를 더한다. `injected_on_post_tool_round` 는 참이고 `resent_when_held` 는 거짓이다. 닫힌 합타입이라 빠진 match 는 컴파일 에러가 된다.
대시보드는 모르는 블록 id 가 든 턴 기록을 통째로 거절한다(#38923). `TURN_PROMPT_BLOCK_IDS` 에 `arrived_stimuli` 를 더했고, `test_turn_record.ml` 이 서버와 대시보드 목록이 같은지 본다.

### 3.2 새로 저장하는 상태

없다. 실행 하나가 이미 보인 행의 `arrival` 번호를 메모리에 들고 있을 뿐이다(`recall_memo` 와 같은 수명). 옛 데이터를 읽는 코드와 migration 은 만들지 않는다.

## 4. 하지 않는 것

- 행을 큐에서 지우거나 ack 하지 않는다. 행의 처리는 지금처럼 자기 턴이 한다.
- 도는 실행을 끊지 않고, urgency 로 실행의 길이를 정하지 않는다.
- 블록에 Keeper 가 해야 할 일을 적지 않는다. 개수, 종류, 나이, 설명만 있다.
- `before_turn_params` 기록이 없는 실행에는 닿지 않는다. 블록은 그 hook 안에서 만든다. 그런 실행 2,775개 중 2,752개는 `client_context_submission` 기록을 남긴다. 이런 실행 안에서 도착한 행이 221개(12%)다.
- 모델이 "닫는 말 + 도구 호출"을 되풀이하는 버릇은 고치지 않는다. 블록은 그 실행이 새 소식을 알게 할 뿐이다. 되풀이가 가장 긴 `music-sensei` 11-05 실행은 903 round 중 `masc_board_list` 를 901번 불렀고 899번이 같은 입력이었는데, 그 실행 안에 ack 된 행이 한 개도 도착하지 않아서 이 블록은 한 줄도 싣지 못한다(`docs/evidence/repeated-calls-2026-11/` 의 표본).

## 5. 검증

| 확인 | 결과 |
|---|---|
| `test_keeper_arrived_stimuli` | 13개 통과. 행 선택, 한 번만 싣기, 요청 실패 뒤 다시 싣기, 한 요청 8개 한도와 남은 개수, 오래된 도착 순서, 읽지 못한 큐, 나이 글 |
| 변형 검사 | 변형 21개를 하나씩 넣어 모두 위 시험이 잡았다 |
| `test_turn_record` | 45개 통과. 서버와 대시보드의 블록 id 목록 일치 |
| `test_keeper_prompt_capture` · `test_keeper_next_request_forecast` | 11개 · 33개 통과 |
| `test_runtime_codex_app_server` | 203개 통과(`DUNE_SOURCEROOT` 를 dune 처럼 주고 돌렸다) |
| 대시보드 | `tsc` 통과. `vitest run` 전체 13,045개 중 8개가 실패한다. 7개는 변경 없는 main(`f2d98655513`)에서도 실패한다(`keeper.test.ts` 3개 등). 1개(`artifact-pdf-export`)는 전체를 돌릴 때만 20초 시간 초과가 나고 그 파일만 돌리면 9개 모두 통과한다 |
| `bin/masc_tui.exe` | 새 합타입 분기가 모두 있어서 컴파일 통과 |
| 측정 스크립트(실행·도착) | 시험 22개, 새 필드 변형 9개를 모두 시험이 잡았다, pyright strict 오류 0, ruff 통과 |
| 측정 스크립트(되풀이 호출) | 시험 27개, 변형 22개를 모두 시험이 잡았다, pyright strict 오류 0, ruff 통과 |

**[확인 필요]** `assemble_hooks` 를 거치는 시험은 없다. Agent Core 턴 하나를 통째로 돌리는 fixture 가 없고, hook 에는 블록 호출 한 곳과 `after_turn` 의 확인 한 줄이 있다.
이 로컬 결과는 CI 와 현재 head 의 독립 리뷰를 대신하지 않는다.

## 6. 배포 뒤 측정

배포는 사용자가 정한다. 배포 뒤에 같은 스크립트를 같은 방법으로 다시 돌린다.

1. 노출: 턴 기록의 블록 목록에 `arrived_stimuli` 가 든 요청의 수와 한 요청의 행 수.
2. 실행 길이: round 100개 이상인 실행의 수와 점유율(지금 35개, 22.7%)이 바뀌는지.
3. 효과: 블록을 본 실행이 그 뒤 어떻게 끝나는지(남은 round 수, 마지막 도구). 정의가 아직 없다. **[확인 필요]**

## 7. 위험과 열린 질문

1. **읽기 비용.** 도구 결과 뒤 요청마다 owner lock 을 잡고 큐 snapshot 을 읽는다. 파일이 그대로면 persistence 층의 `lstat` 캐시가 답해서 JSON 을 다시 읽지 않는다. 2026-11-06 에 본 `event-queue-v19.json` 은 43개이고 크기는 중앙값 11,823바이트, p90 20,948바이트, 최대 108,593바이트다.
   읽는 시간은 그 snapshot 중 4개의 복사본으로 쟀다(`Keeper_event_queue_persistence.pending_selections_result` 한 번의 호출). 대기 행은 0·5·17·34개다.

   | snapshot | 파일이 그대로인 읽기 p50 / p99 (ms) | 파일을 바꾼 뒤 첫 읽기 p50 / p99 / 최대 (ms) |
   |---|---|---|
   | 1,576바이트 | 0.035 / 0.084 | 0.145 / 5.080 / 7.698 |
   | 11,823바이트 | 0.036 / 0.097 | 0.230 / 0.883 / 2.176 |
   | 20,948바이트 | 0.036 / 0.102 | 0.318 / 0.839 / 2.480 |
   | 108,593바이트 | 0.031 / 0.081 | 1.354 / 8.156 / 20.830 |

   조건: macOS 로컬 디스크이고, 읽는 프로세스가 하나이며, 큐에 쓰는 쪽이 없다. 파일이 그대로인 읽기는 2,000번, 바꾼 뒤 읽기는 500번 쟀다. 바꾼 뒤 읽기는 같은 내용의 새 파일을 snapshot 자리에 rename 해서 캐시를 못 쓰게 했다. 복사본은 schema 글자만 현재 빌드의 `v22` 로 고쳤다(실행 중인 서버의 파일은 `v21`). 옆에 transition WAL 이 없다. `Keeper_registry.get` 의 등록 확인은 재지 않았다. 재는 코드는 저장소에 넣지 않았다.
   **[확인 필요]** 쓰는 쪽이 owner lock 을 잡고 fsync 하는 동안 읽기가 기다리는 시간과, 서버에서 Keeper 여러 명이 동시에 읽을 때의 값은 재지 않았다. `RFC-backlog-never-preempts-a-running-turn` 3.5 는 경계마다 읽기를 피하려 했다. 이 RFC 는 도착이 실행 안에서 일어나서 턴 시작의 한 번 읽기로는 못 본다고 본다.
2. **중복 처리.** 모델이 블록의 행을 실행 중에 처리해도 행은 큐에 남아서 자기 턴이 다시 admit 한다. 그 턴이 이미 끝난 일을 알아보는지는 정하지 않았고 재지 않았다. **[확인 필요]**
3. **모델의 반응.** 블록이 돌고 도는 실행을 끝내는지 모른다. 7개 중 2개는 모델이 스스로 답해서 끝났고 3개는 한도 오류로 끝났다. 7개 중 3개에는 ack 된 도착 행이 0개라서, 같은 일이 다시 벌어져도 블록이 나타나지 않는다. 큐에서 ack 없이 사라진 행은 reaction ledger 에 없어서 이 측정에 들어 있지 않다.
4. **시작 시각의 경계.** 실행 시작은 hook 을 조립하는 시각이다. 턴의 첫 intake 와 그 시각 사이에 도착한 행은 이 실행에서 보이지 않고 다음 턴이 처리한다. 그 틈의 길이는 재지 않았다.
5. **다른 런타임.** `before_turn_params` 기록이 없는 실행의 도착 행(221개)은 이 RFC 로 닿지 않는다. 그 런타임에 닿는 길(Codex 의 `turn/steer` 등)은 `RFC-backlog-never-preempts-a-running-turn` 1.7 이 찾은 대로다. 이 RFC 는 다루지 않는다.
6. **한 줄의 글.** 설명은 ledger 의 preview 를 그대로 쓴다. 모델이 이 글로 행을 알아보는지는 재지 않았다.
7. **측정 범위.** 도착 행의 91%가 이틀(11-04·11-05)에서 나왔다. 그 이틀의 부하(실행 1,495개와 2,048개)가 평소인지 모른다.

## 8. 관련

- `RFC-backlog-never-preempts-a-running-turn` — 도는 실행을 끊지 않는 원칙과 큐 요약의 세 길(3.5). 이 RFC 는 그중 도는 중 주입이다.
- `RFC-keeper-async-fleet-continuity`, `RFC-0290-keeper-background-wait-tool` — 도구 결과가 도는 중에 도착하는 길. 이 RFC 는 그 결과가 큐 행으로 도착했을 때 보이는 일만 다룬다.
- `docs/evidence/runs-and-arrivals-2026-11/` — 실행 길이와 도착 행 측정.
- `docs/evidence/repeated-calls-2026-11/` — 직전과 같은 호출을 되풀이하는 실행 측정.
