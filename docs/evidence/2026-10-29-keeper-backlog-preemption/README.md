# Keeper 턴이 대기열 때문에 계속 멈추는 문제 — 측정 기록

해석과 제안은 [RFC-backlog-never-preempts-a-running-turn](../../rfc/RFC-backlog-never-preempts-a-running-turn.md) 에 있다.
이 문서는 잰 값과 그 값을 다시 얻는 방법만 적는다.

- 기준 head: `3e41385b549` (origin/main). 측정 구간(10-29 02:54Z 까지)에 도는 서버 바이너리도 이 커밋이었다. 서버는 10-29 03:07Z 에 `216f7ab8456` 으로, 06:06Z 에 `575e4665d63` 으로 다시 시작했다. 06:34Z 에 읽은 `/health` 의 `build.binary_commit` 은 `575e4665d63` 이다. 1단계 수정은 아직 병합되지 않았으므로 두 재시작 뒤의 값도 수정 전 값이다.
  `3e41385b549` 과 비교한 `lib/keeper` 차이는 `216f7ab8456` 이 85개 파일, `575e4665d63` 이 103개 파일이다. 멈춤 판정 파일 가운데 달라진 곳은 두 커밋에서 같다. `keeper_agent_run.ml` 3줄, `keeper_client_tool_outbox.ml` 8줄, `keeper_unified_turn.ml` 1줄을 더했고, 모두 이 문제와 관계없는 부분(미디어 저장소 인자, 오류 갈래, 타입 이름)이다. `keeper_chat_yield_request.ml`, `keeper_heartbeat_loop.ml`, `keeper_owner.ml`, `keeper_scheduled_turn_handoff.ml`, `keeper_tool_terminal_boundary.ml` 은 같다(`git diff --numstat 3e41385b549 <커밋>`).
- 읽은 곳: `~/me/.masc`. 결정 로그(`<keeper>.decisions.jsonl` 과 `.1`)가 있는 Keeper 이름은 43개이고, 2026-10-26 이후 턴이 있는 Keeper 는 30명이다.
  큐 스냅샷(`<keeper>/event-queue-v19.json`), 시스템 로그(`system_log_<날짜>.jsonl`), 예약 처리 원장(`<keeper>/consumed-schedule-occurrences-v1/`)도 읽었다.
- 측정 도구: `scripts/keeper-queue-probe.py`. 읽기 전용이다. 시간 구간(`--since`, `--until`)을 UTC 로 고정해서 같은 명령이 같은 값을 낸다. 큐 스냅샷(표 1)은 읽은 시각의 값이다.
- 표시: **[사실]** 은 데이터나 코드에서 확인한 것, **[추정]** 은 근거는 있지만 직접 보지 못한 것, **[확인 필요]** 는 아직 모르는 것이다.

| 파일 | 내용 |
|---|---|
| `before-fleet-daily.txt` | 모든 Keeper, 하루별 합계. 2026-09-01 ~ 10-29T02:54:34Z. |
| `before-fleet-hourly-1026.txt` | 모든 Keeper, 10-26 06~17시 시간별 합계. |
| `before-fleet-hourly-now.txt` | 모든 Keeper, 10-28T18Z ~ 10-29T04Z 시간별 합계. 서버 재시작(03:07Z) 앞뒤. |
| `before-fleet-hourly-0636.txt` | 모든 Keeper, 10-29T00Z ~ 06:35:55Z 시간별 합계. 두 번째 재시작(06:06Z) 뒤까지. |
| `before-fleet.txt` | 모든 Keeper, 2026-10-26T00:00Z ~ 10-29T02:54:34Z. 표 2~7. |
| `before-queue-now.txt` | 큐 스냅샷(표 1). 2026-10-29T05:02Z 에 읽음. |
| `before-schedule-latency-daily.txt` | 모든 Keeper, 시각이 된 예약의 전달 지연(표 8). due 날짜별, 10-24 ~ 10-29T02:54:34Z. |
| `before-schedule-latency-hourly-1026.txt` | 같은 표를 10-26 의 due 시각별로. |
| `before-schedule-latency-keepers.txt` | 같은 표를 Keeper 넷(`code-reviewer`, `context-reviewer`, `ocaml-agent-ic`, `pr-updater`)별로. 명령이 구간마다 앞줄에 있다. |
| `before-code-reviewer.txt` | `code-reviewer` 하나, 2026-10-22 ~ 10-29T02:54:34Z. 표 2~7b. |
| `before-code-reviewer-pingpong.txt` | `code-reviewer`, 10-29T02:08:00Z ~ 02:47:00Z. 표 2~7b. |
| `before-code-reviewer-timeline.txt` | 같은 구간의 턴별 한 줄. |
| `before-code-reviewer-1026-timeline.txt` | `code-reviewer`, 10-26T12:30Z ~ 13:05Z 턴별 한 줄. 에이전트 코어 턴. |
| `before-ocaml-agent-ic.txt` | `ocaml-agent-ic`, 10-27T12:40Z ~ 10-28T00:45Z. 표 2~7b. |
| `before-ocaml-agent-ic-timeline.txt` | 같은 구간의 턴별 한 줄. |
| `tlc-*.txt` | TLC 5개 설정의 출력(RFC 4.1). `-workers 1`. |

