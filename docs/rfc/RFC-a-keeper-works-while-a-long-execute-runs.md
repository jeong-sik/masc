---
rfc: "a-keeper-works-while-a-long-execute-runs"
title: "긴 Execute 가 도는 동안 Keeper 가 다른 일을 한다"
status: Draft
created: 2026-11-11
updated: 2026-11-11
author: claude
supersedes: []
superseded_by: null
related: ["execute-background-through-the-tool-outbox", "arrived-stimuli-reach-the-running-turn", "backlog-never-preempts-a-running-turn", "keeper-async-fleet-continuity", "retained-results-carrier-shrinks-to-an-address", "0266", "0225", "0290"]
implementation_prs: []
---

# RFC: 긴 Execute 가 도는 동안 Keeper 가 다른 일을 한다

줄 번호는 `3c89f0114cea` 기준이다. 측정 창을 따로 적지 않은 값은 2026-11-08T05:40:00Z ~ 2026-11-11T05:40:00Z(72시간, 이하 W1)다.
표시: **[사실]** 은 코드나 데이터에서 확인한 것, **[추정]** 은 근거는 있지만 직접 보지 못한 것, **[제안]** 은 이 RFC 가 정하려는 것, **[확인 필요]** 는 아직 모르는 것이다.

## 0. 요약

- **[사실]** 한 Keeper 는 채팅 작업을 하나씩 돌린다. 앞 작업의 턴이 Execute 호출 안에 있으면 다음 작업은 호출이 끝날 때까지 기다린다.
- **[사실]** 60초 이상 Execute 1,183번(74.214 h) 중 15.519 h(20.9%) 동안 같은 Keeper 의 채팅 작업이 기다렸다. 그 89.0%(13.812 h)는 직접 턴 안이다. 직접 턴은 채팅 작업이 기다린다는 이유로는 끝나지 않는다.
- **[사실]** 15.519 h 의 68.5%(10.629 h)는 직접 턴에서 `sleep` 뒤에 GitHub 확인 상태를 읽는 호출 286번이 만들었다. 호출 시간은 중앙값 242초다(측정용 라벨).
- **[사실]** 같은 기다림에 쓰는 typed 길 `masc_schedule_create until_github_run` 은 255번 불렸다. 그 기다림을 `sleep` 으로 한 60초 이상 호출은 683번이다. 직접 턴만 보면 55번 대 286번이다. 긴 호출이 `run_in_background` 로 간 적은 없다(0 / 1,183).
- **[제안]** 후보는 셋이다. (가) 영수증을 모델 호출마다 다시 읽는다. (나) 모델이 영수증 하나를 기다리겠다고 부르면 턴이 끝나고, 작업은 그 영수증이 올 때까지 claim 되지 않는다. (다) 한 Keeper 안에서 턴 둘이 동시에 돈다.
- **[사실]** (가)는 겹침을 움직이지 못한다. (나)가 닿는 상한은 겹침 15.519 h 전부다. 큐 대기 196.34 h 의 66.4% 는 다른 채팅 작업이 도는 동안의 대기이고, 이쪽은 (다)만 닿는다.
- 추천과 결정은 8절에 있다.

## 1. 배경: 잰 것

### 1.1 고정 기준

겹침 기준은 #51284 의 `docs/evidence/tool-efficiency-before-after-2026-11/queue_wait_overlap.py` 다. 정의는 이렇다.

- 호출 구간: Execute 장부 행 중 `duration_ms` 가 60초 이상인 것을 `[ts - duration, ts]` 로 그린다. Keeper 마다 겹치는 구간을 합친다.
- 대기 구간: 그 Keeper 의 채팅 작업 저장소(`chat-operations.sqlite3`)에서 `created_at` 부터 `started_at` 까지다.

W1 값은 #51284 의 `docs/evidence/tool-efficiency-1111-2026-11/result-queue-wait-overlap-2026-11-08T05-40_11-11T05-40.json` 에서 읽었다(장부 파일 71개). 같은 폴더의 `README.md` 를 이하 `README.md` 라 부른다.

| 값 | 분모 |
|---|---|
| 60초 이상 Execute 1,183번, Keeper 24명, 74.214 h | — |
| 그 시간 중 같은 Keeper 의 채팅 작업이 기다린 시간 15.519 h | 74.214 h 의 20.9% |
| 채팅 작업 1,466개의 큐 대기 합 196.34 h | — |
| 그 대기 중 긴 Execute 와 겹친 합 42.457 h | 196.34 h 의 21.6% |

42.457 h 는 작업별 합이라 같은 시각에 기다린 두 작업을 둘 다 센다. 15.519 h 는 Keeper 시간이다.

### 1.2 긴 Execute 와 기다림이 어디서 나는가

위 두 값을 턴 종류와 명령 글자로 나눴다. 합은 1.1 의 값과 같다(74.214 h, 15.519 h, 42.457 h).

| 턴 | 명령 | 호출 | 잡은 시간 | 같은 Keeper 작업이 기다린 시간 | 대기 합 중 겹침 |
|---|---|---:|---:|---:|---:|
| 순찰 | `sleep` 없음 | 224 | 7.546 h | 0.180 h | 0.325 h |
| 순찰 | `sleep` 있음 | 510 | 36.767 h | 1.527 h | 4.264 h |
| 직접 | `sleep` 없음 | 106 | 5.511 h | 1.989 h | 2.545 h |
| 직접 | `sleep` 있음 | 343 | 24.391 h | 11.823 h | 35.323 h |
| 합 | | 1,183 | 74.214 h | 15.519 h | 42.457 h |

- 직접 턴은 채팅 작업으로 도는 턴이다(장부 `turn_kind` 가 `direct`). 순찰 턴은 `autonomous` 다.
- `sleep` 이 든 호출이 잡은 시간의 82.4%(61.158 h)이고, 기다림 15.519 h 의 86.0%(13.351 h)다. 이 값은 계산이 아니라 기다림이다.
- 직접 턴에서 `ollama_cloud.ollama-cloud-deepseek-v4-1-flash` 로 돈 호출이 334번(22.863 h)이고, 기다림은 12.561 h 로 15.519 h 의 80.9% 다. Keeper 는 `code-reviewer-brother`, `code-reviewer-father`, `context-reviewer`, `masc-productor-owner`, `rondo`, `wkbl-data`, `wkbl-front`, `wkbl-growth` 여덟이다.
- 결과 JSON 의 Keeper 별 값으로는 `rondo` 가 330번(21.164 h) 중 9.105 h 다.
- 순찰 턴 안의 기다림은 1.707 h 뿐이다. 순찰 턴은 도구 경계에서 채팅 작업에 슬롯을 넘기기 때문이다(3.2).

`sleep` 이 든 직접 턴 호출 343번을 `gh` 로 한 번 더 나눴다. 합은 위 표의 「직접 · `sleep` 있음」 행과 같다.

