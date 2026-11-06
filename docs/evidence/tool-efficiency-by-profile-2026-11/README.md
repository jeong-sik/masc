# 도구 호출 낭비 측정을 런타임 프로필별로 나눈 값 (2026-11-05 확인)

`scripts/measure-tool-efficiency.py` 는 원장 전체에 숫자 하나를 내요. 이 폴더의 스크립트는 같은 원장을 같은 규칙으로 읽고 `runtime_profile` 별로 따로 세요.
읽은 결과와 해석은 [`docs/reports/2026-11-06-tool-efficiency-by-profile.md`](../../reports/2026-11-06-tool-efficiency-by-profile.md) 에 있어요.

## 재는 방법

```bash
python3 -B docs/evidence/tool-efficiency-by-profile-2026-11/measure_by_profile.py \
  --base-path ~/me --from-date 2026-11-01 --to-date 2026-11-04 \
  --json-out docs/evidence/tool-efficiency-by-profile-2026-11/result-2026-11-01_11-04.json
python3 -B -m unittest discover -s docs/evidence/tool-efficiency-by-profile-2026-11
```

- 읽은 시각: 2026-11-05T17:32Z. 4일(UTC)은 모두 끝난 날이라서 원장에서 날 파일이 지워지지 않는 한 같은 결과가 나와요.
- 작업 위치: `~/me` 가 base path 인 개발 머신 한 대. 읽지 못한 줄은 0이에요(`unreadable_lines`).
- 공식 스크립트를 읽어 들여 `observe_row` 를 그대로 불러요. 프로필마다 합계 객체를 따로 두고, 같은 호출을 되받았는지 보는 `last_seen` 은 하루에 하나만 둬서 모든 프로필이 나눠 써요. 그래서 프로필 합은 공식 값과 같아요. 이 원장에서 직접 맞춰 봤어요: 호출 151,787, 결과 바이트 977,206,683, 되받은 호출 34,438, 되받은 바이트 311,269,666, blob 호출 8,121, blob 바이트 387,119,539, 되읽기 호출 17,046이 모두 같아요.
- 시험 7개는 가짜 원장 두 날로 프로필 귀속, `unrecorded`, `--top`, 한 프로필이 한 줄이라는 출력 모양을 보고, 같은 원장에 공식 스크립트를 돌려 프로필 합과 맞춰 봐요. 스크립트를 다섯 군데 일부러 망가뜨려(프로필별 `last_seen`, 라벨 오타, `record_kind` 검사 제거, `--top` 무시, Keeper 귀속 오류) 시험이 모두 잡는 것을 확인했어요.

## 읽을 때 주의

- 되받은 호출은 나중 호출의 프로필로 세요. 앞 호출이 다른 프로필이어도 그래요.
- 프로필 이름은 원장에 적힌 `runtime_profile` 그대로예요. 기록이 없는 행은 `unrecorded` 예요. 같은 모델이 계정마다 다른 프로필 이름을 가질 수 있어서 이름 하나가 모델 하나는 아니에요.
- 이 값은 "어느 프로필이 만들었나"만 가려요. 차이가 모델 때문인지 계정이나 레인 설정 때문인지는 가르지 못해요.
- 되받은 호출 일부는 새 컨텍스트로 시작하는 레인에 필요한 읽기일 수 있어요. 새 정보가 없었던 호출의 수이고, 줄일 수 있는 양의 상한이 아니에요.
- 11-05 같은 열린 날은 읽는 동안 바뀌어서 결과 파일로 남기지 않았어요. 보고서의 11-05 숫자는 읽은 시각을 같이 적었어요.