각 파일의 첫 두 줄에 잰 시각과 명령이 있다. 결정 로그와 시스템 로그는 쌓이기만 하므로 `--until` 로 끊은 값은 다시 재도 같다.
로그 파일이 회전(rotation)으로 잘려 나가면 오래된 구간은 달라질 수 있다.

## 1. 열의 뜻

| 열 | 뜻 |
|---|---|
| `ckpt` | 턴이 `checkpoint` 로 끝난 수. 모델이 끝낸 게 아니라 서버가 중간에 멈춘 턴이다. |
| `durable` | `yielded_to_durable_stimulus` 로 멈춘 턴 수. 공식 클라이언트(Codex, Claude Code, Muse, Antigravity)는 도구 경계에서 큐에 채팅 작업이 있어서 멈춘 경우도 이 값으로 적는다(`keeper_agent_run.ml:272-276`). 체크포인트 수의 부분 집합으로 세지 않고 멈춤 이유로 센다. |
| `op_q` | `yielded_to_operation_queued` 로 멈춘 턴 수. 위 이유로 공식 클라이언트가 도구 경계에서 멈춘 턴의 `durable` 과 `op_q` 는 원인을 나눈 값이 아니다. Codex 직접 턴은 대기 채팅 작업 안내문을 받고 자연히 끝나면 `op_q` 로 적힌다. |
| `done` / `done+tool` | `completed` 로 끝난 수 / 그중 도구를 한 번 이상 쓴 수. |
| `ckpt_t01` | 체크포인트 턴 중 도구 호출이 0~1번인 수. |
| `yield%` / `dir_yld%` / `auto_yld%` | (`durable` + `op_q`) 턴 수를 전체 / 직접 턴 / 자율 턴 수로 나눈 값. |
| `dir_done%` | 직접 턴(채팅 작업) 중 `completed` 로 끝난 비율. #46437 이 보는 값이다. |
| `max_ret` | 큐 행이 체크포인트 턴에 admit 되고도 남은 횟수(`checkpoint_retentions`)의 최댓값. |
| `busy` (표 7) | 하트비트가 "owner 가 채팅 작업으로 바빠서 intake 전에 건너뜀"이라고 남긴 줄 수. |
| `consumed` / `again` (표 7) | 턴이 입력을 admit 했다는 로그(`turn entry: consumed stimulus`) 수 / 그중 같은 Keeper 의 앞선 턴이 이미 admit 했던 `stimulus_id` 인 수. 시스템 로그의 `keeper_name` 은 `system` 이라서 Keeper 이름은 줄 끝의 `(keeper=이름)` 에서 읽는다. |
| `max_repeat` (표 7b) | 같은 `stimulus_id` 가 admit 된 가장 많은 횟수. 같은 id 가 다시 나오는 이유는 체크포인트가 행을 남겨서일 수도 있고, 같은 대상(게시글 등)에 새 알림이 와서일 수도 있다. 이 값만으로 구분하지 않는다. |

## 2. 관찰

### 2.1 하루별 멈춤 (모든 Keeper, `before-fleet-daily.txt`)

**[사실]** 결정 로그는 2026-08-29 부터 남아 있다. 아래는 10-15 이후이고, 09-01 ~ 10-14 도 같은 파일에 있다(`yield%` 는 대부분 0~5%).

