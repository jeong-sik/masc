# 서버 재시작 앞뒤로 도구 호출 원장 비교하기 (2026-11)

도구 호출 원장(`~/me/.masc/tool_calls`)을 서버 부팅 시각 앞뒤의 같은 길이 두 창으로 나눠 같은 값을 세요. 결과 크기, Execute 가 붙든 시간, 실패, 디스크 바닥 거절, 백그라운드 Execute 를 한 번에 내요.

## 왜 재나요

도구를 고치고 배포한 뒤 "좋아졌다"고 말하려면 같은 정의로 앞뒤를 세야 해요. 정의를 쓸 때마다 바꾸면 값이 달라져도 이유를 알 수 없어요. 이 스크립트는 정의를 한 곳에 고정해요. 배포가 끝나면 부팅 시각만 넣어서 다시 돌려요.

## 결과 (부팅 2026-11-07T18:24:19Z, 끝 11-08T14:08:00Z, UTC)

앞은 11-06 22:45Z ~ 11-07 18:24Z, 뒤는 11-07 18:29Z ~ 11-08 14:08Z 로 둘 다 19.7시간이에요. 뒤 창은 부팅 5분 뒤부터예요.

| 항목 | 앞 | 뒤 |
|---|---|---|
| 호출 | 18,727 | 8,524 |
| 실패 | 170 | 116 |
| Grep 결과 100 KiB 이상 | 108/1,087, 최대 1,127,672 B | 0/147, 최대 10,552 B |
| `keeper_tools_list` 중앙값 | 282,958 B (81/81 이 100 KiB 이상) | 9,655 B (0/28) |
| BrowserTabs 중앙값 | 33,014 B (27/50 이 16 KiB 이상) | 7,901 B (0/8) |
| `masc_dashboard` 16 KiB 이상 | 36/36 | 3/6 |
| Execute 붙든 시간 | 13.30 h (7,238호출) | 7.03 h (4,186호출) |
| Execute 60초 이상 | 109호출, 6.12 h | 29호출, 2.14 h |
| `sleep N` 폴링(두 Keeper) | 71호출, 4.18 h (이 둘의 Execute 624호출) | 7호출, 0.28 h (228호출) |
| 성공한 Execute 의 도구 쪽 오버헤드 | 1.83 h (13.9%) | 1.27 h (18.5%) |
| `remote_ssh_disk_low` 실패 | 17 (Execute 17) | 53 (Execute 51, Grep 2) |
| `run_in_background` 시작 | 0 | 1 (도구 이름을 알리는 문구 0) |

- 호출 수가 54% 줄어서 비율은 같은 조건의 비교가 아니에요. 상한을 거는 수리는 최댓값으로 읽어요.
- 뒤 창의 `remote_ssh_disk_low` 53건은 `intent` 가 없는 Execute 49건, `request_effect` 2건, Grep 2건이에요.
- `sleep N` 폴링은 두 Keeper 의 Execute 호출이 같은 창에서 62% 줄어든 것(624에서 228)과 섞여 있어요. 호출당 폴링 몫은 11.4%(71/624)에서 3.1%(7/228)예요.

## 배포 뒤에 다시 재는 법

서버 부팅 시각은 `/health` 의 `build.started_at` 이에요. #49959 와 #49942 를 담은 빌드가 뜨면 그 시각을 넣어요.

```bash
python3 docs/evidence/tool-efficiency-before-after-2026-11/measure_before_after.py \
  --base-path ~/me --boot <build.started_at, UTC, 초까지> --end <지금, UTC> \
  --json-out docs/evidence/tool-efficiency-before-after-2026-11/result-boot-<부팅 시각>.json
```

- #49959(읽기 호출은 디스크 바닥 검사를 건너뛴다): `after.disk_low.by_tool` 에 `Grep` 이 없고 `execute_by_intent` 에 `auto` 가 없어야 해요. `request_effect` 는 남을 수 있어요.
- #49942(시작 결과가 상태 읽기·취소 도구 이름을 알린다): `after.background_starts.naming_both_handle_tools` 가 `calls` 와 같아야 해요.
- `--hours-before` 로 앞 창 길이를, `--settle-s` 로 부팅 직후를 뺀 시간을, `--sleep-keepers` 로 폴링을 셀 Keeper 를 바꿔요.

## 시험

```bash
python3 -m unittest discover -s docs/evidence/tool-efficiency-before-after-2026-11
```

합성 원장으로 세는 법을 확인하는 시험 15개예요. 창과 부팅 직후 제외, 크기 중앙값과 상한, `sleep` 폴링의 정의, 백그라운드 호출, 오버헤드, 디스크 바닥 거절의 의도별 구분, 회전 파일 읽기를 봐요.

## 못 잰 것

- 앞뒤 차이의 원인. 창마다 활동량이 달라서 수리 효과와 활동 변화를 가르지 못해요.
- `sleep N` 폴링은 명령에 `sleep` 과 숫자가 있는 호출만 세요. `argv` 배열로 나눠 쓴 `sleep` 은 놓쳐요.
- 오버헤드는 출력에 `execution_time_ms` 가 남은 성공 호출만 세요. 출력이 잘려 이 값이 없는 호출은 빠져요.
- 모델이 본 크기가 아니라 도구가 낸 크기(`result_bytes`)예요.