| 명령 | 호출 | 잡은 시간 | 같은 Keeper 작업이 기다린 시간 | 대기 합 중 겹침 |
|---|---:|---:|---:|---:|
| `gh` 로 Actions run·check run·`pr checks` 를 읽음 | 286 | 20.677 h | 10.629 h | 32.935 h |
| `gh` 로 그 밖의 것(PR·review·git ref)을 읽음 | 25 | 1.516 h | 0.699 h | 1.389 h |
| `gh` 없음 | 32 | 2.198 h | 0.495 h | 0.999 h |
| 합 | 343 | 24.391 h | 11.823 h | 35.323 h |

- 첫 행이 15.519 h 의 68.5%, 42.457 h 의 77.6% 다.
- 첫 행 286번의 호출 시간은 중앙값 242초, p90 423초, 최대 1,214초다.
- `gh` 가 든 호출 311번이 읽는 자원은 한 호출이 여럿을 읽으면 각각 세어 `actions` 183번, `pulls` 65번, `commits/…/check-runs` 58번, `gh pr checks` 57번, `pulls/…/reviews` 24번이다. 명령의 모양은 `sleep 480; gh pr checks 51166 --repo jeong-sik/masc | head -6` 이다.
- 순찰 턴의 `sleep` 호출 510번 중 397번도 같은 확인 상태를 읽는다(30.497 h). 기다림은 0.494 h 다.

### 1.3 기다린 쪽

채팅 작업 1,466개의 대기 196.34 h 를 장부와 같은 저장소에서 다시 나눴다.

| 대기 | 개수 | 시간 |
|---|---:|---:|
| 전체 | 1,466 | 196.34 h |
| 같은 Keeper 의 다른 채팅 작업이 도는 동안(그런 구간이 있는 작업 523개) | — | 130.45 h (66.4%) |
| 다른 Keeper 나 에이전트가 보낸 것(`channel` 이 `agent`) | 1,399 | 183.468 h (93.4%) |
| `channel` 이 빈 문자열인 것 | 67 | 12.872 h |
| 60초를 넘겨 기다린 작업 | 542 | 194.734 h (99.2%) |

- 작업 하나의 대기는 중앙값 7.8초, p90 1,527.6초, 최대 14,596.8초다. 긴 쪽 10%(146개)가 143.805 h(73.2%)를 쓴다.
- `agent` 채널 대기 183.468 h 중 127.398 h(69.4%)가 다른 채팅 작업이 도는 동안이다.
- 긴 Execute 와 겹친 것은 42.457 h 다. 그 가운데 직접 턴 안이 37.868 h 다. 다른 채팅 작업이 도는 동안의 130.45 h 에서 빼면 약 92.6 h 가 긴 Execute 밖에서 기다린 시간이다. 두 집합이 정확히 포개지는지는 확인하지 않았다.

### 1.4 기다림을 슬롯 밖으로 보내는 길이 쓰이는 모양

`run_in_background`:
- 같은 창에서 Execute 는 89,771번이고 `run_in_background` 는 124번(0.14%)이다. 60초 이상 호출 중에는 0번이다(`README.md` 표).
- 124번은 Keeper 열다섯이 불렀다. 많은 순서로 `wkbl-data` 44, `ocaml-agent-ic` 31, `e-masc-the-leader` 10, `code-reviewer-father` 9, `sangsu` 7 이고, 나머지 열은 4번 이하다. 순찰 턴 68번, 직접 턴 56번이고 `keeper_turn_id` 는 56개다.
- 시작 호출은 중앙값 31 ms, 최대 1.9초에 끝났다. 명령의 첫 단어는 `cd` 52, `sh` 23, `dune` 14, `bash` 11 순이다.
- 시작 뒤 같은 턴에서 호출이 중앙값 33개 더 이어졌다. 이어진 호출이 없는 경우는 9번이다.
- 66번은 같은 턴에서 `sleep` 이 든 Execute 를 다시 불렀고, 그중 59번은 그 호출이 60초 이상이었다. `keeper_composition_*` 를 부른 경우는 16번이다.

`masc_schedule_create`:
- 같은 창에서 524번 불렸다(순찰 턴 437, 직접 턴 87). 입력에 `until_github_run` 인자가 든 호출이 255번이다(순찰 턴 200, 직접 턴 55). 입력의 `message` 글에 그 이름만 적힌 3번은 세지 않았다. 많이 부른 Keeper 는 `e-masc-the-leader` 58, `sangsu` 50, `github-pr-checker` 31 이다.
- 같은 창에서 같은 기다림(Actions run·check run·`pr checks`)을 `sleep` 으로 한 60초 이상 Execute 는 683번이다(순찰 턴 397, 직접 턴 286). 분류는 1.2 와 같다.
- Execute 의 도구 설명은 이 호출이 GitHub Actions run 이 끝날 때 Keeper 를 깨운다고 말한다(`config/tools/Execute.toml:1-20`). 예약한 뒤 직접 작업이 어떻게 끝나는지는 읽지 않았다.

### 1.5 한계

- 겹침은 **본 겹침**이지 줄어들 시간이 아니다. 호출이 끝난 뒤 이어지는 턴의 모델 시간은 그대로 남고, 늦어진 작업이 더 늦게 시작하는 효과는 반대로 작용한다(`README.md` 「못 한 것과 모르는 것」).
- 같은 창을 다시 재면 큐 대기 값이 달라진다. 15.087 h 였다가 15.519 h 가 됐다(`README.md`). 이보다 작은 변화는 읽지 않는다.
- `sleep`·`gh`·확인 상태(Actions run, check run, `pr checks`) 분류는 명령 글자의 단어 경계 규칙이다. 측정용이며 제품 규칙이 아니다. `sleep` 없이 기다리는 명령과, `sleep` 이 있어도 기다림이 아닌 명령이 모두 있을 수 있다.
- 분할 값(1.2~1.4)은 한 번씩 돌린 스크립트에서 나왔다. 저장소에 두지 않았다. 읽은 것은 1.1 과 같은 장부 파일과 저장소이고, 분할의 합이 1.1 의 값과 같은 것을 확인했다. 따로 쓴 두 번째 스크립트가 1.1 의 세 값과 「직접 · `sleep` 있음 · `gh` 확인」 행의 겹침 10.629 h, 대기 합 중 겹침 32.935 h 를 같게 냈다(11-11). 명령 분류 규칙의 세부가 달라 그 행의 호출 수는 286 대 280, 잡은 시간은 20.677 h 대 19.901 h 로 갈렸다. 「직접 · `sleep` 없음」 행의 겹침도 1.989 h 대 1.868 h 로 갈렸다. 구현 PR 이 이 분할을 `queue_wait_overlap.py` 에 넣는다.
- 긴 Execute 수는 스크립트마다 다르다(1,181 / 1,183 / 1,184, `README.md`). 이 RFC 는 겹침 기준의 1,183을 쓴다. 같은 창에서 `github_wait_shapes.py` 는 GitHub 를 기다리는 긴 호출을 926번(61.342 h)으로 센다. 그 분류는 `gh run watch|view`, `gh pr checks|view|status`, `gh api`, `--watch` 중 하나와 맞는 명령을 세고 `sleep` 은 보지 않는다(`tool-efficiency-1110-2026-11/README.md`). 이 RFC 의 `gh` 분류는 `sleep` 이 든 호출만 세므로 값이 다르다.
- W1 은 Keeper 와 일이 이전 창과 달라서 창끼리 값을 빼지 않는다. 이전 창(11-07T10:20Z ~ 11-10T10:20Z)의 같은 값은 6.473 h(16.7%)였다.