| 날 (UTC) | 턴 | `durable` | `op_q` | `yield%` | `auto_yld%` | `dir_done%` |
|---|---|---|---|---|---|---|
| 10-15 | 247 | 2 | 1 | 1.2% | 1.2% | (직접 턴 0) |
| 10-16 | 1,179 | 17 | 24 | 3.5% | 3.5% | 17.3% |
| 10-17 | 773 | 6 | 56 | 8.0% | 2.1% | 8.8% |
| 10-18 | 500 | 4 | 38 | 8.4% | 2.4% | 59.0% |
| 10-19 | 1,245 | 10 | 48 | 4.7% | 1.5% | 73.9% |
| 10-20 | 1,596 | 22 | 112 | 8.4% | 3.1% | 57.6% |
| 10-21 | 2,334 | 17 | 293 | 13.3% | 2.1% | 45.8% |
| 10-22 | 2,028 | 12 | 24 | 1.8% | 0.8% | 89.9% |
| 10-23 | 3,190 | 26 | 468 | 15.5% | 2.0% | 46.5% |
| 10-24 | 1,501 | 16 | 133 | 9.9% | 2.4% | 63.3% |
| 10-25 | 2,091 | 5 | 139 | 6.9% | 2.1% | 78.4% |
| 10-26 | 4,253 | 525 | 258 | 18.4% | 14.6% | 47.8% |
| 10-27 | 3,793 | 793 | 458 | 33.0% | 26.2% | 41.4% |
| 10-28 | 4,783 | 1,113 | 467 | 33.0% | 25.8% | 37.9% |
| 10-29 (02:54Z 까지) | 490 | 139 | 62 | 41.0% | 29.3% | 20.2% |

- 10-15 ~ 10-25 합계: 턴 16,684, `durable` 137, `op_q` 1,336, `yield%` 8.8%, `auto_yld%` 2.1%, `dir_yld%` 36.4%, `dir_done%` 54.3%.
- 10-26 ~ 10-29T02:54Z 합계: 턴 13,319, `durable` 2,570, `op_q` 1,245, `yield%` 28.6%, `auto_yld%` 22.2%, `dir_yld%` 59.9%, `dir_done%` 40.1%.
- `durable` 만 보면 하루 2~26개에서 525개 이상으로 늘었다. `op_q` 도 하루 121개에서 399개로 늘었다(10-26 이후는 3.1일). 늘어난 몫이 큰 쪽은 `durable` 이다.
- 직접 턴은 10-26 앞에도 `dir_yld%` 가 3~54% 로 높은 날이 많았다. 채팅 작업이 새 채팅에 멈추는 일(`op_q`)이 오래된 동작이기 때문이다. 자율 턴의 `auto_yld%` 가 0.8~3.5% 에서 14.6~29.3% 로 오른 쪽이 새 현상이다.
- 늘어난 `durable` 은 한 Keeper 에 몰려 있지 않지만 고르지도 않다. 10-26 ~ 10-28 `durable` 2,431개 중 `ocaml-agent-ic` 489, `context-reviewer` 437, `code-reviewer` 384, `ocaml-refactor-woman` 361, `pr-updater` 235, `you-never-change` 215 가 합 2,121개(87%)다(`before-fleet.txt` 표 2).

### 2.2 10-26 시간별 (`before-fleet-hourly-1026.txt`)

**[사실]**

| 시(UTC) | 06 | 07 | 08 | 09 | 10 | 11 | 12 | 13 | 14 | 15 | 16 | 17 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `durable` | 2 | 0 | 1 | 1 | 0 | 0 | 22 | 61 | 29 | 34 | 58 | 57 |
| `auto_yld%` | 5.5 | 0.0 | 8.1 | 2.0 | 1.8 | 3.5 | 22.9 | 20.3 | 16.9 | 17.7 | 33.7 | 31.3 |

- #46133 과 #46134 는 10-26T11:47Z 에 병합됐다. 병합 뒤 첫 서버 시작이 12:11Z(`logs/masc-start-1026-2111.log`, 21:11 KST)이고, 공식 클라이언트의 `durable` 첫 기록은 Claude Code 12:17:57Z, Muse 12:18:25Z, Codex 12:18:43Z 다.
  **[추정]** 그 시작에 두 변경이 들어 있었다고 본다. 바이너리 커밋을 그 시각에 확인하지는 않았다.
- 그 전 열하루(10-15 ~ 10-25) 자율 턴 중 공식 클라이언트는 Claude Code 2,732개에서 `durable` 0, Codex 2,525개에서 7, Muse 2,623개에서 0, Antigravity 330개에서 0 이었다.

### 2.3 모든 Keeper, 2026-10-26 00:00Z ~ 10-29 02:54:34Z (`before-fleet.txt`)

**[사실]**

- 턴 13,319개 중 3,815개(28.6%)가 체크포인트로 끝났다. `durable` 2,570, `op_q` 1,245.
- `completed` 8,314개 중 도구를 쓴 턴이 6,252개다. 체크포인트 턴 중 도구를 0~1번 쓴 턴이 1,458개(38.2%)다. 도구를 6번 이상 쓰고 멈춘 턴도 981개(25.7%) 있다(표 3).
  체크포인트나 `completed` 로 끝난 턴 중 도구를 쓴 10,022개에서 3,770개(38%)가 체크포인트로 끝났다.
