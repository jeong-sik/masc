# 실행이 되풀이하는 도구 호출 측정 (2026-11)

`measure_repeated_calls.py` 는 Keeper 의 실행(run)이 직전 호출과 똑같은 호출을 얼마나 되풀이하는지 재요.
raw trace 를 읽기만 해요.
`docs/evidence/runs-and-arrivals-2026-11/` 가 "돌고 도는 실행"이라고 부른 실행이 정말 같은 호출을 되풀이하는지, 그 몫이 얼마인지 보려고 만들었어요.

## 다시 측정하기

```bash
python3 -I -B docs/evidence/repeated-calls-2026-11/measure_repeated_calls.py --base-path ~/me \
    --json-out after.json
```

이 폴더의 `result.json` 은 2026-11-05T20:36Z 에 위 명령을 창 없이 돌린 결과예요. 읽는 데 10초 남짓 걸려요.
raw trace 는 오래된 순으로 지워져요. 다시 재면 값이 달라서 `read_at_utc` 를 같이 보세요.
목록을 읽은 뒤 열기 전에 지워진 파일은 `unreadable_files` 에, JSON 이 아닌 줄은 `unreadable_lines` 에 세어요.
시험은 `python3 -B -m unittest discover -s docs/evidence/repeated-calls-2026-11` 로 돌려요. Python 3.11 이상이 필요해요.

## 센 방법

- 실행: Keeper 의 raw trace 파일 하나예요.
- 호출: `tool_execution_started` 기록과 같은 `tool_use_id` 를 가진 `tool_execution_finished` 기록 한 쌍이에요.
- 되풀이(repeat): 같은 실행에서 바로 앞에 끝난 호출과 도구 이름, 입력, 결과가 모두 같은 호출이에요. 입력은 키 순서를 무시하고 비교해요. 시작 기록이 없는 호출, 입력이나 결과 필드가 없는 호출은 아무것과도 같지 않아요.
- 줄(streak): 앞 호출을 되풀이하는 호출이 이어진 구간이에요. 호출 N개로 된 줄은 되풀이 N-1개를 가져요. 줄의 시간은 첫 호출의 시작부터 마지막 호출의 끝까지예요.
- 실행끼리는 비교하지 않아요. 앞 실행의 마지막 호출과 다음 실행의 첫 호출이 같아도 되풀이가 아니에요.
- 되풀이는 모델이 새로 알게 된 것이 없는 호출이에요. 바뀌지 않는 상태를 일부러 다시 보는 호출도 되풀이로 세어요. 실수라고 판정하지는 않아요.
- 결과 크기: raw trace 에 기록된 `tool_result` 글을 UTF-8 로 바꾼 바이트 수예요. `tool_result` 가 없는 기록은 크기가 없고 0으로 더해요. 되풀이한 호출의 결과는 직전 결과와 같아서, `repeated_result_bytes` 는 같은 글이 실행에 다시 들어온 양이에요. 뒤 요청이 그 글을 얼마나 싣는지는 history 를 어떻게 보관하느냐에 달려서 이 수는 토큰 수가 아니에요.

## 결과(2026-11-05T20:36Z 읽음)

실행 5,410개 중 3,826개에 끝난 호출이 있고, 호출은 43,639개예요. 그중 1,663개(3.8%)가 직전 호출의 되풀이예요. 되풀이 중 170개는 결과가 오류였어요.
도구 결과는 합쳐서 124,501,392바이트이고, 되풀이한 호출의 결과는 1,636,270바이트(1.3%)예요. 호출로는 3.8%인데 바이트로는 1.3%예요. 호출 하나의 결과는 평균 2,853바이트이고, 되풀이한 호출의 결과는 평균 984바이트예요.

| 도구 | 호출 | 되풀이 | 호출 중 되풀이 | 되풀이한 결과(바이트) | 그 도구 결과 중 |
|---|---:|---:|---:|---:|---:|
| `masc_board_list` | 2,135 | 1,440 | 67.5% | 881,264 | 34.6% |
| `Execute` | 22,257 | 82 | 0.4% | 74,272 | 0.2% |
| `masc_board_post_get` | 2,669 | 39 | 1.5% | 71,157 | 0.4% |
| `keeper_artifact_read` | 676 | 28 | 4.1% | 458,752 | 10.4% |
| `masc_board_comment` | 1,915 | 27 | 1.4% | 4,275 | 0.1% |

되풀이의 86.6%가 `masc_board_list` 예요. 되풀이한 결과의 바이트로는 `masc_board_list` 가 53.9%, `keeper_artifact_read` 가 28.0%예요. `keeper_artifact_read` 의 458,752바이트 중 442,368바이트는 `kidsnote-job-manager` 의 실행 하나(10-26, 호출 33개 중 27개 되풀이)에서 나왔어요.

