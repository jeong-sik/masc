# keeper-librarian 프롬프트 비교의 기준선, A1 계약으로 다시 셈 (2026-11-15)

`scripts/tinker/librarian/prompt_lines.json` 에 두 모델의 기준선을 다시 고정했다.
스택 #51826 이 RFC-0517 §7.1 의 A1 계약을 들이면서 [#51780](../2026-11-13-librarian-pinned-baseline/README.md) 의 기준선이 비었다.
A1 계약에서는 지우기와, 기존 기억을 흡수만 하는 새 claim 에 지지 후보가 없어도 된다.

- #51780 이 고정한 실행 셋(Inkling 2 Small 기본 모델 두 번, GLM `glm-5.3-flash` 한 번)을 다시 채점했다. 모델은 다시 부르지 않았다(`eval_admission.py rescore`).
- 다시 채점한 답의 라벨 밖 지우기와 흡수는 Claude Opus 블라인드 판정자가 판정했다.
- 고정한 숫자는 `prompt_compare.py baseline` 의 출력 그대로다.
- #51982 가 `prompt_counts.py` 를 바꿨다. 기준선은 바뀐 파일로 셌다. 옛 파일로 세어도 숫자는 같고 `prompt_counts_sha256` 만 다르다.

이 폴더에는 숫자, 라벨, ID 만 있다. 요청 본문, 기억 문장, 모델 답 원문, 판정 이유는 넣지 않았다.

## 고정한 숫자