- 실행 경로와 런타임별로 보면(표 4) `durable` 은 자율 턴(`autonomous_cycle`)의 에이전트 코어 584, Codex 398, Muse 282, Claude Code 180과 직접 턴(`direct_turn`)의 에이전트 코어 895, Claude Code 158, Codex 55, Muse 18 이다.
- 체크포인트로 끝난 비율이 높았던 Keeper 와 날(UTC):

  | Keeper | 날 | 턴 | 체크포인트 | `durable` | `op_q` | 비율 |
  |---|---|---|---|---|---|---|
  | `ocaml-agent-ic` | 10-27 | 200 | 168 | 168 | 0 | 84.0% |
  | `ocaml-agent-ic` | 10-28 | 436 | 408 | 252 | 156 | 93.6% |
  | `ocaml-agent-ic` | 10-29 (02:54Z 까지) | 63 | 63 | 31 | 32 | 100% (`done` 0) |
  | `ocaml-refactor-woman` | 10-28 | 489 | 478 | 246 | 232 | 97.8% |
  | `code-reviewer` | 10-27 | 395 | 303 | 151 | 152 | 76.7% |
  | `context-reviewer` | 10-27 | 542 | 343 | 194 | 149 | 63.3% |

- `durable` 로 끝난 턴이 끊기지 않고 이어진 가장 긴 구간은 `ocaml-agent-ic` 의 120턴이다(10-27T12:49Z ~ 10-28T00:39Z). 다음은 `code-reviewer` 18턴, `context-reviewer` 15턴이다(표 6).
- 완료된 턴의 길이(표 5, 초): 전체 n=8,314 에서 p50 46, p90 356, p99 2,086, 최대 10,002. 자율 턴 n=7,396 에서 41, 340, 2,116, 10,002. 직접 턴 n=918 에서 107, 482, 1,374, 5,419.
- 시스템 로그에서 양보 판정이 첫 번째 대기 행의 종류(`head=`)를 남긴 양보는 380건이다. 로그 문구가 둘로 나뉜다.

  | 로그 문구 | 판정 | head 별 건수 |
  |---|---|---|
  | `source turn yields to a new durable successor` | admit 한 행이 있는 자율 턴 (RFC 유형 B) | `tool_result_ready` 243, `ask_answered` 13, `keeper_delegate_completed` 8, `completion_authority_rejected` 3, `task_outcome` 3, `task_cancelled` 2 = 272 |
  | `autonomous turn yields to durable stimulus` | admit 한 행이 없는 자율 턴 (RFC 유형 A) | `schedule_due` 62, `board_signal` 31, `tool_result_ready` 13, `completion_authority_rejected` 2 = 108 |

  합치면 `tool_result_ready` 256(67.4%), `schedule_due` 62(16.3%), `board_signal` 31(8.2%)이다. 유형 B 의 `tool_result_ready` 는 `pr-updater` 100, `code-reviewer` 53, `context-reviewer` 34 건이 많다.
  `new durable successor` 줄은 #46125(10-27T09:20Z 병합) 앞에는 없다. 시스템 로그에서 10-24 ~ 10-26 0줄, 10-27 34줄(처음 10:30:03Z), 10-28 223줄, 10-29 33줄이다.
  `Tool_result_ready` 를 admit 했다는 줄은 10-25 19줄, 10-26 39줄, 10-27 1,297줄, 10-28 10,892줄이다.
- `durable` 2,570턴 중 head 가 로그에 남은 양보는 380건(14.8%)이다. 나머지 2,190건은 head 를 남기지 않는 분기에서 났거나 도구가 스스로 deferred 로 답한 멈춤이다.
  **[추정]** 로그 없이 `Durable_stimulus_waiting` 을 돌려주는 곳은 예약으로 멈추는 두 곳(`keeper_chat_yield_request.ml:31`, `keeper_unified_turn.ml:500-518`), Gate 재생 양보(`keeper_unified_turn.ml:489`), 채팅 분기(`keeper_chat_yield_request.ml:17`), deferred 도구(`keeper_tool_terminal_boundary.ml:3`)다. 분기별 건수는 로그로 나눌 수 없다.
- 시스템 로그에서 `schedule_due` 를 admit 했다는 줄 중 이미 앞서 admit 한 id 의 비율: 10-24 17.8%, 10-25 8.3%, 10-26 12.7%, 10-27 6.4%, 10-28 31.7%, 10-29 44.5%(하루 일부). 체크포인트가 `Schedule_due` 를 남기도록 바꾼 #46202 는 10-28T03:01Z 에 병합됐다.
- 하트비트가 "owner 가 채팅 작업으로 바빠서 intake 전에 건너뜀"이라고 남긴 줄이 3,147개다(표 7).