## 2. 문제

- 채팅 작업은 한 Keeper 에서 하나씩 돈다. 도는 턴이 호출 하나에 오래 머물면 그만큼 뒤 작업이 기다린다.
- 호출은 끝나야 경계가 온다. 순찰 턴이 채팅 작업에 슬롯을 넘기는 때는 호출이 끝난 뒤다. 직접 턴은 채팅 작업이 기다려도 넘기지 않는다(3.2).
- 긴 호출의 대부분은 계산이 아니라 기다림이다. 직접 턴에서는 `sleep` 뒤에 GitHub 확인 상태를 읽는 호출이 중앙값 242초다(1.2).
- 기다림을 슬롯 밖으로 내보내는 길(`run_in_background`, `masc_schedule_create`)은 이미 있다. 긴 호출은 `run_in_background` 로 간 적이 없고, 예약은 같은 기다림에 255번 쓰였다(1.4).
- `run_in_background` 는 턴을 끝내지 않는다. 시작한 뒤에도 턴이 이어지고, 이어진 턴이 다시 기다린다(1.4).

이 RFC 가 다루는 것은 겹침 15.519 h 와 그 바깥 구조다. 큐 대기 196.34 h 중 긴 Execute 와 겹치는 것은 21.6% 뿐이다.

## 3. 지금 코드가 하는 일

### 3.1 한 Keeper 에 턴 하나

- Owner 는 도는 턴을 한 칸에 둔다. `turn_in_flight : turn_in_flight option Atomic.t`(`keeper_owner.ml:453`)이고 칸의 값은 `lane`(순찰·채팅 작업·유지보수), 시작 시각, 중단 토큰이다(`:84-93`).
- 채팅 작업 child 는 칸이 비어 있고 claim 할 작업이 있을 때만 시작한다(`start_child_if_needed`, `keeper_owner.ml:1816-1834`). 닫힌 문(`chat_gates_closed`, `:1808-1815`)이 있으면 시작하지 않는다.
- 취소 능력도 하나다(`child_cancel : child_cancel option Atomic.t`, `keeper_owner.ml:466`).
- 저장소가 같은 것을 한 번 더 막는다. `running` 행은 하나(`operations_single_running`, `keeper_chat_operation_store.ml:128-129`), 실행 기록의 `running` 도 하나(`semantic_single_running`, `:97`)다. 스키마는 `masc.keeper_chat_operations.v3` 다(`:85`).
- 이 제약이 생긴 사고는 `RFC-0225` 에 있다. 2026-06-10 `sangsu` 에서 17분 순찰 턴이 채팅 턴 다섯 개와 겹쳤고, 체크포인트가 덮어써져 방금 한 말을 잊었다(§1).

### 3.2 순찰 턴은 호출이 끝난 뒤 슬롯을 넘긴다

- AGENT_CORE 는 도구 결과와 체크포인트를 저장한 뒤에야 양보 probe 를 부른다(`keeper_agent_run.ml:1402-1404` 주석). probe 는 `tool_boundary_state` 다(`:355-372`).
- 순서는 종단 효과, 반복 실패, `chat_handoff` 다. `chat_handoff` 가 참이면 `Yield Durable_stimulus_waiting` 이다.
- `chat_handoff` 는 순찰 턴에서만 owner 에게 묻는다(`keeper_agent_run.ml:1372-1393`). 직접 턴은 `Ok false` 다(`:1374`).
- owner 의 답은 이렇다(`keeper_owner.ml:2083-2096`). 도는 턴이 순찰이고 중단 토큰이 같다. 채팅 작업 runner 가 있고 문이 열려 있다. claim 할 작업이 있고 도는 채팅 작업이 없다. 모두 참이면 참이다.
- 양보한 턴은 `Resume_after_chat_handoff` 를 남긴다(`keeper_agent_run.ml:403-409`). heartbeat 는 이것이 있고 대기 입력이 있으면 다음 주기를 바로 연다(`keeper_heartbeat_loop.ml:923-933`).
- 그래서 대기하는 채팅 작업이 순찰 턴의 긴 Execute 를 기다리는 시간은 호출의 남은 시간이다. 1.2 의 순찰 행이 그 값이다(1.707 h).

### 3.3 직접 턴이 끝나는 길

- 직접 턴은 채팅 작업이 기다린다는 이유로 끝나지 않는다(3.2). 도중에 끝나고 작업이 큐에 남는 길로 읽은 것은 둘이다(`keeper_turn.ml:1057-1081`).
  1. 도구 결과가 `Generic_deferred` 다. 턴이 `Yielded_to_durable_stimulus` 로 끝나고 결과는 `Continuation_checkpoint` 다(`keeper_tool_terminal_boundary.ml:1-4`, `keeper_turn_outcome.ml:44-45`). 체크포인트를 남기고 작업을 큐로 되돌린다(`Keeper_direct_checkpoint_continuation.defer` `:85`, `defer_official` `:106`). 저장소는 이 작업의 순서를 새 입력 뒤로 옮기고 바로 claim 할 수 있게 둔다(`keeper_chat_operation_store.ml:2616-2670`, 주석 `:2655-2656`). 다시 시작할 때 체크포인트에서 이어 가며 원래 입력을 다시 붙이거나 도구 호출을 다시 하지 않는다(`keeper_direct_checkpoint_continuation.ml:43-71`).
  2. Agent Core 가 `InputRequired` 로 끝난다. 모델이 입력을 요청한 경우다. 작업은 `Input_wait` 로 남고 응답이 올 때까지 claim 되지 않는다(`defer_direct_input_wait`, `keeper_chat_operation_store.ml:2404`).
- 도구 결과의 `deferred_kind` 는 넷이다(`keeper_tool_execution.mli:6-10`). 핸들러는 `Generic_deferred` 일 때만 `on_deferred` 를 부르고, 그 상태가 턴을 끝낸다(`keeper_tools_agent_core_handler.ml:124-136`).
  - `External_effect_deferred`(Gate 가 효과를 보류한다)는 경계 판정이 `Continue` 다. 주석이 이유를 적는다. 턴이 호출 하나만 보류하고 멈추자 모델의 말이 맨 상태 줄로 나갔다(`keeper_tool_terminal_boundary.ml:5-11`).
  - `Owned_job_result_wait`, `Composition_result_wait` 는 콜백을 부르지 않는다. 주석은 이 읽기에 완료 깨움이 없고 직접 호출자는 다른 일을 이어 한다고 말한다.