`a/b` 는 맞은 수와 기회 수다. 비교는 「고정값」 열을 쓴다. 지표의 뜻은 [#51780 README](../2026-11-13-librarian-pinned-baseline/README.md#고정한-숫자) 와 같다.

| 지표 | inkling 1 | inkling 2 | inkling 고정값 | glm 고정값 |
| --- | --- | --- | --- | --- |
| `synth_valid_rate` | 89/90 = 0.989 | 86/90 = 0.956 | 175/180 = 0.972 | 82/90 = 0.911 |
| `real_valid_rate` | 44/50 = 0.880 | 46/50 = 0.920 | 90/100 = 0.900 | 42/50 = 0.840 |
| `memory_state_accuracy` | 114/125 = 0.912 | 112/125 = 0.896 | 226/250 = 0.904 | 110/125 = 0.880 |
| `stale_drop_recall` | 31/102 = 0.304 | 21/102 = 0.206 | 52/204 = 0.255 | 60/102 = 0.588 |
| `judged_merge_recall` | 12/44 = 0.273 | 7/44 = 0.159 | 19/88 = 0.216 | 19/44 = 0.432 |
| `drop_precision` | 46/60 = 0.767 | 36/51 = 0.706 | 82/111 = 0.739 | 76/99 = 0.768 |
| `absorb_precision` | 31/52 = 0.596 | 25/37 = 0.676 | 56/89 = 0.629 | 30/55 = 0.545 |

| 기준 | sha256 |
| --- | --- |
| `pass_lines.json` | `9b62a25507a2…` |
| 템플릿 `config/prompts/librarian.md` | `575a68497f00…` |
| `prompt_counts.py` | `3ebf075047f8…` |

셋 중 하나가 바뀌면 `prompt_lines.py` 가 파일을 거절한다. 실행마다 rows sha256 과 답한 호출은 `prompt_lines.json` 과 `counts.json` 에 있다.

## #51780 과 달라진 몫

| 지표 | inkling #51780 → 지금 | glm #51780 → 지금 |
| --- | --- | --- |
| `synth_valid_rate` | 168/180 → 175/180 | 80/90 → 82/90 |
| `real_valid_rate` | 90/100 → 90/100 | 40/50 → 42/50 |
| `memory_state_accuracy` | 219/250 → 226/250 | 109/125 → 110/125 |
| `stale_drop_recall` | 40/162 → 52/204 | 54/81 → 60/102 |
| `judged_merge_recall` | 15/74 → 19/88 | 17/37 → 19/44 |
| `drop_precision` | 72/96 → 82/111 | 74/95 → 76/99 |
| `absorb_precision` | 22/44 → 56/89 | 26/49 → 30/55 |

달라진 까닭은 둘이다.

1. 채점기가 모든 요청의 심은 낡은 fact 와 바라는 합침을 센다(#51842). 그 전에는 지지 후보가 없는 요청을 세지 않았다.
   - `stale_drop_recall` 기회가 실행마다 81 에서 102 로 21 늘었다. 판정과 무관한 몫이다. 맞은 수는 세 실행 모두 6 늘었다. 그중 이 몫은 inkling 이 실행마다 1, glm 이 4 이고, 나머지는 새로 유효해진 답의 몫이다.
   - `judged_merge_recall` 기회가 실행마다 37 에서 44 로 7 늘었다.
2. 옛 검사기가 `new_claim_without_support` 로 거절한 답 11건이 유효해졌다. E-synth 는 inkling 3·4건, glm 2건이고 E-real 은 glm 2건이다. 유효하던 답이 무효가 된 경우는 없다.
   - 옛 실행에서도 유효했던 답의 흡수는 두 채점에서 같다(30·14·49). 늘어난 흡수는 모두 새로 유효해진 답에서 나왔다.
   - `judged_merge_recall` 의 맞은 수를 나누면 아래와 같다.

| 실행 | 옛 실행에서도 유효했던 답 | 새로 유효해진 답 |
| --- | --- | --- |
| inkling 1 | 9/41 | 3/3 |
| inkling 2 | 6/39 | 1/3 |
| glm 1 | 18/39 | 1/1 |

다시 채점한 E-real 의 Inkling `rows.jsonl` 은 #51780 과 sha256 이 같다. GLM 은 50줄 중 2줄이 다르고, 두 줄 모두 새로 유효해진 답이다.

## 판정자

| 실행 | 라벨 밖 지우기의 판정 | 흡수의 판정 | 지우기 판정 파일 sha256 | 흡수 판정 파일 sha256 |
| --- | --- | --- | --- | --- |
| inkling 1 | keep 13 | loses_knowledge 21, mergeable 31 | `5e3b256a1785…` | `8a9039092f87…` |
| inkling 2 | keep 15 | loses_knowledge 12, mergeable 25 | `fd6ce8d33f4a…` | `2f619e35e768…` |
| glm 1 | keep 23 | loses_knowledge 24, mergeable 30 | `493729c92847…` | `04ece15d44ae…` |

- 판정자는 Claude Opus 하위 에이전트다. 라벨, 대상 모델, 다른 판정자의 폴더는 보지 못한다. 사례의 모양은 #51780 과 같다.
- ID 를 뺀 모든 칸이 #51780 의 사례와 같은 사례는 그때의 Opus 판정을 옮겼다(`carry_decisions.py`). 판정자가 본 글이 같기 때문이다. 나머지 사례는 2026-11-15 에 판정자 다섯 명이 한 명에 한 폴더씩 봤다.

| 판정 폴더 | 옮긴 판정 | 새로 본 사례 |
| --- | --- | --- |
| inkling 1 지우기 | 8 | 0 |
| inkling 2 지우기 | 6 | 3 |
| glm 1 지우기 | 14 | 1 |
| inkling 1 흡수 | 30 | 22 |
| inkling 2 흡수 | 14 | 23 |
| glm 1 흡수 | 43 | 5 |

- 판정자 모델은 사용자가 2026-11-13 에 Opus 로 정했다. 그 전에 #51780 의 흡수 사례 87건을 Sonnet 블라인드 판정자 네 명에게 다시 보였다. 64건이 같았다. 다른 23건은 모두 Opus `loses_knowledge`, Sonnet `mergeable` 이었고 반대는 없었다.
- 흡수 판정만 Sonnet 으로 바꾸면 glm `judged_merge_recall` 은 29/44, `absorb_precision` 은 45/55 가 된다. 판정자 모델이 기준선을 2σ 넘게 움직인다. 하네스가 판정자 모델을 고정하지 않는 문제는 #51867 에 있다.
- 보정 사례를 만든 도구는 git 이 무시하는 `artifacts/tinker/librarian/code/calib_cases.py` 에 있다.

## 초안이 넘어야 하는 선

폭은 나빠짐 2.5σ, 좋아짐 2σ 다. 아래는 기회 수가 기준선과 같은 초안이 선을 넘는 맞은 수다.

| 모델 | 지표 | 기준선 | 나빠짐 | 채택 근거가 되는 좋아짐 |
| --- | --- | --- | --- | --- |
| inkling | `synth_valid_rate` | 175/180 = 0.972 | 163 이하 | — |
| inkling | `real_valid_rate` | 90/100 = 0.900 | 76 이하 | — |
| inkling | `memory_state_accuracy` | 226/250 = 0.904 | 206 이하 | 238 이상 |
| inkling | `stale_drop_recall` | 52/204 = 0.255 | 31 이하 | 71 이상 |
| inkling | `judged_merge_recall` | 19/88 = 0.216 | 7 이하 | 31 이상 |
| inkling | `drop_precision` | 82/111 = 0.739 | 64 이하 | — |
| inkling | `absorb_precision` | 56/89 = 0.629 | 39 이하 | — |
| glm | `synth_valid_rate` | 82/90 = 0.911 | 69 이하 | — |
| glm | `real_valid_rate` | 42/50 = 0.840 | 30 이하 | — |
| glm | `memory_state_accuracy` | 110/125 = 0.880 | 94 이하 | — |
| glm | `stale_drop_recall` | 60/102 = 0.588 | 42 이하 | — |
| glm | `judged_merge_recall` | 19/44 = 0.432 | 8 이하 | — |
| glm | `drop_precision` | 76/99 = 0.768 | 59 이하 | — |
| glm | `absorb_precision` | 30/55 = 0.545 | 17 이하 | — |

채택 근거가 되는 좋아짐은 `inkling` 의 `memory_state_accuracy`, `stale_drop_recall`, `judged_merge_recall` 뿐이다(`better_from`).

## 재지 않은 것과 남는 조건

- GLM 은 한 번 쟀다. 실행 사이의 퍼짐은 모른다.
- 지우기 판정자가 읽는 규칙은 고정 템플릿의 `admission_policy` 절이다. 그 절은 아직 A1 이전 계약 글이다. 초안 실행도 같은 글로 판정한다.
- 블라인드 판정자와 라이브 흡수 게이트가 같은 흡수를 같게 보는지는 재지 않았다.
- 실행 폴더와 판정 폴더는 한 대의 디스크에만 있다. 없어지면 고정한 숫자를 다시 확인할 수 없다. 비교는 그래도 돈다.
- CI 는 근거 폴더의 스크립트를 돌리지도, 타입 검사하지도 않는다. #51982 뒤 `baseline_counts.py` 는 `prompt_counts.target_of` 에 파싱 전 summary 를 넘겨 멈췄다. 이 PR 이 그 한 줄을 고쳤다. pyright strict 는 고치기 전 줄을 오류로 잡는다.

## 다시 확인하는 법

저장소 루트에서 돌린다. `artifacts/` 는 실행 폴더가 있는 checkout 의 것이어야 한다.

```sh
# 옮긴 판정과 새 판정을 기준선 판정 폴더 하나로 (폴더마다)
python3 docs/evidence/research/2026-11-13-librarian-rescored-baseline/carry_decisions.py join \
  --new artifacts/tinker/librarian/rescore-a1/opus/base-<run>-<drops|merges> \
  --carry artifacts/tinker/librarian/rescore-a1/opus/carry-<run>-<drops|merges>

# 고정한 숫자가 실행 폴더에서 다시 나오는지
uv run docs/evidence/research/2026-11-13-librarian-pinned-baseline/baseline_counts.py \
  docs/evidence/research/2026-11-13-librarian-rescored-baseline/baseline-runs.json > counts.json
python3 docs/evidence/research/2026-11-13-librarian-pinned-baseline/tables.py counts.json
```

`baseline_counts.py` 는 두 모델의 실행이 센 숫자가 고정값과 모두 같을 때만 0 으로 끝난다. 이 폴더의 `counts.json` 은 그렇게 끝난 실행의 출력이다.