줄은 128개예요. 호출 수는 p50 4, p90 16, p99 61, 최대 895예요. 줄 안에서 보낸 시간은 합쳐서 6.34시간이에요.

| 줄의 호출 수 | 줄 | 되풀이 |
|---|---:|---:|
| 2~9개 | 106 | 307 |
| 10~99개 | 21 | 462 |
| 100개 이상 | 1 | 894 |

10개 이상인 줄 22개가 되풀이의 81.5%(1,356개)를 가져요.

| 실행 | profile | 날짜 | round | 시간(시) | 호출 | 되풀이 | 되풀이한 결과(바이트) | 끝난 이유 |
|---|---|---|---:|---:|---:|---:|---:|---|
| `music-sensei` | `glm-5.3-flash` | 11-05 | 903 | 3.63 | 904 | 897 | 453,882 | 사용량 한도(5시간) |
| `masc-productor-owner` | `glm-5.3-flash` | 11-04 | 508 | 1.03 | 507 | 427 | 331,369 | 모델이 답함 |
| `masc-productor-owner` | `glm-5.3-flash` | 11-04 | 151 | 0.96 | 150 | 104 | 81,265 | provider 시간 초과 |

이 세 실행이 되풀이의 85.9%(1,428개)이고, 되풀이한 결과 바이트의 53.0%(866,516바이트)예요. 셋 다 되풀이한 도구는 `masc_board_list` 예요. 나머지 실행은 되풀이가 27개 이하예요(`result.json` 의 `runs_with_the_most_repeats`).

profile 로 나누면 `glm-5.3-flash` 가 호출 12,045개 중 1,456개(12.1%)를 되풀이해서 전체 되풀이의 87.6%예요. `opencode-go-deepseek-flash` 는 호출 11,992개 중 3개예요.

## 표본으로 본 것(스크립트로 재지 않음)

`music-sensei` 11-05 실행(`turn-1793888944859-2fe7-000363.jsonl`, 903 round)을 직접 읽었어요.

- `masc_board_list` 901번 중 899번이 같은 입력(`compact` true, `hearth` sandbox, `limit` 2, `sort_by` recent)이고 결과도 같아요(`revision` 이 `board:6648…` 로 같아요). 호출 사이 시간은 중앙값 7.1초, 최대 176.4초예요.
- 이 도구에는 `if_revision` 인자가 있어요(`config/tools/masc_board_list.toml`). 이 실행의 901번 입력에는 한 번도 없어요.
- 11-05T20:37Z 에 모든 raw trace 에서 한 번 센 값이에요. `if_revision` 인자가 있는 도구 중 `masc_board_list` 는 호출 2,135번 중 28번(1.3%)만, `keeper_tasks_list` 는 964번 중 0번 이 인자를 넣었어요. `masc_status` 는 호출이 없어요.
  `masc_board_list` 28번은 모두 `mad-scientist` 가 10-28(24번), 10-29(4번)에 부른 호출이에요. 11-01 이후 도구 호출 원장에서는 `masc_board_list` 2,640번 중 5번이고 모두 `sangsu` 예요(11-05T20:50Z 에 읽음, 창 끝 20:00Z).
- round 903개 중 글이 든 응답은 4개예요. 그중 둘은 "이 턴은 여기서 끝낸다", "조용히 종료한다"고 쓰면서 같은 응답에 `masc_board_list` 호출을 넣었어요.
- 실행은 `Rate limited: Usage limit reached for 5 hour` 로 끝났어요.
- reaction ledger 에서 이 실행 안에 ack 된 도착 행은 0개예요(`docs/evidence/runs-and-arrivals-2026-11/result.json` 의 `spin_runs`).
- 서버가 도구 호출을 강제한다는 근거는 찾지 못했어요. 라이브 `runtime.toml` 에는 tool choice 값을 정하는 줄이 없고 capability 선언(`supports-*-tool-choice`) 5줄뿐이에요. `glm-5.3-flash` 로 도는 round 있는 실행 1,086개 중 916개는 20:37Z 에 `run_finished.error` 없이 끝나 있었어요.

## 이 측정이 말하지 못하는 것

- 되풀이가 왜 일어나는지는 몰라요. 위 표본은 모델이 끝낸다고 쓰고도 호출을 되풀이한 실행 하나예요.
- raw trace 가 남은 기간(10-17~11-05)만 봐요. 오래된 실행은 지워졌어요.
- 한 응답에 든 호출 여러 개는 끝난 순서대로 비교해요.
- raw trace 의 `tool_result` 가 모델에 보낸 도구 결과와 같은 글인지는 확인하지 못했어요. 결과 크기는 raw trace 에 남은 글의 크기예요.
- 되풀이를 줄이는 수리의 효과는 배포 뒤에 같은 스크립트로 `--from-date` 를 배포한 날로 주고 `masc_board_list` 의 되풀이와 `streaks.by_length` 를 견주면 알 수 있어요. 지금은 값이 없어요.