### 2.4 `code-reviewer` 의 직접 턴 ↔ 자율 턴 왕복

**[사실]** 10-26T12:36Z ~ 12:59Z (`before-code-reviewer-1026-timeline.txt`, 에이전트 코어)

- 13턴이 연속 12쌍 모두에서 실행 경로가 바뀌었다. 앞 11턴에서 직접 턴 5개는 모두 `durable`(도구 1~19번, 70~251초), 자율 턴 6개는 모두 `op_q`(도구 2~5번, 22~568초)로 끝났다.
- 에이전트 코어는 `durable` 과 `op_q` 를 따로 적는다. 직접 턴이 대기 입력에, 자율 턴이 기다리는 채팅 작업에 멈춘 것으로 읽힌다. #46133 병합 49분 뒤다.

**[사실]** 10-29T02:08Z ~ 02:47Z (`before-code-reviewer-timeline.txt`, `before-code-reviewer-pingpong.txt`, Claude Code)

- 64턴이다. 직접 턴 32, 자율 턴 32. 실행 경로가 바뀐 곳이 연속 63쌍 중 56쌍이다.
- 종료: `durable` 체크포인트 50(직접 26, 자율 24), `completed` 13(직접 6, 자율 7), `op_q` 1.
- `durable` 체크포인트 50턴 중 48턴이 도구를 1번만 썼다(2번 1턴, 6번 1턴). 길이는 중앙값 17.8초, p75 41.5초, 최대 175.8초다.
- 이 구간에 head 가 로그에 남은 양보는 0건이다. owner 바쁨 줄은 20개다.
- 같은 구간의 입력 admit(표 7b): `board_attention` 25개를 141번(한 개는 43번), `schedule_due` 4개를 27번(한 개는 15번).
- 주간 표(`before-code-reviewer.txt`)에서 `code-reviewer` 의 `durable` 은 10-22 ~ 10-25 에 0이고, 10-26 73, 10-27 151, 10-28 160, 10-29 51 이다. `op_q` 는 10-23 에 341로 높았다(다른 원인).

**[추정]** 두 구간 모두 같은 왕복이다. Claude Code 는 두 이유를 같은 `durable` 로 적어서 라벨로는 나누지 못한다. 10-29 구간의 근거는 head 로그가 0건이라는 점, 두 경로가 번갈아 도는 점, 코드(`keeper_chat_yield_request.ml:17`, `:31`)가 그 두 멈춤을 가진 점이다.

### 2.5 `ocaml-agent-ic`, 2026-10-27T12:49Z ~ 10-28T00:39Z (`before-ocaml-agent-ic.txt`, `before-ocaml-agent-ic-timeline.txt`)

**[사실]**

- 연속 120턴이 모두 자율 턴(에이전트 코어)이고 모두 `durable` 체크포인트다. 경로가 바뀐 쌍은 0이다.
- 턴 길이는 중앙값 332초(33~741초, 결정 로그 119턴). 도구 호출은 중앙값 3번(최대 13번).
- 쓴 도구는 `keeper_artifact_read` 123, `tool_execute` 122, `tool_read_file` 68, `tool_write_file` 15 등 일반 도구다. 턴 119개 중 70개의 `trigger_signals` 에 `scheduled_automation_due_ready` 가 있다.
- 입력 admit(표 7b, 10-27T12:40Z ~ 10-28T00:45Z): `schedule_due` 205개를 210번(5개만 두 번), `board_attention` 11개를 55번(한 개는 27번), `completion_authority_rejected` 1개를 54번.
- 예약 처리 원장(부록 B): 구간 안에 처리된 시각이 된 예약 199개, 도착 간격 중앙값 199초, 턴 120개 중 109개가 도는 동안 새 예약이 도착했다.
- 이 Keeper 의 3일(10-26 ~ 10-29)에 head 가 로그에 남은 양보는 15건이다(`schedule_due` 13, `completion_authority_rejected` 2).

**[추정]** intake 뒤에 도착한 예약에 멈추는 유형 D 가 연쇄를 만들었다. 새 예약이 턴마다 도착하고 같은 입력을 두 번 처리한 경우가 5개뿐인 점이 근거다. 남은 행을 다시 처리하는 연쇄가 아니다.
**[확인 필요]** 도구가 deferred 로 답해서 멈춘 경우는 배제하지 못했다. 이 도구들이 deferred 결과를 돌려주는지 확인하지 않았다.

### 2.6 서버 재시작 뒤 (`before-fleet-hourly-now.txt`)

