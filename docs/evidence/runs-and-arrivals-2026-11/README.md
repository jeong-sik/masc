# 실행 길이와 도는 중 도착한 큐 행 측정 (2026-11)

`measure_runs_and_arrivals.py` 는 Keeper 의 실행(run)이 얼마나 오래 도는지, 도는 동안 그 Keeper 의 큐에 무엇이 도착하는지 재요.
raw trace 와 reaction ledger 를 읽기만 해요.
`docs/rfc/RFC-arrived-stimuli-reach-the-running-turn.md` 가 풀려는 기다림이 얼마나 되는지 재요.

## 다시 측정하기

```bash
python3 -I -B docs/evidence/runs-and-arrivals-2026-11/measure_runs_and_arrivals.py --base-path ~/me \
    --json-out after.json --svg-out after.svg
```

이 폴더의 `result.json`·`chart.svg` 는 2026-11-05T19:39Z 에 위 명령을 창 없이 돌린 결과예요. 읽는 데 10초쯤 걸려요.
raw trace 는 오래된 순으로 지워져요. 같은 날 39분 사이에 두 번 읽었더니 round 가 33,595개에서 32,789개로, 실행 중에 도착한 행이 1,884개에서 1,792개로 줄었어요. 그래서 다시 재면 값이 달라요. 값을 비교할 때는 `read_at_utc` 를 같이 보세요.
목록을 읽은 뒤 열기 전에 지워진 파일은 `unreadable_files` 에, JSON 이 아닌 줄은 `unreadable_lines` 에 세어요.
시험은 `python3 -B -m unittest discover -s docs/evidence/runs-and-arrivals-2026-11` 로 돌려요. Python 3.11 이상이 필요해요.

## 센 방법

- 실행: Keeper 의 raw trace 파일 하나(`.masc/keepers/<keeper>/raw-traces/turn-*.jsonl`)예요. 시작은 첫 줄의 `ts`, 끝은 마지막 줄의 `ts` 예요. 모델이 도구 호출 없이 답하거나 provider 오류가 나면(`run_finished.error`) 실행이 끝나요.
- round: 그 파일의 `before_turn_params` hook 기록 하나예요. 모델 요청 하나에 하나씩 있어요. 이 기록이 하나도 없는 실행은 `runs_without_rounds` 에 따로 세고 round 통계에서 빼요. 그런 실행 2,757개 중 2,734개는 `client_context_submission` hook 기록을 남기고, 23개는 hook 기록이 없어요.
- 긴 실행: round 100개 이상, 400개 이상인 실행이에요.
- 도는 중 도착한 행: reaction ledger(`reaction-ledger/v7/YYYY-MM/DD.jsonl`)의 `event_queue_ack` 행 중, 도착 시각(`arrived_at_unix`)이 같은 Keeper 의 어떤 실행의 시작과 끝 사이인 행이에요. 같은 `event_id` 는 한 행으로 세어요.
- 범위: 그 Keeper 의 첫 trace 시작부터 마지막 trace 끝까지만 세어요. 더 오래된 trace 는 지워지고, 실행이 지워진 행은 쉬는 중에 도착한 행처럼 보여요.
- 막힌 시간: 도착부터 그 실행의 끝까지예요. 큐는 턴 사이에만 비우니 행은 적어도 이만큼 기다려요. 행이 자기 턴을 시작하는 시각은 더 늦어서 실제 기다림은 이보다 길어요.
- 다음 round: 도착한 뒤 같은 실행의 첫 `before_turn_params` 예요. 도구 결과 뒤 round 가 그 행을 처음 보여 줄 수 있는 시각이에요. 뒤따르는 round 가 없는 행은 둘로 나눠 세어요. `rows_after_the_last_round` 는 마지막 round 뒤에 도착한 행이고, `rows_in_runs_without_rounds` 는 round 기록이 없는 실행 안에서 도착한 행이에요.
- 돌고 도는 실행(spin): round 150개 이상이고 한 도구가 도구 호출의 85% 이상인 실행이에요. 이 보고서에서 실행에 이름을 붙이는 용도예요. 서버가 이 값을 읽고 무언가를 정하지 않아요.
- profile: `run_started.agent_name` 에서 첫 점 뒤 부분이에요. 점이 없으면 이름 전체이고, 이름이 없으면 `unrecorded` 예요.
- 날짜: 실행은 시작의 UTC 날짜, 행은 도착의 UTC 날짜예요.
- 백분위: 정렬한 값에서 `내림(p × n)` 번째(0부터) 값이에요. 끝을 넘으면 마지막 값이에요.

## 결과(2026-11-05T19:39Z 읽음)