- claim 못 하는 상태는 다섯이다(`blocked_queued_scopes`, `keeper_chat_operation_store.ml:1731-1753`). 해결이 없는 Gate 대기, `Preparation_wait`, `Gate_binding`, `Input_wait`, `not_before` 가 아직 오지 않은 제공자 backoff 다. 멈춘 실행 기록은 도는 슬롯을 잡지 않는다(`keeper_chat_operation_store.mli:514-515`).
- 실행 기록의 `phase` 는 `Suspended of Keeper_checkpoint_ref.t` 와 `Recovering` 을 포함한다(`keeper_semantic_execution.mli:129-142`).
- 시각으로 푸는 대기는 서버가 다시 시작하면 깨움이 죽는다. owner 가 시작할 때와 drain 마다 가장 이른 깨움을 다시 건다(`next_runtime_retry_wake`, `keeper_chat_operation_store.ml:1782`).

### 3.4 Execute 의 백그라운드 경로

- `run_in_background` 는 `Keeper_execute_background.defer`(`keeper_execute_background.ml:253-321`)가 받는다. 명령은 서버 수명 switch 위 `Keeper_msg_async` worker 에서 돈다. worker 는 자기 sandbox 를 만든다(`:188-195`). 호출한 턴의 factory 는 턴 수명이라 넘길 수 없다.
- 모델은 `request_id` 가 든 시작 결과를 받는다(`started_json`, `:96-104`). 이 결과는 성공이라 턴이 이어진다.
- 명령이 끝나면 worker 가 영수증을 Keeper 의 outbox 에 쓰고(`deliver`, `:109`) 깨운다(`keeper_client_tool_outbox_wake.ml:36-62`). 깨움은 영수증마다 `Tool_result_ready` stimulus 를 큐에 넣는다. `post_id` 는 영수증 id 에서 나온다. 영수증을 ACK 할 때까지 같은 stimulus 를 다시 알린다(`:52` 주석). 깨움이 닿지 못해도 영수증은 남고, maintenance pulse 가 다음 주기에 찾는다(`keeper_execute_background.ml:107-108` 주석).
- 영수증의 필드는 `thread_id`, `turn_id`, `call_id`, `tool_name`, `arguments`, `response` 다. 작업 id 는 없다(`keeper_client_tool_outbox.mli:7-16`). outbox 는 Keeper 단위다.
- run 하나가 첫 호출에서 outbox 전체를 한 번 읽고 그 snapshot 을 끝까지 쓴다(`keeper_client_tool_outbox.mli:243-248`, `.ml:545-555`). 끝난 턴이 `Completed` 일 때만 snapshot 을 지운다. 체크포인트로 끝나거나 입력을 기다리며 끝나면 지우지 않는다(`.ml:592-607`).
- 그래서 run 도중 쓰인 영수증은 다음 run 이 싣는다. 순찰 턴이든 직접 턴이든 먼저 시작해 `Completed` 로 끝나는 run 이 읽고 지운다. 이것은 `RFC-retained-results-carrier-shrinks-to-an-address` 의 「run 마다 하나인 carrier」와 같은 계약이다.
- 경로가 쓰는 조건이 있다. Keeper 의 lane 에 든 후보 runtime 이 모두 영수증을 받을 수 있어야 한다. 받지 못하는 runtime 은 Vibe 하나다(`keeper_client_tool_outbox_wake.ml:3-23`). 아니면 `Nothing was started` 로 거절한다(`keeper_execute_background.ml:257-263`).

### 3.5 도는 중에 모델이 보는 것