**[사실]** 03:07Z 재시작 뒤에도 자율 턴이 멈춘 비율은 03Z 34.0%, 04Z 22.8% 다. 10-28T20Z ~ 10-29T00Z 에는 직접 턴 `dir_done%` 가 0.0~5.9% 였다(5시간 연속).

**[사실]** 06:06Z 에 서버가 `575e4665d63` 으로 다시 시작했다. 1단계 수정은 들어 있지 않다. 06:35:55Z 까지 읽은 값(`before-fleet-hourly-0636.txt`)은 아래와 같다. 06Z 는 앞 36분이다.

| 시간 (UTC) | 자율 턴 | 자율 턴이 멈춘 비율 | 직접 턴 | 직접 턴이 끝까지 간 비율 |
|---|---|---|---|---|
| 05Z | 62 | 16.1% | 7 | 71.4% |
| 06Z | 94 | 16.0% | 24 | 62.5% |

자율 턴이 멈춘 비율은 10-15~10-25 범위(0.8~3.5%)보다 높다. 직접 턴 수가 적어서 `dir_done%` 는 흔들린다.

### 2.7 큐와 영수증

**[사실]** `before-queue-now.txt` (2026-10-29T05:02Z, 서버 `216f7ab8456`).

- 큐 행이 있는 Keeper 25명, 합계 77행. `max_ret` 은 `ocaml-agent-ic` 31이고(가장 오래된 행 755시간), 나머지는 모두 1 이하다.
  03:59Z 에 읽었을 때는 `code-reviewer` 에 `tool_result_ready` 9행(`max_ret` 4), `code-reviewer-brother` `max_ret` 5 였다. 큐는 몇 분 단위로 달라진다.
- 가장 오래된 행이 700시간(29일)이 넘고 그 행이 `ask_answered` 인 Keeper 가 11명이다(`rust-hwp-guy` 1,029시간 등). 그중 8명(`hole-finder`, `indie-geek-blue`, `jazz-developer`, `rondo`, `rust-hwp-guy`, `simplifyer`, `tui-developer`, `won-chik`)은 `~/me/.masc/keepers/<keeper>.json` 의 `paused` 가 `true` 다.
  `msx-retro-mania`, `wkbl-front`, `ocaml-agent-ic` 는 `paused` 가 `false` 다. 앞의 둘은 `max_ret` 이 0이다. 이 현상은 이 RFC 의 대상이 아니다(RFC 6절의 7).

### 2.8 시각이 된 예약의 전달 지연 (`before-schedule-latency-*.txt`)

**[사실]** 예약 입력의 `due_at` 에서 같은 입력의 첫 `scheduled wake delivered` 로그 줄까지 걸린 초다(`--schedule-latency`). 입력은 `due_at` 이 속한 UTC 날로 묶었다. 아직 전달되지 않은 예약은 로그가 없어서 세지 않는다. 최근 날짜는 늦게 전달된 예약이 나중에 더해져서 다시 재면 값이 조금 달라질 수 있다.

| due 날 (UTC) | 건수 | p50 | p90 | p99 | 최대 | 한 건당 전달 | 두 번 이상 전달 |
|---|---|---|---|---|---|---|---|
| 10-24 | 538 | 70초 | 5,174초 | 22,380초 | 164,896초 | 1.22 | 10.2% |
| 10-25 | 699 | 24초 | 970초 | 29,480초 | 45,025초 | 1.09 | 5.0% |
| 10-26 | 1,920 | 15초 | 225초 | 2,830초 | 19,770초 | 1.14 | 5.2% |
| 10-27 | 1,400 | 36초 | 550초 | 5,040초 | 25,309초 | 1.07 | 4.7% |
| 10-28 | 1,134 | 18초 | 465초 | 5,680초 | 59,969초 | 1.52 | 19.6% |

Keeper 별 p50 / p90 (초). 괄호는 건수다.

| Keeper | 10-24 | 10-25 | 10-26 | 10-27 | 10-28 |
|---|---|---|---|---|---|
| `code-reviewer` | 25 / 1,772 (96) | 33 / 1,042 (122) | 37 / 887 (153) | 40 / 324 (184) | 14 / 313 (165) |
| `context-reviewer` | 168 / 5,505 (25) | 29 / 254 (71) | 19 / 88 (207) | 23 / 116 (254) | 14 / 159 (189) |
| `ocaml-agent-ic` | 64 / 612 (176) | 25 / 390 (266) | 20 / 356 (369) | 229 / 1,054 (340) | 326 / 574 (213) |
| `pr-updater` | 164 / 5,437 (17) | 1,184 (2) | 12 / 26 (259) | 12 / 37 (261) | 13 / 52 (256) |

