# 실행 길이와 도는 중 도착한 큐 행 측정 (2026-11)

`measure_runs_and_arrivals.py` 는 Keeper 의 실행(run)이 얼마나 오래 도는지, 도는 동안 그 Keeper 의 큐에 무엇이 도착하는지 재요.
raw trace 와 reaction ledger 를 읽기만 해요.
`docs/rfc/RFC-arrived-stimuli-reach-the-running-turn.md` 가 풀려는 기다림이 얼마나 되는지 재요.

## 다시 측정하기

```bash
python3 -I -B docs/evidence/runs-and-arrivals-2026-11/measure_runs_and_arrivals.py --base-path ~/me \
    --json-out after.json --svg-out after.svg
```

이 폴더의 `result.json`·`chart.svg` 는 2026-11-05T20:24Z 에 위 명령을 창 없이 돌린 결과예요. 읽는 데 10초 남짓 걸려요.
raw trace 는 오래된 순으로 지워져요. 19:39Z 에 읽은 값과 20:24Z 에 읽은 값만 해도 round 가 32,759개에서 32,286개로, 실행 중에 도착한 행이 1,791개에서 1,773개로 달라요. 그래서 다시 재면 값이 달라요. 값을 비교할 때는 `read_at_utc` 를 같이 보세요.
목록을 읽은 뒤 열기 전에 지워진 파일은 `unreadable_files` 에, JSON 이 아닌 줄은 `unreadable_lines` 에 세어요.
시험은 `python3 -B -m unittest discover -s docs/evidence/runs-and-arrivals-2026-11` 로 돌려요. Python 3.11 이상이 필요해요.

## 센 방법

- 실행: Keeper 의 raw trace 파일 하나(`.masc/keepers/<keeper>/raw-traces/turn-*.jsonl`)예요. 시작은 첫 줄의 `ts`, 끝은 마지막 줄의 `ts` 예요. 모델이 도구 호출 없이 답하거나 provider 오류가 나면(`run_finished.error`) 실행이 끝나요.
- round: 그 파일의 `before_turn_params` hook 기록 하나예요. 모델 요청 하나에 하나씩 있어요. 이 기록이 하나도 없는 실행은 `runs_without_rounds` 에 따로 세고 round 통계에서 빼요. 그런 실행 대부분은 `client_context_submission` hook 기록을 남겨요(`runs_without_rounds_with_client_context_submission`).
- 긴 실행: round 100개 이상, 400개 이상인 실행이에요.
- 도는 중 도착한 행: reaction ledger(`reaction-ledger/v7/YYYY-MM/DD.jsonl`)의 `event_queue_ack` 행 중, 도착 시각(`arrived_at_unix`)이 같은 Keeper 의 어떤 실행의 시작과 끝 사이인 행이에요. 같은 `event_id` 는 한 행으로 세어요.
- 범위: 그 Keeper 의 첫 trace 시작부터 마지막 trace 끝까지만 세어요. 더 오래된 trace 는 지워지고, 실행이 지워진 행은 쉬는 중에 도착한 행처럼 보여요.
- 막힌 시간: 도착부터 그 실행의 끝까지예요. 큐는 턴 사이에만 비우니 행은 적어도 이만큼 기다려요. 행이 자기 턴을 시작하는 시각은 더 늦어서 실제 기다림은 이보다 길어요.
- 다음 round: 도착한 뒤 같은 실행의 첫 `before_turn_params` 예요. 도구 결과 뒤 round 가 그 행을 처음 보여 줄 수 있는 시각이에요. 뒤따르는 round 가 없는 행은 둘로 나눠 세어요. `rows_after_the_last_round` 는 마지막 round 뒤에 도착한 행이고, `rows_in_runs_without_rounds` 는 round 기록이 없는 실행 안에서 도착한 행이에요.
- 돌고 도는 실행(spin): round 150개 이상이고 한 도구가 도구 호출의 85% 이상인 실행이에요. 이 보고서에서 실행에 이름을 붙이는 용도예요. 서버가 이 값을 읽고 무언가를 정하지 않아요.
- profile: `run_started.agent_name` 에서 첫 점 뒤 부분이에요. 점이 없으면 이름 전체이고, 이름이 없으면 `unrecorded` 예요.
- 날짜: 실행은 시작의 UTC 날짜, 행은 도착의 UTC 날짜예요.
- 백분위: 정렬한 값에서 `내림(p × n)` 번째(0부터) 값이에요. 끝을 넘으면 마지막 값이에요.

