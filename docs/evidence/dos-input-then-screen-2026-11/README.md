# DOS 입력 도구 뒤에 화면 읽기가 바로 이어진 횟수 (2026-11-05 확인)

`masc_dos_step`, `masc_dos_press`, `masc_dos_click`, `masc_dos_type` 호출 뒤에 같은 Keeper 가 같은 턴에서 바로 `masc_dos_screen` 을 부른 횟수를 세요.
입력 도구가 `include_frame` 으로 화면을 같이 돌려주는 변경([RFC](../../rfc/RFC-dos-input-calls-return-the-screen.md))의 수요를 재고, 배포 뒤 같은 규칙으로 다시 재는 도구예요.

## 재는 방법

```bash
python3 -B docs/evidence/dos-input-then-screen-2026-11/measure_input_then_screen.py \
  --base-path ~/me --from-date 2026-11-01 --to-date 2026-11-04 \
  --json-out docs/evidence/dos-input-then-screen-2026-11/result-2026-11-01_11-04.json
python3 -B -m unittest discover -s docs/evidence/dos-input-then-screen-2026-11
```

- 읽은 시각: 2026-11-05T18:19Z. 4일(UTC)은 모두 끝난 날이라서 원장에서 날 파일이 지워지지 않는 한 같은 결과가 나와요. 읽지 못한 줄은 0이에요(`unreadable_lines`).
- 작업 위치: `~/me` 가 base path 인 개발 머신 한 대.
- 쌍: 한 Keeper 의 `masc_dos_*` 호출만 시각 순으로 늘어놓았을 때 서로 이어지고, `trace_id` 와 `keeper_turn_id` 가 같고, 앞이 입력이고 뒤가 `masc_dos_screen` 인 두 호출이에요. 사이에 다른 도구(`Execute` 등)가 끼어도 쌍이에요.
- `screen_in_next_request`: 쌍 가운데 입력 호출의 `batch_size` 가 1인 것. 이 쌍만 `include_frame` 이 모델 요청 하나를 없애요. 모델이 입력과 화면을 한 번에 요청했다면 도구 호출만 한 번 줄어요.

## 결과 (11-01 ~ 11-04)

| 입력 도구 | 호출 | 화면이 바로 이어진 호출 | 다음 요청에서 읽은 쌍 | 사이 시간 합(시간) | 중앙값(초) | 90백분위(초) |
|---|---:|---:|---:|---:|---:|---:|
| `masc_dos_step` | 272 | 189 | 189 | 1.39 | 12.4 | 47.9 |
| `masc_dos_press` | 2,074 | 1,490 | 1,490 | 10.82 | 10.4 | 38.6 |
| `masc_dos_type` | 123 | 28 | 28 | 0.24 | 10.5 | 30.2 |
| `masc_dos_click` | 0 | | | | | |

- 입력 2,469개 중 1,707개(69.1%)가 화면 읽기로 이어졌어요. `masc_dos_screen` 1,940개의 88.0%예요. 쌍은 모두 입력이 자기 배치에 혼자 있었어요.
- 프로필별로 이어지는 비율이 달라요. `ollama_cloud.ollama-cloud-deepseek-v4-1-flash` 는 입력 1,624개 중 1,238개(76.2%), `glm-coding.glm-5.3-flash` 는 383개 중 235개(61.4%)예요. 나머지 프로필 값은 결과 파일에 있어요.
- `masc_dos_*` 호출 4,704개는 모두 `msx-retro-mania` 한 Keeper 의 것이에요(`dos_calls_by_keeper`). 호출은 UTC 날짜별로 11-01 308, 11-02 1,935, 11-03 1,082, 11-04 1,379, 11-05 1이고, 마지막 호출이 11-05T10:17Z 예요.
- `with_frame` 열은 모두 0이에요. 지금 도구에는 `include_frame` 이 없어요.

## 읽을 때 주의

- 사이 시간은 입력 행과 화면 행의 `ts` 차이예요. 모델이 생각한 시간이 들어 있어서, `include_frame` 이 줄이는 시간이 아니에요.
- 쌍의 화면 결과는 159.8 MB(`screen_result_bytes` 합)예요. 화면이 입력 결과로 옮겨 오는 것이라서 이 바이트는 줄지 않아요.
- 배포 뒤 재는 값은 같은 런타임 프로필끼리 견줘요. 프로필마다 입력 뒤에 화면을 읽는 비율이 달라서, 프로필 구성이 다른 두 기간의 전체 값은 도구 변경과 상관없이 움직여요.
- 11-05 같은 열린 날은 읽는 동안 바뀌어서 결과 파일로 남기지 않았어요.
- 한 Keeper 의 4일이에요. 다른 Keeper 가 DOS 를 하면 비율이 다를 수 있어요.

## 시험

시험 4개는 가짜 원장으로 쌍과 배치 크기 규칙, 프로필·도구별 합, `include_frame` 개수, Keeper 가 섞여도 끊기지 않는 이음, 다른 턴 제외, 날짜 창과 조각 파일, 읽을 수 없는 줄, 명령줄 출력을 봐요.
스크립트를 아홉 군데 일부러 망가뜨려(턴 비교 제거, Keeper 구분 제거, `include_frame` 무시, 창 끝 제외, 기록 종류 검사 제거, 객체가 아닌 줄 무시, 화면 바이트를 입력 행에서 읽기, 다음 요청 수를 항상 세기, 화면의 배치 크기로 세기) 시험이 모두 잡는 것을 확인했어요.