- 도구 결과 뒤 요청마다 그 run 이 시작한 뒤 큐에 도착한 행이 붙는다. `Tool_result_ready` 행은 `receipt_id`, `call_id`, `tool`, `outcome` 만 보인다. 결과는 없다(`RFC-arrived-stimuli-reach-the-running-turn`, `keeper_arrived_stimuli.ml`, #48959 #50365 #50577).
- 대기 중인 채팅 작업의 개수는 Agent Core 의 도구 뒤 요청에만 붙는다(`keeper_run_tools_hooks.ml:660-690`, `keeper_waiting_operations.mli`, #49091). `Keeper_waiting_operations` 를 쓰는 파일은 이것 하나다. 공식 클라이언트 경로에는 이 블록이 없다.
- 이 블록은 개수만 말하고 아무것도 시작하거나 끝내지 않는다. 어떻게 할지는 Keeper 가 정한다(`keeper_waiting_operations.mli:1-10`).
- Execute 의 도구 설명은 이미 말한다. 기다림이 있는 `sleep` 루프는 턴을 붙잡고, `run_in_background` 는 즉시 돌려주며, GitHub Actions run 은 `masc_schedule_create until_github_run` 으로 기다린다(`config/tools/Execute.toml:1-20`). `timeout_sec` 기본값은 600이다(`:53-56`). 이 파일은 11-09 08:37Z(#50516)에 들어갔다. 그 전에 같은 문장이 있었는지는 확인하지 않았다.

### 3.6 Delegate

- `masc_keeper_delegate` 는 `operation_id` 를 바로 돌려준다. 위임받은 Keeper 의 채팅 작업 큐에 일반 작업으로 들어간다. 끝나면 요청한 Keeper 에게 `Delegate_completed` 가 간다(`keeper_delegate_completion_wake.mli`).
- 대상이 턴 안에 있으면 결과에 `target_turn_age_s` 가 든다(`keeper_tool_surface_ops.ml:756`). `masc_keeper_delegate_targets` 는 대상별 `queued_count`, `oldest_queued_age_s`, `turn_age_s` 를 준다.

## 4. 후보 설계

기준은 1.1 이다. 후보마다 세 가지를 쓴다. 닿는 상한, 비용(계약이 바뀌는 범위, 도는 중 입력이 바뀌는지, 재현성, prompt cache), 틀렸다면 어디서 드러나는가.

### 4.1 (가) 도구 경계마다 영수증을 다시 읽는다

**내용.** run 이 모델 호출마다 outbox 를 다시 읽고, 새로 쓰인 영수증을 그 호출에 싣는다. 지금은 첫 호출의 snapshot 이 run 끝까지 쓰인다.

**닿는 상한.** 없다. 이 설계는 누가 슬롯을 쥐는지 바꾸지 않는다. 겹침 15.519 h 는 구조상 그대로다. 달라지는 것은 모델이 백그라운드 결과를 같은 턴에서 보는 시각이다.

**비용.**
- 계약. `run_carrier_load` 의 「run 마다 한 snapshot」(`keeper_client_tool_outbox.mli:243-248`)과 `settle_after_turn` 이 지우는 대상(`.ml:603-607`)이 바뀐다. snapshot 여러 개를 정산하는 타입은 이미 있다(`Consumption of snapshot list`, `.ml:609-614`). `RFC-retained-results-carrier-shrinks-to-an-address` 의 형태 바꾸기(`Inline` → `By_address`)가 run 마다 하나인 carrier 를 전제하므로 새 snapshot 마다 다시 정해야 한다.
- 도는 중 입력. Agent Core 에서 carrier 는 호출자 질문 바로 뒤에 놓여 앞 라운드의 서명된 reasoning 이 묶인 prefix 안에 든다(`place_carrier`, `.ml:571-590` 주석). 도는 중 carrier 가 자라면 그 prefix 가 바뀐다. prefix 를 건드리지 않으려면 도구 결과 끝에 붙이는 길뿐이고, 그 길은 이미 행 한 줄을 싣는다(3.5). 공식 클라이언트는 carrier 가 Start·Resume 때 한 번 들어간다(`RFC-retained-results-carrier-shrinks-to-an-address`). 도는 중에 넣을 자리는 도구 결과 끝뿐이다.
- 재현성. 라운드 k 의 입력이 영수증이 쓰인 시각에 달린다. 도착 행 블록이 이미 그렇다.
- prompt cache. 측정하지 않았다.

**장점.** 모델이 백그라운드 결과를 기다리며 폴링하지 않아도 된다. Keeper 가 결정한다는 원칙을 건드리지 않는다.

**단점.** 겹침 기준이 움직이지 않는다. 1.4 에서 시작 뒤 `sleep` 을 부른 66번은 끝나지 않은 호출 안에 있어서, 이 설계도 경계가 오기 전에는 결과를 보여 줄 수 없다.

**이 설계가 틀렸다면 어디서 드러나는가.** 배포 뒤 W1 과 같은 길이의 창에서 겹침 15.519 h 가 그대로이고, 백그라운드를 시작한 턴이 뒤에 `sleep` Execute 를 다시 부르는 비율(66 / 124)이 내려가지 않으면 모델이 「결과가 안 보여서」 기다렸다는 전제가 틀린 것이다.

### 4.2 (나) 영수증을 기다리며 턴이 끝난다

**지금 경로가 안 쓰이는 이유.** 1.2 와 1.4 가 보여 준다. 이유 하나로 가르지는 못했다(9절).
- 긴 호출 1,183번 중 `run_in_background` 는 0번이다. 간 호출 124번은 시작 호출이 2초 안에 끝났다. 시작한 일이 얼마나 걸렸는지는 재지 않았다.
- `run_in_background` 는 턴을 끝내지 않는다. 시작한 턴은 그 뒤 호출을 중앙값 33개 더 불렀다. 슬롯은 그대로다.
- 직접 턴의 긴 호출 중 `sleep` 이 든 것이 343번이고, 286번은 GitHub 확인 상태를 읽는다. 같은 기다림의 typed 길 `masc_schedule_create until_github_run` 은 직접 턴에서 55번, 전체로 255번 쓰였다. 그 기다림을 `sleep` 으로 한 60초 이상 호출은 직접 턴 286번, 전체 683번이다.
- 모델이 `sleep` 을 고르는 이유가 성향인지 도구 설명 탓인지 가르지 못했다. 설명 문장이 들어간 11-09 08:37Z 뒤에도 직접 턴의 `sleep` + `gh` 긴 호출은 줄지 않았다. 서버에 그 문장이 닿은 시각은 모른다(9절).

**내용.** 지금 경로에 세 가지를 더한다.
1. 모델이 영수증 하나(`request_id`)를 기다리겠다고 부르는 typed 호출이다. `deferred_kind` 에 variant 하나를 더해 나타낸다. 지금 `match` 가 variant 를 모두 이름으로 적고 있어서 컴파일러가 빠진 곳을 짚는다(`keeper_tools_agent_core_handler.ml:124-136`). 호출하면 턴이 체크포인트로 끝난다. 공식 클라이언트는 `host_stop` 의 `Terminal_tool_boundary { outcome = Durable_stimulus_deferred }` 로 벤더 루프를 끊는다(`runtime_official_client_tool.mli:13-30`, `:44-48`).
2. 직접 작업이 큐로 돌아가 「그 영수증이 outbox 에 생길 때까지 claim 못 함」으로 남는다. `blocked_queued_scopes` 에 이유 하나를 더하는 모양이다. 가장 가까운 선례는 `Input_wait` 다. 모델이 요청한 입력이 올 때까지 기다린다(3.3). 영수증이 이미 있을 때 호출하면 바로 claim 할 수 있어야 한다. outbox 는 `request_id` 로 영수증이 있는지 묻는 함수를 이미 가진다(`contains_call`, `keeper_client_tool_outbox.mli:115`).
3. 그 영수증은 기다리는 작업이 소유한다. 영수증은 Keeper 단위여서 순찰 턴이 먼저 읽고 `Completed` 로 지울 수 있다(3.4). 그러면 재개한 작업은 받을 것이 없다. 소유자가 있는 영수증은 다른 run 의 carrier 와 ACK 에서 뺀다. 소유를 어디에 적을지는 9절에 있다.

순찰 턴은 작업이 아니므로 첫째만 있으면 된다. 영수증이 `Tool_result_ready` 로 깨운다.

모델이 쓰는 모양은 이렇다. `Execute` 를 `run_in_background: true` 로 불러 `sleep 240; gh pr checks N` 을 worker 에 맡기고, 받은 `request_id` 로 이 호출을 부른다. 턴이 끝나고 슬롯이 빈다. 명령이 끝나면 영수증이 쓰이고, 작업이 다시 claim 되어 영수증을 받고 이어진다.

정석에 가까운 모양이다. actor 모델에서 핸들러가 오래 걸리는 일을 밖으로 보내고 완료를 메시지로 받는 것(Erlang `gen_server` 의 `noreply` 와 나중 `reply`, Akka 의 `pipeTo(self)`)과 같다. 여기서 핸들러는 턴이고 메시지는 영수증이다.

**닿는 상한.** 겹침 15.519 h 전부다.
- 직접 턴 안 13.812 h 는 슬롯을 놓는 길이 지금 없는 곳이다. 그중 10.629 h 가 `sleep` 뒤 GitHub 확인 상태를 읽는 호출이다.
- 순찰 턴 안 1.707 h 는 호출이 끝난 뒤에야 슬롯을 넘기는 곳이다. 이 설계는 그 시각을 앞당긴다.
- 모델이 새 호출을 쓰지 않은 호출은 줄지 않는다. 상한은 쓰임의 몫을 말하지 않는다.
- 10.629 h 는 같은 날 쓰이는 별도 RFC(check 완료를 기다리는 감시, #51302)가 노리는 기다림과 겹친다. 하네스는 한 기준(1.1)으로 재서 같은 시간을 두 번 세지 않는다. 두 RFC 의 접점은 9절에 있다.

**비용.**
- 계약. (1) 새 `deferred_kind` variant 와 도구 정의(`config/tools/`). (2) claim 못 함의 새 이유. 실행 기록 `phase` 와 `has_claimable_queued` 를 건드리므로 저장소 스키마가 v3 에서 바뀐다(hard cut, 옛 데이터를 위한 코드 없음). (3) 영수증이 쓰이면 owner 가 claim 가능 여부를 다시 계산하는 연결. (4) 영수증 소유. outbox 나 작업 기록 한쪽이 바뀐다(hard cut). (5) 공식 클라이언트 resume. `defer_official` 이 이미 있으나 Resume 이 가능한 벤더 세션이어야 한다.
- 도는 중 입력. 바뀌지 않는다. 재개한 턴의 입력은 체크포인트와 영수증 carrier 다.
- 재현성. 같은 체크포인트와 같은 영수증이면 같은 입력이다. 턴이 끝나는 시각은 모델이 정한다.
- prompt cache. 쉬는 동안 prefix 가 식을 수 있다. 측정하지 않았다.

**장점.**
- 호스트가 턴을 끊지 않는다. Keeper 가 스스로 끝낸다.
- `sleep` 이 슬롯을 쥐던 시간이 빈다. worker, 영수증, 깨움, carrier, 체크포인트 재개는 있는 것을 쓴다.
- 같은 작업이 이어진다. 작업의 답이 같은 작업에서 나온다.
- 모델의 `sleep` 호출과 폴링 왕복이 없어진다.

**단점.**
- 모델이 불러야 쓰인다. 같은 기다림의 typed 길이 있어도 `sleep` 이 더 많이 쓰였다(직접 턴 55번 대 286번).
- 직접 작업의 답이 나중에 이어서 나온다. 요청한 쪽은 그동안 작업이 `Queued` 로 보인다(5절). 턴이 호출 하나를 보류하고 멈췄을 때 모델의 말이 맨 상태 줄로 나간 사고가 있었다(3.3). 이 호출은 모델이 스스로 부르므로 그 사고와 다르다. 다만 끝나는 턴의 마지막 말이 요청한 쪽에 어떻게 보이는지는 확인해야 한다.
- 영수증 소유로 outbox 계약이 바뀐다. 상태와 스키마 변경이 든다.

**이 설계가 틀렸다면 어디서 드러나는가.** 도입 뒤 W1 과 같은 길이의 창에서 1.2 의 「직접 · `sleep` 있음 · `gh` 확인」 행(286번, 기다림 10.629 h)이 재측정 잡음(0.432 h) 밖으로 줄지 않으면 모델이 새 호출을 쓰지 않은 것이다. 줄었는데 큐 대기 합과 p90 이 줄지 않으면 겹침이 대기의 원인이 아닌 것이다. 재개한 작업의 첫 요청에 기다리던 영수증이 없으면 소유 규칙이 틀린 것이다.

호스트가 도착한 채팅 작업을 이유로 직접 턴의 호출을 떼어 내는 변형은 제안하지 않는다(7절).

### 4.3 (다) 한 Keeper 안에서 턴 둘이 동시에 돈다

brief 의 (다)는 순찰 턴과 채팅 턴의 동시 실행이다. 측정은 채팅 턴과 채팅 턴이 대부분이다(1.2, 1.3). 여기서는 두 경우를 함께 다룬다.

**내용.** 한 Keeper 의 슬롯을 하나에서 여럿으로 바꾼다. 앞 작업이 긴 호출에 있어도 다음 작업이 바로 시작한다. 턴은 끝까지 돈다. 양보가 필요한 이유(슬롯 하나)가 없어진다.

**닿는 상한.** 다른 채팅 작업이 도는 동안의 대기 130.45 h(66.4%)와 순찰 턴이 쥔 동안의 대기다. 긴 Execute 밖에서 기다린 시간(약 92.6 h)에도 닿는 것은 이 후보뿐이다.

**깨지는 곳.** 코드에서 읽은 불변식과 동시 실행 때 달라지는 것이다.

| 불변식 | 있는 곳 | 동시 실행이 되면 |
|---|---|---|
| 도는 턴 한 칸 | `keeper_owner.ml:453`, `:1816-1834` | 시작 조건이 사라지고 칸이 집합이 된다 |
| 취소 능력 하나 | `keeper_owner.ml:466` | interrupt·stop 이 가리킬 child 를 정해야 한다 |
| `running` 행 하나 | `keeper_chat_operation_store.ml:97`, `:128-129`, 스키마 `:85` | 인덱스 둘이 바뀌고 스키마가 v3 에서 바뀐다 |
| 영수증 snapshot 은 run 마다 하나 | `keeper_client_tool_outbox.ml:545-555`, `:592-607` | **[추정]** 두 run 이 같은 영수증을 싣는다. 먼저 `Completed` 한 쪽이 지우고 다른 쪽은 이미 지워진 영수증을 정산한다. 두 모델이 같은 효과를 다시 일으킬 수 있다 |
| 벤더 세션 하나 | `keeper_official_client_session_store.ml:1487-1535` | 둘째 턴은 `Turn_already_inflight` 로 거절된다(`:1535`). 새 Start 는 대화를 잇지 못한다 |
| 체크포인트 | `keeper_checkpoint_store.mli:695-705`(원본 참조가 일치할 때만 저장하는 `save_agent_core_if_source`) | 원본 참조가 다르면 저장이 거절된다. 거절된 턴의 일이 어디로 가는지 읽지 않았다 |

- 과거 사고(3.1)는 체크포인트 덮어쓰기였다. 지금은 원본 참조가 다르면 저장이 거절된다. 이 검사가 그 사고를 막는지는 확인하지 않았다. 거절된 쪽의 일이 사라지는지도 읽지 않았다.
- 헌법의 실패 조건에 「이전 턴과 다음 턴의 기억이 올바르게 이어지지 않는다」가 있다. 동시에 도는 두 턴은 서로의 진행 중 출력을 입력에 갖지 못한다.
- 이 표는 읽은 것만 적었다. 작업 공간·sandbox·librarian·Keeper 메타 카운터는 읽지 않았다(9절).

**비용.**
- 계약. 위 표의 여섯 곳과 읽지 않은 곳. 코드를 쓰기 전에 상태 기계 TLA+ 모델(`BugAction` = 둘째 동시 admission)이 먼저다.
- 도는 중 입력. 턴마다 바뀌지 않는다. 다만 턴 사이 기억이 이어지지 않는다.
- 재현성. 턴의 순서가 시각에 달린다.
- prompt cache. 같은 prefix 로 요청이 둘 나란히 나간다. 측정하지 않았다.

**장점.**
- 호스트가 턴을 끊을 이유가 없다. 「턴은 끝까지 돌고 다음 행동은 Keeper 가 고른다」와 맞는다.
- 긴 Execute 에 한정되지 않는다. 대기 130.45 h 에 닿는다.

**단점.**
- 변경이 가장 크다. 이미 사고가 난 곳을 다시 연다.
- actor 모델의 반대 방향이다. actor 는 한 번에 메시지 하나를 처리하고, 동시성은 actor 를 늘려서 얻는다. MASC 에서 그 길은 Keeper 를 더 두거나 일을 다른 Keeper 에게 위임하는 것이다.

**이 설계가 틀렸다면 어디서 드러나는가.** 같은 Keeper 의 서로 다른 `keeper_turn_id` 두 개가 겹친 구간에 같은 `input_fingerprint` 의 Execute 를 부른다. 또는 체크포인트 저장 거절과 `Turn_already_inflight` 가 늘어난다.

## 5. Delegate 에 주는 것

Delegate 는 이 RFC 가 바꾸지 않는다. 읽은 것과 이 RFC 가 닿는 곳만 적는다.

**[사실]** W1 의 장부 값이다.

| 값 | 개수 |
|---|---:|
| `masc_keeper_delegate` 호출 | 1,506 (받아들인 것 1,489, 못 받은 것 17) |
| 받아들인 결과에 `target_turn_age_s` 가 든 것 | 602 (중앙값 171초, 최대 8,494초) |
| `masc_keeper_delegate_status` 호출 | 939 (작업 357개) |
| 그 호출의 상태 | `Running` 407, `Queued` 315, `Succeeded` 167, `Failed` 36, 상태 없음 14 |
| `masc_keeper_delegate_targets` 호출 | 383 |

- 제출은 이미 비동기다. 요청한 Keeper 는 `Delegate_completed` 로 깨어난다. 그런데 status 를 939번 불렀고 722번(76.9%)이 `Running` 이나 `Queued` 였다.
- 기다림은 대상 Keeper 의 큐다. 1.3 에서 `agent` 채널 대기가 183.468 h 이고 그중 69.4% 가 다른 채팅 작업이 도는 동안이다. 위임 요청과 Keeper 사이 메시지가 이 채널에 같이 든다. 둘을 가르지 않았다.
- 바쁨의 노출은 턴의 나이와 큐 길이다. 대상이 Execute 안에 있다는 사실은 어느 도구도 말하지 않는다.
- #51242(2026-11-11T05:24:47Z 병합, `475c95443e73`)는 없는 Keeper 이름으로 위임할 때 등록된 이름을 알려 준다. 기다림과 무관하다. W1 의 못 받은 17번을 원인별로 가르지 않았다.

**이 RFC 가 주는 것.**
- (가): 없다.
- (나): 대상의 도는 작업이 영수증을 기다리며 끝나면 대상의 슬롯이 비고, 큐 뒤 위임이 시작한다. 닿는 상한은 겹침 42.457 h 다. 채널별로 나누지 않았다. `agent` 채널이 대기의 93.4% 라서 대부분 이쪽일 것이다. **[추정]** 위임받은 작업이 영수증을 기다리는 동안 `masc_keeper_delegate_status` 는 `Queued` 를 보인다. 대상이 Execute 안에 있다는 사실을 말하는 필드는 아니다.
- (다): 위임이 대상의 긴 호출을 기다리지 않는다. 여러 Keeper 가 같은 대상을 고르는 경우의 순서는 이 RFC 가 정하지 않는다.
- 요청한 쪽의 status 폴링은 어느 후보도 바꾸지 않는다.

Keeper 를 고르는 것은 요청한 쪽이다. `masc_keeper_delegate_targets` 는 이미 큐 길이와 턴 나이를 준다. 호출은 383번이고 제출은 1,506번이다. 두 값을 짝지어 보지는 않았다. 이것은 Delegate 의 일이라 여기서 다루지 않는다.

## 6. 하네스

측정 스크립트와 그 시험은 구현 PR 과 다른 변경에 둔다(#51284). 구현이 기준을 못 바꾸게 하는 장치다.

**고정하는 것.**
1. `queue_wait_overlap.py` 를 `--hold-s 60` 으로, 72시간 창에서 돌린 값. 기준값은 W1 의 15.519 h(Keeper 시간), 42.457 h(작업별 합), 196.34 h(큐 대기 합)다.
2. 위 값의 분할: 턴 종류, 명령 `sleep` 여부와 `gh` 확인 여부(측정용), runtime(1.2).
3. 큐 대기의 분위수: 중앙값 7.8초, p90 1,527.6초. 이 값이 필요한 이유는 60초 임계가 측정의 일부라서, 호출을 임계 아래 조각으로 쪼개면 겹침이 줄어드는데 대기는 그대로이기 때문이다.
4. 기다림을 슬롯 밖으로 보내는 길의 호출 수: `masc_schedule_create until_github_run` 255번(직접 턴 55), 같은 기다림을 `sleep` 으로 한 60초 이상 Execute 683번(직접 턴 286)이다.

**읽는 규칙.**
- 같은 창을 다시 재면 값이 달라진다(15.087 h / 15.519 h). 이 범위 안의 변화는 읽지 않는다.
- 창마다 Keeper 와 일이 다르다. 전체 합을 창끼리 빼지 않고, 같은 창 안의 분할 행과 Keeper 별 행으로 읽는다.
- 겹침이 줄었는데 `queue_wait` 합이 같으면 기다림이 다른 곳으로 옮겨 간 것이다.
- 4 의 두 값은 함께 읽는다. 새 호출이 늘었는데 `sleep` 이 그대로면 모델은 둘을 같이 쓴 것이다.

**(나)·(다)를 위한 검사.**
- 깨움이 헛됐는가. 재개한 작업의 첫 요청에 기다리던 `request_id` 의 영수증이 없는 경우다. 다른 run 이 먼저 읽고 지웠거나 소유 규칙이 틀린 것이다. `Tool_result_ready` 로 시작한 순찰 턴의 첫 요청이 영수증을 0개 싣는 경우도 센다. 깨움 하나와 턴 시작은 같지 않다(`keeper_client_tool_outbox_wake.ml:52` 주석).
- 깨움을 놓쳤는가. 상태 검사다. 영수증을 기다리며 claim 못 하는 작업이 있고, 그 영수증이 outbox 에 있고, 도는 턴이 없는 상태가 한 번이라도 있는가. 시간 임계 없이 정확히 가려진다. 저장소와 outbox 를 같이 읽는 스크립트와, owner 시험에서 모든 drain 단계와 서버 재시작 직후마다 확인하는 시험을 둔다. 시각으로 푸는 대기가 재시작에서 깨움을 잃은 선례가 있다(3.3).
- 효과가 두 번 났는가. 같은 Keeper 에서 서로 다른 `keeper_turn_id` 두 개가 같은 `input_fingerprint` 의 Execute 를 부른 경우. 장부 행에 있는 키만 쓴다.
- TLA+. `NextBuggy` 는 영수증 없이 다시 시작하는 행동, 다른 run 이 소유자 있는 영수증을 지우는 행동, 둘째 동시 admission 을 `BugAction` 으로 모델링한다. 정상 설정과 버그 설정을 모두 돌린다.

**(가)를 위한 검사.** 백그라운드를 시작한 턴이 뒤에 `sleep` Execute 를 부르는 비율(W1 에서 66 / 124).

## 7. 하지 않는 것

- 호스트가 도착한 채팅 작업을 이유로 직접 턴의 호출을 떼어 내거나 턴을 끝내는 규칙. 강제 양보다. `RFC-backlog-never-preempts-a-running-turn` 2절은 도는 턴을 멈추는 일을 채팅 작업·승인·직접 입력으로 좁히고 나머지는 Keeper 가 끝낼 때 정하게 한다. 헌법 `gates.default` 도 하드 게이팅을 기본으로 두지 않는다. 이 변형은 직접 턴까지 강제 양보를 넓히고, 호출이 도는 중에 끊으려면 명령을 서버 worker 가 처음부터 쥐어야 한다.
- 「긴」을 시간 임계(몇 초 이상)로 가르는 규칙. 헌법 `magic_number`. 이 RFC 의 60초는 측정의 정의이고 제품 규칙이 아니다.
- 명령 글자(`sleep`, `gh`)로 흐름을 가르는 규칙. 헌법 `string_matching`. 1.2 의 분류는 측정용이다.
- Keeper 프롬프트나 도구 설명에 「기다릴 때는 이렇게 하라」는 문장을 더하는 일.
- Delegate 의 재설계. 5절은 읽은 것과 닿는 곳만 적는다.
- 옛 영수증·옛 실행 기록을 읽는 코드. hard cut 이다.

## 8. 사용자가 정할 것

정석 쪽을 근거와 대가를 달아 먼저 쓴다.

1. **어느 후보를 쓸지.**
   - 추천: (나)를 쓴다. (가)와 (다)는 쓰지 않는다.
   - 근거:
     - 겹침 15.519 h 의 89.0%(13.812 h)가 직접 턴 안이다. 직접 턴이 채팅 작업이 기다린다는 이유로 슬롯을 놓는 길은 없다(3.2).
     - 그 가운데 10.629 h(68.5%)는 `sleep` 뒤 GitHub 확인 상태를 읽는 호출이다. 그 명령을 백그라운드 worker 에 맡기고 영수증을 기다리면 같은 기다림이 슬롯 밖으로 간다. worker, 영수증, 깨움, 체크포인트 재개는 이미 있다.
     - 직접 작업이 입력을 기다리며 슬롯을 놓는 길(`InputRequired`)이 이미 있다. 새 것은 「영수증을 기다린다」는 이유 하나와 영수증 소유 규칙이다.
     - actor 모델의 정석과 같다(4.2). (가)는 기준을 못 움직인다. (다)는 변경이 가장 크고 사고가 난 곳을 다시 연다.
   - 대가: 새 도구, 저장소 스키마 변경(hard cut), 영수증 소유 기록(hard cut), 공식 클라이언트 resume 경로가 든다. 직접 작업이 기다리는 동안 요청한 쪽에는 `Queued` 로 보인다. 코드보다 상태 기계 RFC 와 TLA+ 모델이 먼저다.
   - 모르는 것: 모델이 새 호출을 쓸지. 같은 기다림의 typed 길이 있어도 `sleep` 이 더 많이 쓰였다(직접 턴 55번 대 286번). 도입 뒤 같은 창에서 1.2 의 「직접 · `sleep` 있음 · `gh` 확인」 행이 재측정 잡음 밖으로 줄지 않으면 (나)를 지운다.
2. **한 Keeper 안의 동시 실행(다)을 허용할지.**
   - 추천: 지금은 허용하지 않는다.
   - 근거: 닿는 몫은 가장 크다(대기 130.45 h). 그러나 `RFC-0225` 의 사고가 난 곳을 다시 열고, 영수증·벤더 세션·체크포인트 저장 거절이 한꺼번에 바뀐다.
   - 대가: 대기 130.45 h 의 구조는 그대로다. 동시성은 Keeper 를 늘리거나 위임 대상을 고르는 쪽에서 얻는다.
   - (나)를 도입한 뒤 같은 하네스로 다시 잰다. 긴 Execute 밖의 대기(약 92.6 h)가 남아 있으면 그때 (다)를 상태 기계 RFC 로 연다. 허용하기로 하면 상태 기계 RFC 와 TLA+ 모델이 코드보다 먼저다.
3. **도는 중에 모델 입력이 바뀌어도 되는지.**
   - 지금도 도착한 행 한 줄은 도구 결과 끝에 붙는다(3.5). 이 길은 그대로 둔다.
   - 추천: 영수증 본문이나 carrier 가 도는 중에 바뀌게 하지 않는다. prefix 를 바꾸고(4.1), 겹침 기준을 움직이지 못한다.
   - 대가: 백그라운드 결과를 보려면 `keeper_composition_status` 를 계속 불러야 한다. 16 / 124번이 그렇게 했다. (나)를 쓰면 이 폴링이 호출 하나로 줄어든다.

## 9. 확인하지 못한 것

- 같은 날 쓰이는 「check 완료를 기다리는 감시」 RFC(#51302)와의 접점. 그 RFC 가 직접 작업을 열어 둔 채 기다리게 하는지 모른다. 열어 두지 않으면(예약한 뒤 작업이 끝난다) (나)가 그 자리를 채운다. 열어 두면 두 설계가 같은 상태를 두 번 만든다. 한쪽이 영수증의 출처가 되는 길이 있는지도 모른다.
- 예약(`masc_schedule_create`)한 뒤 직접 작업이 어떻게 끝나는지. 코드를 읽지 않았다. 모델이 예약 대신 `sleep` 을 고르는 이유가 거기 있는지 모른다.
- (나)의 두 번째 부분(영수증을 기다리며 claim 못 함)이 `Input_wait` 처럼 `recovery_origin` 의 새 variant 하나로 되는지, 다른 상태가 필요한지. `keeper_semantic_execution.ml` 의 전이는 일부만 읽었다.
- 직접 턴이 도중에 끝나는 길이 `Generic_deferred` 와 `InputRequired` 외에 더 있는지. `Generic_deferred` 결과를 내는 도구가 무엇인지는 따라가지 않았다. `chat_handoff` 가 직접 턴에 `Ok false` 인 이유는 코드에 없다.
- 공식 클라이언트에서 (나)의 첫 부분이 어떻게 보이는지. `host_stop` 은 읽었으나 Muse 와 Antigravity 의 resume 은 읽지 않았다.
- 영수증 소유를 outbox 영수증에 적을지 작업 기록에 둘지. outbox 의 receipt 는 vendor 세션 좌표를 담도록 만든 형식이다(`keeper_client_tool_outbox.mli:1-16`).
- 기다림을 호출 둘(백그라운드 시작과 기다림)로 나눌지, `Execute` 의 모드 하나로 합칠지. 나누면 앞서 시작한 백그라운드 호출의 영수증도 기다릴 수 있다. 합치면 호스트가 시작과 함께 기다림을 등록하므로 영수증이 먼저 오는 경우가 없다.
- (다)의 표에 없는 곳: 작업 공간, sandbox, librarian, Keeper 메타 카운터, 대화 기록 append 순서. 체크포인트 저장이 거절된 턴의 일이 어디로 가는지.
- 깨움이 헛됐는지 보는 값을 장부나 로그에서 이미 읽을 수 있는지. `Tool_result_ready` 로 시작한 턴과 그 턴의 첫 요청이 실은 영수증 수의 기록 경로는 확인하지 않았다.
- 직접 턴의 `sleep` 이 모델 성향인지 도구 설명 탓인지. 한 HTTP runtime 이 기다림의 80.9% 를 만든 이유를 가르지 못했다. Execute 의 설명 문장이 W1 안에서 모델에게 닿은 시각도 모른다(3.5). 직접 턴의 `sleep` + `gh` 긴 호출은 그 문장이 들어간 11-09 08:37Z 뒤에도 줄지 않았다. 시간당 개수는 11-10 16Z 뒤에 늘었다.
- 겹침에서 `agent` 채널 몫. 위임과 Keeper 사이 메시지를 가르지 않았다.
- 대기 중인 채팅 작업 개수 블록(#49091)이 W1 에 도는 서버에 있었는지. 현재 실행 중인 빌드 `f45e70258c29` 에는 있다.
- 읽지 못한 큐 저장소가 하나 있다(결과 JSON 의 `unreadable_stores` 에 든 `tool_usage`).
- 분할 스크립트는 저장소에 없다(1.5).