## 결과(2026-11-05T20:24Z 읽음)

실행은 5,409개예요. 2,775개는 round 기록이 없고, 2,634개에 round 32,286개가 있어요. round 기록이 없는 실행 중 2,752개는 `client_context_submission` hook 기록을 남기고, 23개는 hook 기록이 없어요. 실행당 round 는 p50 5, p90 28, p99 111, 최대 903이에요.

| 실행 크기 | 실행 | round | 전체 round 의 비율 | 도는 시간(시) |
|---|---:|---:|---:|---:|
| round 100개 이상 | 35 | 7,344 | 22.7% | 39.63 |
| round 400개 이상 | 5 | 3,012 | 9.3% | 11.95 |

round 400개 이상인 실행 5개는 모두 `glm-5.3-flash` 예요. 이 profile 의 round 10,881개 중 27.7%예요.
돌고 도는 실행은 7개, round 3,378개예요. 6개가 `glm-5.3-flash`, 1개(`context-reviewer`)가 `opencode-go-deepseek-flash` 예요. 3개는 사용량 한도 오류로, 2개는 모델이 답해서, 1개는 네트워크 오류로, 1개는 provider 시간 초과로 끝났어요.

| keeper | 날짜 | round | 시간(시) | 가장 많이 부른 도구(호출/전체) | 도착한 행 | 끝난 이유 |
|---|---|---:|---:|---|---:|---|
| `music-sensei` | 11-05 | 903 | 3.63 | `masc_board_list` 901/904 | 0 | 사용량 한도 |
| `wkbl-data` | 11-05 | 665 | 2.77 | `Execute` 661/665 | 0 | 사용량 한도 |
| `masc-productor-owner` | 11-04 | 508 | 1.03 | `masc_board_list` 487/507 | 13 | 모델이 답함 |
| `wkbl-growth` | 11-05 | 475 | 2.19 | `Execute` 473/473 | 0 | 사용량 한도 |
| `goo-yang-bong` | 11-05 | 461 | 2.33 | `keeper_memory_write` 456/460 | 5 | 모델이 답함 |
| `context-reviewer` | 11-04 | 215 | 1.55 | `Execute` 283/291 | 1 | 네트워크 오류 |
| `masc-productor-owner` | 11-04 | 151 | 0.96 | `masc_board_list` 131/150 | 20 | provider 시간 초과 |

이 7개에 도착한 행은 합쳐서 39개예요(`spin_runs[].rows_arrived_inside`). 3개 실행에는 한 행도 안 왔어요. 39개 중 33개는 `masc-productor-owner` 의 두 실행에서 왔어요.
한 도구가 호출의 85% 이상인 이 실행들은 전체 round 의 10.5%(3,378/32,286)인데, 도착한 행은 2.2%(39/1,773)예요.
직전과 같은 호출을 되풀이했는지는 `docs/evidence/repeated-calls-2026-11/` 에 따로 재요. `masc_board_list` 를 부른 위 3개 실행이 거기서 되풀이가 가장 많은 3개예요.

실행 중에 도착한 행은 1,773개예요. 범위 안의 확인된 행 3,534개의 50.2%예요. 이 행 중 실행이 끝나기 전에 확인(ack)된 행은 0개예요. 큐를 턴 사이에만 비우니 예상한 값이에요.
1,614개(91.0%)는 11-04·11-05에 도착했어요. 그 두 날에 trace 가 가장 많이 남아 있어요(실행 1,495개와 2,048개). 11-03에 68개, 10-19~10-29에 91개 도착했고, 10-30~11-02에는 0개예요. 10-30~11-02에는 ledger 행이 하루 605~1,673개 있는데 trace 가 거의 없어서 잴 수 없어요.