- 10-26 을 due 시각별로 보면(`before-schedule-latency-hourly-1026.txt`) 00~11Z 의 p90 은 430~2,039초이고, 14Z 부터 25~137초다. #46133 은 11:47Z 에 병합됐고 서버는 12:11Z 에 다시 시작했다.
- **[사실]** `code-reviewer`(#46120 이 본 Keeper)의 p90 은 #46133 앞 이틀(10-24, 10-25)에 1,772초, 1,042초이고 뒤 이틀(10-27, 10-28)에 324초, 313초다. p99 는 앞 22,252초, 7,186초에서 뒤 11,384초, 5,812초이고 최대는 8시간 넘게 남아 있다.
- **[사실]** `ocaml-agent-ic` 는 반대다. p50 이 20~64초에서 229~326초로 늘었다. 이 Keeper 는 10-27 12:49Z 부터 120턴이 모두 체크포인트였다(2.5).
- **[사실]** 합계의 개선은 `pr-updater` 가 섞인 영향이 크다. 이 Keeper 는 10-26 부터 하루 약 260건을 내는데(p50 12초) 10-24, 10-25 에는 17건, 2건이었다. 합계로는 앞뒤를 비교하지 않는다.
- **[한계]** 앞 이틀(10-24 토요일, 10-25 일요일)과 뒤 이틀(10-27 화요일, 10-28 수요일)은 요일이 다르다. 예약 목록과 부하가 같다고 볼 수 없어서 원인은 가려내지 못한다. `code-reviewer` 의 p90 이 줄어든 것이 #46133 의 슬롯 예약 때문인지, 도는 턴을 끊은 때문인지도 나누지 못한다.
- 이 값은 수정 전 기준선이다. 배포 뒤 같은 표를 만들어 `code-reviewer` p90 이 10-27, 10-28 의 324초, 313초 근처에 머무는지, 10-24, 10-25 의 1,042~1,772초로 돌아가는지 본다(RFC 3.4 의 1, 4.3).

## 3. 코드 근거

`3e41385b549` 에서 직접 읽은 위치다.

| 무엇 | 위치 |
|---|---|
| outbox 의 영수증마다 `Tool_result_ready`(긴급도 `Immediate`) 한 행을 큐에 넣는다. | `lib/keeper/keeper_client_tool_outbox_wake.ml:34` `notify` |
| 영수증은 `Completed` 로 끝난 턴만 지운다. 어떤 `Yielded_*` 로 끝나도 남긴다. | `lib/keeper/keeper_client_tool_outbox.ml:270` `settle_after_turn` |
| 남은 영수증 전부를 다음 요청의 개발자 컨텍스트로 보낸다. | `keeper_client_tool_outbox.ml:230` `developer_context`, `keeper_codex_runtime.ml:1107`, `keeper_antigravity_runtime.ml:652`, `keeper_turn_driver_try_provider.ml:2450` |
| 체크포인트로 끝난 턴이 지우는 큐 행은 알림형(`Bootstrap`, `Board_signal`, `Board_attention`, `Hitl_resolved`)뿐이다. 나머지는 남기고 `checkpoint_retentions` 를 올린다. | `lib/keeper/keeper_heartbeat_loop.ml:613-631` `checkpoint_source_policy` |
| 유형 B: admit 한 행이 있는 자율 턴은 intake 뒤에 도착한 행 중 `source_may_preempt` 가 참인 종류에 멈춘다. `Tool_result_ready` 가 참이다. | `lib/keeper/keeper_unified_turn.ml:451` `source_may_preempt`, `:461` `make_autonomous_yield_probe`, `:494` |
| 유형 A: admit 한 행이 없는 wake(`Proactive_tick`, `Woken []`)는 대기 행이 하나라도 있으면 멈춘다. | `keeper_unified_turn.ml:232` `autonomous_yield_request_with_filter`, `:524` |
| 유형 D: B 에 해당하는 행이 없을 때 intake 뒤에 시각이 된 예약이 도착하면 멈춘다. Owner 가 받아들여야 한다. | `keeper_unified_turn.ml:500-518`, `lib/keeper/keeper_scheduled_turn_handoff.ml:10-18`, `:35-44` |
| 유형 C: 직접 턴은 예약 입력이 있으면 멈추고, 자율 턴은 기다리는 채팅 작업이 있으면 멈춘다. | `lib/keeper/keeper_chat_yield_request.ml:17`, `:31` |
| 공식 클라이언트는 도구 경계에서 `Operation_queued` 와 `Durable_stimulus_waiting` 을 모두 `Durable_stimulus_deferred` 로 끝낸다. | `lib/keeper/keeper_agent_run.ml:272-276` `official_client_tool_boundary` |
| 도구가 deferred 로 답하면 턴을 끝낸다(바꾸지 않음). | `lib/keeper/keeper_tool_terminal_boundary.ml:3` |
| 한 턴이 admit 하는 행의 상한. 기본 32. | `lib/keeper/keeper_heartbeat_stimulus_intake.ml:839`, `lib/config/env_config_keeper.ml:520` |
| owner 가 채팅 작업 중이면 자율 사이클은 intake 전에 건너뛴다. | `lib/keeper/keeper_heartbeat_loop.ml:1519` |

## 4. 한계

- 수정이 배포되기 전의 값이다. 수정 뒤 값(after)은 아직 없다. 배포 뒤 같은 명령으로 `after-*.txt` 를 이 폴더에 더하고, 첫 줄에 서버 `binary_commit` 을 적는다.
- 서버 하나(이 컴퓨터의 `~/me/.masc`)에서만 잼. 설정이 다른 배포에서는 값이 다를 수 있다.
- 큐 길이를 시간순으로 잰 값이 없다. 큐 스냅샷은 읽은 시각의 값이고 몇 분 단위로 달라진다. 영수증 개수(`kidsnote-slack-reader` 74개, 692KB)는 세션 중에 02:55Z 에 읽은 값이고 원본을 보관하지 않아서 해석에 쓰지 않았다.
- 유형 C·D, Gate, 채팅 분기, deferred 도구의 멈춤은 로그에 이유가 없다. 2.4 와 2.5 의 원인은 추정이다.
- `HEAD_PATTERNS` 는 로그 문구를 맞춰 센다. 수정 뒤에는 문구가 바뀌므로(`source turn yields to a queued chat operation`, `... an approved Gate resolution`) 도구가 새 문구도 센다.
- **[확인 필요]** 12:11Z 서버 시작에 #46133, #46134 가 들어 있었는지.
- **[확인 필요]** `ocaml-agent-ic` 의 도구가 deferred 결과를 돌려주는지.
- Mermaid 도식은 문법을 눈과 정적 점검으로만 확인했고 렌더하지 않았다.

## 부록 A: 하루별·시간별 합계

```
python3 scripts/keeper-queue-probe.py <base>/.masc/keepers --fleet-by day  --since 2026-09-01 --until 2026-10-29T02:54:34Z
python3 scripts/keeper-queue-probe.py <base>/.masc/keepers --fleet-by hour --since 2026-10-26T06:00:00Z --until 2026-10-26T17:59:59Z
```

## 부록 B: `ocaml-agent-ic` 예약 처리 원장

원장 파일 하나(`consumed-schedule-occurrences-v1/occurrence-*.json`)는 `witness.source_arrived_at`(예약 입력이 큐에 도착한 시각), `witness.applied_at_unix`(처리를 기록한 시각), `witness.disposition.kind` 를 가진다.

```python
import glob, json, datetime, bisect
UTC = datetime.timezone.utc
lo = datetime.datetime(2026, 10, 27, 12, 49, 0, tzinfo=UTC).timestamp()
hi = datetime.datetime(2026, 10, 28, 0, 41, 0, tzinfo=UTC).timestamp()
arrivals = []
for path in glob.glob("<base>/.masc/keepers/ocaml-agent-ic/consumed-schedule-occurrences-v1/occurrence-*.json"):
    witness = json.load(open(path)).get("witness", {})
    arrived, applied = witness.get("source_arrived_at"), witness.get("applied_at_unix")
    if witness.get("source_kind") == "schedule_due" and lo <= applied <= hi:
        arrivals.append(arrived)
arrivals.sort()
gaps = sorted(b - a for a, b in zip(arrivals, arrivals[1:]))
print(len(arrivals), "median gap", gaps[len(gaps) // 2])
turns = []
for path in glob.glob("<base>/.masc/keepers/ocaml-agent-ic.decisions.jsonl*"):
    for line in open(path, errors="replace"):
        row = json.loads(line)
        end, ms = row.get("ts_unix"), row.get("latency_ms")
        if row.get("event") == "turn" and end and ms and \
           datetime.datetime(2026, 10, 27, 12, 49, 15, tzinfo=UTC).timestamp() <= end <= \
           datetime.datetime(2026, 10, 28, 0, 39, 55, tzinfo=UTC).timestamp():
            turns.append((end - ms / 1000, end))
during = sum(1 for start, end in turns
             if (i := bisect.bisect_right(arrivals, start)) < len(arrivals) and arrivals[i] <= end)
print(len(turns), "turns,", during, "with a new schedule_due arriving while they ran")
```

결과: 처리된 예약 199개, 도착 간격 중앙값 199초, 턴 120개 중 109개.
