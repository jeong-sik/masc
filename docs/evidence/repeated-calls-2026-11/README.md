# 실행이 되풀이하는 도구 호출 측정 (2026-11)

`measure_repeated_calls.py` 는 Keeper 의 실행(run)이 직전 호출과 똑같은 호출을 얼마나 되풀이하는지 재요.
raw trace 를 읽기만 해요.
`docs/evidence/runs-and-arrivals-2026-11/` 가 "돌고 도는 실행"이라고 부른 실행이 정말 같은 호출을 되풀이하는지, 그 몫이 얼마인지 보려고 만들었어요.

## 다시 측정하기

```bash
python3 -I -B docs/evidence/repeated-calls-2026-11/measure_repeated_calls.py --base-path ~/me \
    --json-out after.json
```

이 폴더의 `result.json` 은 2026-11-05T20:15Z 에 위 명령을 창 없이 돌린 결과예요. 읽는 데 10초 남짓 걸려요.
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

## 결과(2026-11-05T20:15Z 읽음)

실행 5,401개 중 3,819개에 끝난 호출이 있고, 호출은 43,700개예요. 그중 1,663개(3.8%)가 직전 호출의 되풀이예요. 되풀이 중 170개는 결과가 오류였어요.

| 도구 | 호출 | 되풀이 | 호출 중 되풀이 |
|---|---:|---:|---:|
| `masc_board_list` | 2,133 | 1,440 | 67.5% |
| `Execute` | 22,302 | 82 | 0.4% |
| `masc_board_post_get` | 2,660 | 39 | 1.5% |
| `keeper_artifact_read` | 679 | 28 | 4.1% |
| `masc_board_comment` | 1,912 | 27 | 1.4% |

되풀이의 86.6%가 `masc_board_list` 예요.

줄은 128개예요. 호출 수는 p50 4, p90 16, p99 61, 최대 895예요. 줄 안에서 보낸 시간은 합쳐서 6.34시간이에요.

| 줄의 호출 수 | 줄 | 되풀이 |
|---|---:|---:|
| 2~9개 | 106 | 307 |
| 10~99개 | 21 | 462 |
| 100개 이상 | 1 | 894 |

10개 이상인 줄 22개가 되풀이의 81.5%(1,356개)를 가져요.

| 실행 | profile | 날짜 | round | 시간(시) | 호출 | 되풀이 | 끝난 이유 |
|---|---|---|---:|---:|---:|---:|---|
| `music-sensei` | `glm-5.3-flash` | 11-05 | 903 | 3.63 | 904 | 897 | 사용량 한도(5시간) |
| `masc-productor-owner` | `glm-5.3-flash` | 11-04 | 508 | 1.03 | 507 | 427 | 모델이 답함 |
| `masc-productor-owner` | `glm-5.3-flash` | 11-04 | 151 | 0.96 | 150 | 104 | provider 시간 초과 |

이 세 실행이 되풀이의 85.9%(1,428개)예요. 셋 다 되풀이한 도구는 `masc_board_list` 예요. 나머지 실행은 되풀이가 27개 이하예요(`result.json` 의 `runs_with_the_most_repeats`).

profile 로 나누면 `glm-5.3-flash` 가 호출 11,937개 중 1,456개(12.2%)를 되풀이해서 전체 되풀이의 87.6%예요. `opencode-go-deepseek-flash` 는 호출 12,092개 중 3개예요.

## 표본으로 본 것(스크립트로 재지 않음)

`music-sensei` 11-05 실행(`turn-1793888944859-2fe7-000363.jsonl`, 903 round)을 직접 읽었어요.

- `masc_board_list` 901번 중 899번이 같은 입력(`compact` true, `hearth` sandbox, `limit` 2, `sort_by` recent)이고 결과도 같아요(`revision` 이 `board:6648…` 로 같아요). 호출 사이 시간은 중앙값 7.1초, 최대 176.4초예요.
- 이 도구에는 `if_revision` 인자가 있어요(`config/tools/masc_board_list.toml`). 901번의 입력에는 한 번도 없어요.
- round 903개 중 글이 든 응답은 4개예요. 그중 둘은 "이 턴은 여기서 끝낸다", "조용히 종료한다"고 쓰면서 같은 응답에 `masc_board_list` 호출을 넣었어요.
- 실행은 `Rate limited: Usage limit reached for 5 hour` 로 끝났어요.
- reaction ledger 에서 이 실행 안에 ack 된 도착 행은 0개예요(`docs/evidence/runs-and-arrivals-2026-11/result.json` 의 `spin_runs`).
- 도구 호출 없는 답은 이 모델에서도 나와요. `glm-5.3-flash` 로 도는 round 있는 실행 1,072개 중 903개는 `run_finished.error` 없이, 모델이 도구 호출 없이 답해서 끝났어요. 라이브 `runtime.toml` 에는 tool choice 값을 정하는 줄이 없고 capability 선언(`supports-*-tool-choice`) 5줄뿐이에요.

## 이 측정이 말하지 못하는 것

- 되풀이가 왜 일어나는지는 몰라요. 위 표본은 모델이 끝낸다고 쓰고도 호출을 되풀이한 실행 하나예요.
- raw trace 가 남은 기간(10-17~11-05)만 봐요. 오래된 실행은 지워졌어요.
- 한 응답에 든 호출 여러 개는 끝난 순서대로 비교해요.
- 되풀이를 줄이는 수리의 효과는 배포 뒤에 같은 스크립트로 `--from-date` 를 배포한 날로 주고 `masc_board_list` 의 되풀이와 `streaks.by_length` 를 견주면 알 수 있어요. 지금은 값이 없어요.