| 도착한 실행의 크기 | 행 | 막힌 시간(시) | 중앙값(분) | p90(분) | 최대(시) |
|---|---:|---:|---:|---:|---:|
| round 0~9개 | 633 | 36.9 | 1.6 | 9.6 | 1.00 |
| round 10~49개 | 800 | 193.6 | 7.4 | 37.8 | 2.84 |
| round 50~99개 | 192 | 73.6 | 16.6 | 45.8 | 3.41 |
| round 100개 이상 | 148 | 75.7 | 25.0 | 65.5 | 2.22 |

막힌 시간은 합쳐서 379.8시간이에요(`arrivals_during_runs.all`). 중앙값은 5.6분, p90은 34.7분, 최대는 3.41시간이에요. 긴 실행 때문만이 아니에요. round 10~49개인 실행 뒤에서 가장 많이(193.6시간) 기다렸어요.

| 행 종류 | 행 | 그중 Immediate | 막힌 시간(시) | 중앙값(분) |
|---|---:|---:|---:|---:|
| `board_attention` | 745 | 0 | 172.2 | 7.2 |
| `board_signal` | 737 | 293 | 158.1 | 5.4 |
| `schedule_due` | 172 | 0 | 31.7 | 2.6 |
| `keeper_delegate_completed` | 54 | 34 | 11.4 | 3.7 |
| `task_outcome` | 17 | 17 | 2.5 | 4.2 |

그 밖의 5종류는 48행이에요(`result.json` 의 `by_kind`).

다음 round 로 다시 재면(replay) 1,773개 중 1,374개에 뒤따르는 round 가 있어요. 도착부터 다음 round 까지는 중앙값 23.7초, p90 260.9초, 최대 1,795.3초예요. 이 행들을 실행 끝이 아니라 다음 round 에서 처음 보여 줄 수 있었다면 합쳐서 334.2시간 일찍 보여요.
뒤따르는 round 가 없는 행은 399개예요. 221개는 round 기록이 없는 실행 안에서, 178개는 마지막 round 뒤에 도착했어요.
뒤따르는 round 가 있는 행을 그 round 별로 묶으면 round 1,037개가 새 행을 처음 보여 줘요. 한 round 에 든 행은 p50 1, p90 2, p99 7, 최대 16개예요. 8개를 넘는 round 는 7개이고 그 안에 행 89개가 있어요(`rows_per_next_round`). 한 요청에 8개씩 보이면 그중 33개가 다음 요청으로 밀려요.

`chart.svg` 는 위쪽 그림에 날마다 round(100개 미만·이상 실행)를, 아래쪽 그림에 날마다 막힌 시간을 그려요. 회색 막대는 그날 round 기록이 없는 날이에요. 기록이 적은 날은 그 값도 일부예요.

## 공식 클라이언트 실행에 붙인 블록 (배포 뒤에 재요)

공식 클라이언트(Claude Code, Codex, Antigravity, Muse)는 모델 루프를 스스로 돌려서 round 기록이 없어요. 이 실행에서 MASC 가 도착한 행을 보여 줄 수 있는 자리는 MASC 도구의 결과 끝뿐이에요(`lib/keeper/keeper_official_client_host.ml` 의 `with_arrived_rows`).
호스트가 블록을 붙이면 그 실행의 raw trace 에 `arrived_stimuli_projection` hook 기록이 하나 남아요. `hook_detail` 은 JSON 이고 `tool`(블록을 실은 도구), `later`(이번 블록에 못 실은 행 수), `text_bytes`, `rows`(행마다 큐 항목 번호 `arrival` 과 도착 시각 `arrived_at`)를 적어요.
스크립트는 ledger 없이 이 기록만으로 `arrived_stimuli_projection` 을 채워요.

- `rows_shown`: 행을 처음 실은 블록을 기준으로 한 번씩 센 행 수예요. 클라이언트가 못 읽어서 다음 블록에 다시 실린 행은 새 행이 아니에요.
- `seconds_to_first_block`: 그 행들이 도착부터 처음 실린 블록까지 기다린 시간이에요.
- `seconds_to_run_end_of_the_same_rows`: 블록이 없었다면 같은 행이 적어도 기다렸을 시간(도착부터 실행 끝까지)이에요.
- `hours_earlier_than_the_run_end`: 위 두 값의 차이를 합친 값이에요. `by_day` 는 블록을 처음 실은 UTC 날짜별로 나눠요.
- `block_bytes`: 블록이 도구 결과에 더한 바이트(합계, 중앙값, p90, 최대)예요.
- `unreadable_projection_records`: 호스트가 쓰는 모양이 아닌 기록 수예요. 블록은 행을 하나 이상 싣고 숫자는 0 이상이에요.