실행은 5,392개예요. 2,757개는 round 기록이 없고, 2,635개에 round 32,759개가 있어요. 실행당 round 는 p50 5, p90 29, p99 111, 최대 903이에요.

| 실행 크기 | 실행 | round | 전체 round 의 비율 | 도는 시간(시) |
|---|---:|---:|---:|---:|
| round 100개 이상 | 36 | 7,449 | 22.7% | 40.45 |
| round 400개 이상 | 5 | 3,012 | 9.2% | 11.95 |

round 400개 이상인 실행 5개는 모두 `glm-5.3-flash` 예요. 이 profile 의 round 10,894개 중 27.6%예요.
돌고 도는 실행은 7개, round 3,378개예요. 6개가 `glm-5.3-flash`, 1개가 `opencode-go-deepseek-flash` 예요. 3개는 사용량 한도 오류로, 2개는 모델이 답해서, 1개는 네트워크 오류로, 1개는 provider 시간 초과로 끝났어요.

실행 중에 도착한 행은 1,791개예요. 범위 안의 확인된 행 3,544개의 50.5%예요. 이 행 중 실행이 끝나기 전에 확인(ack)된 행은 0개예요. 큐를 턴 사이에만 비우니 예상한 값이에요.
1,630개(91.0%)는 11-04·11-05에 도착했어요. 그 두 날에 trace 가 가장 많이 남아 있어요(실행 1,506개와 2,013개). 11-03에 70개, 10-19~10-29에 91개 도착했고, 10-30~11-02에는 0개예요. 10-30~11-02에는 ledger 행이 하루 605~1,673개 있는데 trace 가 거의 없어서 잴 수 없어요.

| 도착한 실행의 크기 | 행 | 막힌 시간(시) | 중앙값(분) | p90(분) | 최대(시) |
|---|---:|---:|---:|---:|---:|
| round 0~9개 | 634 | 36.9 | 1.6 | 9.6 | 1.00 |
| round 10~49개 | 813 | 194.2 | 7.2 | 37.5 | 2.84 |
| round 50~99개 | 192 | 73.6 | 16.6 | 45.8 | 3.41 |
| round 100개 이상 | 152 | 78.2 | 25.3 | 64.6 | 2.22 |

막힌 시간은 합쳐서 382.7시간이에요. 긴 실행 때문만이 아니에요. round 10~49개인 실행 뒤에서 가장 많이(194.2시간) 기다렸어요.

| 행 종류 | 행 | 그중 Immediate | 막힌 시간(시) | 중앙값(분) |
|---|---:|---:|---:|---:|
| `board_attention` | 746 | 0 | 172.2 | 7.2 |
| `board_signal` | 741 | 295 | 160.5 | 5.4 |
| `schedule_due` | 174 | 0 | 31.8 | 2.6 |
| `keeper_delegate_completed` | 64 | 44 | 11.8 | 3.0 |
| `task_outcome` | 17 | 17 | 2.5 | 4.2 |

다음 round 로 다시 재면(replay) 1,791개 중 1,390개에 뒤따르는 round 가 있어요. 도착부터 다음 round 까지는 중앙값 23.4초, p90 258.3초, 최대 1,795.3초예요. 이 행들을 실행 끝이 아니라 다음 round 에서 처음 보여 줄 수 있었다면 합쳐서 337.1시간 일찍 보여요.
뒤따르는 round 가 없는 행은 401개예요. 222개는 round 기록이 없는 실행 안에서, 179개는 마지막 round 뒤에 도착했어요.

`chart.svg` 는 위쪽 그림에 날마다 round(100개 미만·이상 실행)를, 아래쪽 그림에 날마다 막힌 시간을 그려요. 회색 막대는 그날 round 기록이 없는 날이에요. 기록이 적은 날은 그 값도 일부예요.

## 이 측정이 말하지 못하는 것

- 막힌 시간은 아래쪽 경계예요. 실제 기다림은 행이 자기 턴을 시작할 때까지예요.
- replay 는 실행 안에서 round 가 행을 보여 줄 수 있는 시각이에요. 모델이 행을 읽고 무엇을 할지는 잴 수 없어요. 배포하기 전이라 값이 없어요.
- 행 하나가 자기 턴에서 한 번 더 다뤄지는지(중복 처리)는 재지 않았어요.
- 10-30~11-02는 trace 가 거의 없어서 값이 없어요. 이 기간에 기다림이 없었다는 뜻이 아니에요.
- round 는 `before_turn_params` 기록으로만 세어요. `client_context_submission` 만 남기는 실행은 round 를 못 세서, 막힌 시간에는 들어가도 replay 에는 못 들어가요.
