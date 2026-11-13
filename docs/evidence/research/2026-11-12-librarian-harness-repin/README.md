# librarian 평가 하네스 재고정 기록, 2026-11-12

[#51416](https://github.com/jeong-sik/masc/pull/51416)이 이 기록을 근거로 쓴다.
이 폴더에는 숫자와 이름만 있다. 기억 본문, 모델 답 원문, E-real 기록은 넣지 않았다.

## 무엇을 확인했나

- 새 E-synth 두 배치가 블라인드 라벨 감사를 거쳤는가.
- 감사를 거친 두 배치가 item ID 순으로 한 세트가 됐는가.
- `pass_lines.json`에 적은 sha256이 main의 파일, 합친 세트, 고정 템플릿과 같은가.

## 소스와 입력

| 항목 | 값 |
| --- | --- |
| 코드 | main `10daa5ef46cd`의 `scripts/tinker/librarian/`. #51367 head `c3b2d4522c9e`와 바이트가 같다 |
| 고정 템플릿 | `config/prompts/librarian.md` sha256 `575a6849…`. #51325가 되돌린 문면이다 |
| 생성 모델 | Tinker `thinkingmachines/Inkling-2-Small` |
| 기본 실행 모델 | Tinker `thinkingmachines/Inkling-2-Small:peft:262144`, `reasoning_effort` low, `max_tokens` 32,768 |
| 판정자 | Claude Opus 하위 세션. 라벨과 모델 답은 보지 않는다. 판정자 폴더의 `judge.md`, `cases.jsonl`, 규칙 사본만 읽는다 |
| E-real | 50건, manifest sha256 `8d87e880…`. #51367이 고정했고 이번에는 바꾸지 않았다 |

## 배치와 감사

| 배치 | 생성 seed | `--first-memory` | 감사 | 규칙 sha256 | 읽은 요청 | 남긴 요청 | 표본 case | 표본에서 라벨과 어긋난 비율 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 20261112 | 0 | 첫째 | `1975c43e…` | 134 | 57 | 59 | 0.203 |
| 1 | | | 둘째 | `575a6849…` | 57 | 37 | 29 | 0.103 |
| 2 | 20261113 | 10 | 첫째 | `575a6849…` | 136 | 53 | 57 | 0.368 |

- 감사는 기본 모델 답이 라벨과 다른 요청을 모두 판정하고, 나머지 요청을 표본으로 판정한다. `--sample 1000`이라 나머지도 전부 판정했다.
- 배치 1의 첫째 감사는 프롬프트가 0.71.0 문면(`1975c43e…`)일 때 했다. #51325로 문면이 돌아간 뒤, 남은 57건을 고정 템플릿 규칙으로 다시 감사했다.
- 배치 2는 생성기가 기억 4개와 요청 14건을 만들지 못해 136건이 됐다.
- 배치 2 기본 실행은 136건 중 127건이 유효했다. 감사 case 136건은 기준 답 무효 9건, 라벨과 같음 48건, 라벨과 다름 79건이다.
- 배치 2 감사는 판정자 8명이 기억 단위로 나눠 맡았다. 한 기억의 case는 한 판정자가 모두 본다. 판정은 case 순서로 다시 이어 `e_synth_audit.py apply`에 넣었다.

배치 2에서 판정이 라벨과 어긋난 종류다. 왼쪽이 라벨, 오른쪽이 판정이다.

| 대상 | 종류 | 건수 |
| --- | --- | --- |
| 후보 | new → complements | 12 |
| 후보 | corrects → complements | 5 |
| 후보 | corrects → restates | 3 |
| 후보 | new → restates | 1 |
| 후보 | restates → corrects | 1 |
| 기억 | keep → restates | 39 |
| 기억 | keep → drop | 12 |
| 기억 | superseded → keep | 8 |
| 기억 | keep → superseded | 3 |

- 후보 판정이 어긋난 요청은 22건이다. 기억 판정이 어긋난 기억은 36개 중 17개이고, 그 기억의 요청은 68건이다.
- 두 묶음이 겹쳐서 빠진 요청은 83건이고 53건이 남았다.

## 파일

run은 git이 무시하는 `artifacts/tinker/librarian/` 아래에 있다. 모델 답은 `calls.jsonl`에만 있다.

| 파일 | 줄 | sha256 |
| --- | --- | --- |
| `synth-eval-s2/requests.jsonl` (배치 2 생성본) | 136 | `5284d8519fa5…` |
| `eval-s2-base-synth/rows.jsonl` (배치 2 기본 실행) | 136 | `ce3370bd9ab2…` |
| `eval-s2-base-synth/calls.jsonl` | 272 | `635005401f29…` |
| `e-synth-s2-audit/key.jsonl` | 136 | `e3e90c75d9ac…` |
| `e-synth-s2-audit/judge/cases.jsonl` | 136 | `fb59cf143c30…` |
| `e-synth-s2-audit/judge/decisions.jsonl` | 136 | `cbe8d231a64c…` |
| `e-synth-s2/requests.jsonl` (배치 2 감사 뒤) | 53 | `785fb4b56d58…` |
| 배치 1 감사 뒤 `requests.jsonl` | 37 | `044adadaf6e9…` |
| `e-synth-pooled/requests.jsonl` (합친 세트) | 90 | `8aa43fde4bd0…` |

## 합친 세트

| 항목 | 배치 1 | 배치 2 | 합 |
| --- | --- | --- | --- |
| 요청 | 37 | 53 | 90 |
| 기억 | 12 | 19 | 31 |
| 후보 | 54 | 71 | 125 |
| new_durable | 18 | 12 | 30 |
| correction | 11 | 10 | 21 |
| paraphrase | 11 | 16 | 27 |
| transient | 9 | 24 | 33 |
| complement | 5 | 9 | 14 |
| 중복 쌍이 든 요청 | 14 | 16 | 30 |
| 후보가 기억 변경을 지지하는 요청 | 32 | 39 | 71 |
| 쓸 날이 남은 기록 | 7 | 5 | 12 |
| 쓸 날이 지난 기록 | 2 | 5 | 7 |
| 점수에 드는 기록·요청 쌍, 쓸 날이 남음 | 24 | 10 | 34 |
| 점수에 드는 기록·요청 쌍, 쓸 날이 지남 | 4 | 12 | 16 |
| 점수에 드는 낡은 상태·요청 쌍 | 29 | 52 | 81 |

- Keeper별 요청은 docs-gardener 19, infra-cost-watch 27, qa-coordinator 21, support-triage 23건이다.
- Keeper별 기억은 6, 10, 7, 8개다.

## 고정값

| 항목 | 값 |
| --- | --- |
| `pass_lines.json` | sha256 `94c12b7943d1…`, `fixed_on` 2026-11-12 |
| `e_synth` | 90건, `requests_sha256` `8aa43fde…`, `audit_seed` 20261113, 배치 2개와 감사 3번 |
| `files_sha256` | 24개. 템플릿은 `575a6849…` |
| `train_sft.PASS_LINES_SHA256` | `pass_lines.json`의 sha256과 같다 |
| `prompt_lines.json` | 새 `pass_lines.json`과 고정 템플릿을 가리킨다. 기준선 숫자는 [2026-11-13 기준선](../2026-11-13-librarian-pinned-baseline/README.md)에서 고정했다 |
| 게이트, `choice`, `request`, `e_real` | 바꾸지 않았다 |

## 명령

```sh
cd <main 10daa5ef46cd checkout>
uv run scripts/tinker/librarian/synth_generate.py --split eval --seed 20261113 \
  --first-memory 10 --out artifacts/tinker/librarian/synth-eval-s2 --budget 4.2
# 감사 전 136건을 임시로 고정한 사본에서
uv run scripts/tinker/librarian/eval_admission.py run --set synth \
  --requests artifacts/tinker/librarian/synth-eval-s2/requests.jsonl \
  --target base=thinkingmachines/Inkling-2-Small:peft:262144 \
  --out artifacts/tinker/librarian/eval-s2-base-synth --budget 2.0
uv run scripts/tinker/librarian/e_synth_audit.py cases \
  --requests artifacts/tinker/librarian/synth-eval-s2/requests.jsonl \
  --run artifacts/tinker/librarian/eval-s2-base-synth --baseline base \
  --sample 1000 --seed 20261113 --out artifacts/tinker/librarian/e-synth-s2-audit
uv run scripts/tinker/librarian/e_synth_audit.py apply \
  --requests artifacts/tinker/librarian/synth-eval-s2/requests.jsonl \
  --audit artifacts/tinker/librarian/e-synth-s2-audit \
  --final artifacts/tinker/librarian/e-synth-s2/requests.jsonl
uv run scripts/tinker/librarian/e_synth_audit.py pool \
  --batch <배치 1 감사 뒤 requests.jsonl> \
  --batch artifacts/tinker/librarian/e-synth-s2/requests.jsonl \
  --final artifacts/tinker/librarian/e-synth-pooled/requests.jsonl
python3 docs/evidence/research/2026-11-12-librarian-harness-repin/repin2.py \
  . config/prompts/librarian.md artifacts/tinker/librarian/e-synth-pooled/requests.jsonl \
  20261113 2026-11-12 <batches.json>
```

- `repin2.py`는 고정값을 쓴 스크립트의 사본이다. 쓰기 전에 하는 검사는 그 파일 첫머리에 적혀 있다.
- 배치 1은 생성본과 첫째 감사 폴더가 없어서 `recorded_audits`로 넘겼다. 그 값은 지워지기 전에 같은 스크립트가 `audit.json`에서 읽어 적은 것이다.

## 확인하지 못한 것

- 배치 1의 생성본, 첫째 감사 폴더, 기본 실행은 2026-11-11에 worktree와 함께 지워졌다. 첫째 감사의 숫자는 파일로 다시 대조할 수 없다.
- 판정자는 한 case를 한 번 판정했다. 판정자 사이의 일치도는 재지 않았다.
- 배치 2 생성본의 기억 `eval-infra-cost-watch-19`에 본문이 `NaN`인 fact가 하나 있었다. 감사가 그 기억을 뺐다. 생성기는 fact 본문의 길이를 검사하지 않는다.
- G4(−0.06)와 G5(1.16)는 2026-11-09에 E-real 99건으로 잰 같은 창 퍼짐의 2배다. 지금 E-real은 50건이고, 50건에서의 퍼짐은 아직 재지 않았다.