배포 전 기준선은 2026-11-09T03:34Z 에 읽은 값이에요(창: 10-25~11-09, 읽지 못한 줄·파일 0개).

- `arrived_stimuli_projection` 은 `{"blocks": 0}` 이에요. 이 hook 을 쓰는 코드가 아직 배포되지 않았어요.
- round 기록이 없는 실행은 3,428개예요. 3,415개가 `client_context_submission` hook 을 남겨요. 실행 시간은 중앙값 32.7초, p90 150.3초, 최대 4,674.2초이고 합쳐서 69.0시간이에요(`runs.wall_seconds_of_runs_without_rounds`).
- 실행 중에 도착한 행은 139개이고 막힌 시간은 28.3시간이에요. 그중 7개가 round 기록이 없는 실행에 도착했어요. 나머지 132개는 round 가 있는 실행에 도착했어요.
- 그 7개로 replay 하면(`arrivals_during_runs.visible_at_next_tool_result`) 6개는 같은 실행에 MASC 도구 결과가 뒤따라요. 도착부터 그 결과까지 중앙값 5.2초, p90 12.3초, 최대 12.3초이고, 실행 끝까지 기다리는 것보다 합쳐서 0.29시간 일찍 보여요. 1개는 뒤따르는 도구 결과가 없어요.

같은 창에서 막힌 시간 28.3시간 중 round 기록이 없는 실행의 몫은 0.31시간(1.1%)이에요(`visible_at_next_tool_result.blocked_hours`, 7개 행의 도착부터 실행 끝까지 합). 블록이 앞당길 수 있는 시간은 그 안쪽이에요. 공식 클라이언트 실행이 짧아서 행이 도착할 틈이 적어요.
배포 뒤에는 `rows_shown`·`seconds_to_first_block` 을 위 replay 와 견주고, `rows_shown` 을 같은 창의 `visible_at_next_round.rows_in_runs_without_rounds` 와 견주세요. 행 하나하나를 이어 붙이지 않아서 비율은 근사값이에요. 아직 ack 되지 않은 행도 `rows_shown` 에 들어가요.

## 이 측정이 말하지 못하는 것

- 막힌 시간은 아래쪽 경계예요. 실제 기다림은 행이 자기 턴을 시작할 때까지예요.
- 행은 reaction ledger 의 `event_queue_ack` 만 세어요. 큐에서 ack 없이 사라진 행은 ledger 에 없어서 들어 있지 않아요.
- replay 는 실행 안에서 round 가 행을 보여 줄 수 있는 시각이에요. 모델이 행을 읽고 무엇을 할지는 잴 수 없어요. 배포하기 전이라 값이 없어요.
- 행 하나가 자기 턴에서 한 번 더 다뤄지는지(중복 처리)는 재지 않았어요.
- 10-30~11-02는 trace 가 거의 없어서 값이 없어요. 이 기간에 기다림이 없었다는 뜻이 아니에요.
- round 는 `before_turn_params` 기록으로만 세어요. `client_context_submission` 만 남기는 실행은 round 를 못 세서, 막힌 시간에는 들어가도 replay 에는 못 들어가요.
- `arrived_stimuli_projection` 은 호스트가 블록을 결과에 붙인 시점의 기록이에요. 클라이언트가 그 결과를 모델에 넘겼는지, 모델이 행을 읽고 무엇을 했는지는 재지 않아요. 쓰기 시점의 관측자는 I/O 를 하면 안 돼서 쓰기 성공은 기록하지 않아요.
- 클라이언트 자체 도구(Claude Code 의 Bash, Read 같은 것)의 결과는 MASC 를 거치지 않아서 블록을 붙일 수 없어요. MASC 도구를 한 번도 부르지 않는 실행은 블록을 못 받아요.
