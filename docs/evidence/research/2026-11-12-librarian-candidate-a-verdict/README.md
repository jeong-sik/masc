# 후보 A 판정 기록, 2026-11-12

[RFC-0517](../../../rfc/RFC-0517-the-librarian-keeps-one-correct-fact-per-piece-of-knowledge.md) §2.1 의 학습 단계에서 keeper-librarian 후보 A 를 한 번 학습하고 고정 게이트로 판정했다.
A 는 여섯 게이트 중 G5 하나만 통과했다. `verdict` 는 `choice: null` 을 냈고, A 는 운영 슬롯에 올리지 않는다.

이 폴더에는 숫자, 라벨, ID 만 있다. 요청 본문, 기억 문장, 모델 답 원문, 체크포인트 경로는 넣지 않았다.

## 결과

게이트는 A 에만 건다. 기본 모델은 같은 실행에서 같은 요청에 답한 비교 대상이다.

| 게이트 | 읽는 값 | 선 | 기본 모델 | A | 판정 |
| --- | --- | --- | --- | --- | --- |
| G1 | E-real 유효율 | 0.95 이상 | 42/49 = 0.857 | 38/49 = 0.776 | 미달 |
| G2 | 라이브가 안 지운 fact 를 지운 수 | 4 이하 | 1 | 10 | 미달 |
| G3 | 남는 기억 정확도 | 0.95 이상 | 108/125 = 0.864 | 97/125 = 0.776 | 미달 |
| G3 | 지우기 정밀도 | 1.0 | 34/43 = 0.791 | 32/52 = 0.615 | 미달 |
| G3 | 낡은 상태 재현율 | 0.9 이상 | 18/81 = 0.222 | 18/81 = 0.222 | 미달 |
| G4 | 라이브와 같은 판정 비율, A 에서 기본 모델을 뺀 값 | −0.06 이상 | 37/52 = 0.712 | 26/52 = 0.500, 차 −0.212 | 미달 |
| G5 | 지연 p50, A 를 기본 모델로 나눈 값 | 1.16 이하 | 36.89초 | 22.68초, 비 0.61 | 통과 |
| G6 | 흡수 정밀도 | 0.85 이상 | 8/16 = 0.500 | 5/14 = 0.357 | 미달 |
| G6 | 판정 합침 재현율 | 0.70 이상 | 6/37 = 0.162 | 3/37 = 0.081 | 미달 |

- G1 의 분모는 49건이다. E-real 50건 중 1건(`7ac0f0a0dd5ae910`)은 엔드포인트가 두 모델 모두에게 HTTP 400 으로 거절했다. 고정 규칙이 그런 요청을 분모에서 뺀다.
- A 는 생각 부분 없이 답했다. E-real 49건과 E-synth 90건 모두 그랬다. 기본 모델은 139건 모두 생각 부분을 먼저 썼다.
  지연은 답 토큰 수와 같이 줄었다. 답 토큰 중앙값은 E-real 에서 2,014 대 900, E-synth 에서 2,371.5 대 1,135.5 다.
- 학습이 겨냥한 행동은 늘지 않았다. 심은 낡은 상태는 두 모델 모두 81개 중 18개를 지웠다. 라벨이 바란 합침은 기본 모델이 37개 중 9개, A 가 6개를 했다.
- 틀린 지우기와 무효 답은 늘었다. 라벨 밖 지우기는 기본 모델 9개, A 19개다. 블라인드 판정자는 28개 모두 남겨야 할 fact 로 봤다.
  무효 답은 E-real 에서 8건 대 12건, E-synth 에서 8건 대 12건이다.
- 기본 모델도 G1, G3, G6 선에 닿지 않는다.

## 소스와 입력

| 항목 | 값 |
| --- | --- |
| 코드 | main `8a66fd8c9fe1`(#51462 병합 커밋)의 `scripts/tinker/librarian/` 사본 |
| 고정값 | `pass_lines.json` sha256 `94c12b79…`, 템플릿 sha256 `575a6849…`. 학습 전 사본과 판정 뒤 main `d624550aa10f` 에서 같다 |
| 기본 모델 | Tinker `thinkingmachines/Inkling-2-Small:peft:262144`, `reasoning_effort` low, `max_tokens` 32,768 |
| A | 같은 모델의 LoRA. rank 8, 학습률 2e-4 고정, 한 step 에 예시 4건, 한 번 돌기 |
| E-real | 고정된 50건 |
| E-synth | 고정된 합친 E-synth 90건, `requests_sha256` `8aa43fde…` |
| 학습 요청 | 라벨 감사를 통과한 199건, sha256 `5c7937dd…` |

실행 폴더는 git 이 무시하는 `artifacts/tinker/librarian/` 아래에 있다. 폴더마다 남은 파일의 sha256 은 `runs.json` 에 있다.

## 학습까지

| 단계 | 수 | 근거 |
| --- | --- | --- |
| 학습 split 생성 | 요청 384건, 기억 66개, Keeper 8명 | `runs.json` `train-split.kinds.before` |
| 블라인드 라벨 감사 뒤 | 요청 199건, 기억 38개, Keeper 8명 | `runs.json` `train-split.kinds.after` |
| 교사 답이 필터를 통과 | 199건 중 199건. 바로 채택 143건, 흡수가 있어 합침 판정을 기다린 답 56건 | `runs.json` `teacher.summary` |
| 교사 답의 흡수 판정 | 흡수 67개 중 mergeable 48개, loses_knowledge 19개 | `runs.json` `teacher.accepted` |
| 채택 | 181건. 기다린 56건 중 38건이 들어갔다 | 같은 곳 |
| 학습 | 예시 181건, step 46번(4건 45번과 1건 1번), 토큰 9,524,712, 556초 | `runs.json` `train-A` |

- 라벨 감사는 384건을 모두 판정했다. 판정자는 Claude Opus 하위 세션 22개다. 감사가 fact 하나라도 틀렸다고 본 기억의 요청은 모두 빠진다.
- 교사는 기본 모델이다. 요청과 스키마 안내 사이에 그 요청의 라벨을 적은 글을 받고 답한다. 학습 예시에는 라벨 글과 교사의 생각 부분이 없다.
- 학습 예시는 요청, 스키마 안내, 답 셋이다. loss 는 답 토큰에만 건다. 답 토큰은 266,297개로 전체 9,524,712개의 2.8% 다(`runs.json` `train-A.examples_check`).
  학습 전에 예시 181건을 모두 렌더링해 봤다. 읽히는 글, loss 가 걸리는 구간, 엔드포인트가 센 프롬프트 토큰 수가 181건 모두 맞았다(같은 곳 `checks`).

step 마다 잰 loss 는 그 step 의 예시를 학습하기 전 가중치로 잰 값이다(`tables.py` 의 `train.loss_by_block`).

| step | 0~7 | 8~15 | 16~23 | 24~31 | 32~39 | 40~45 |
| --- | --- | --- | --- | --- | --- | --- |
| 평균 loss | 0.1275 | 0.1314 | 0.1190 | 0.1076 | 0.1136 | 0.1133 |

step 하나의 loss 는 0.0466 에서 0.2442 사이다.

## E-real 50건

같은 실행에서 기본 모델과 A 가 같은 요청에 답했다(`tables.py` 의 `real`).

| | 기본 모델 | A |
| --- | --- | --- |
| HTTP 200 | 49 | 49 |
| 유효한 답 | 42 | 38 |
| 생각 부분 없는 답 | 0 | 49 |
| 답 토큰 중앙값 | 2,014 | 900 |
| 지연 p50 | 36.89초 | 22.68초 |
| 라이브가 안 지운 fact 를 지운 수 | 1개(요청 1건) | 10개(요청 5건) |
| 라이브가 안 흡수한 fact 를 흡수한 수 | 1 | 2 |
| 더한 claim (라이브 53) | 29 | 22 |
| 뺀 기억 (라이브 32) | 18 | 16 |

무효 사유다.

| 사유 | 기본 모델 | A |
| --- | --- | --- |
| `memory_claim_absent` | 5 | 3 |
| `no_answer` | 2 | 2 |
| `new_claim_without_support` | 1 | 2 |
| `absorbs_dropped_memory_id` | 0 | 3 |
| `absorbs_unknown_memory_id` | 0 | 1 |
| `supersedes_not_dropped` | 0 | 1 |

두 모델의 답이 모두 유효한 요청은 33건이고 후보는 52개다. 후보마다 라이브, 기본 모델, A 의 판정을 나란히 셌다.

| 라이브 | 기본 모델 | A | 후보 |
| --- | --- | --- | --- |
| incorporated | incorporated | incorporated | 13 |
| incorporated | incorporated | not_durable | 9 |
| not_durable | not_durable | not_durable | 9 |
| already_represented | incorporated | not_durable | 3 |
| already_represented | not_durable | not_durable | 3 |
| incorporated | not_durable | not_durable | 3 |
| already_represented | already_represented | already_represented | 2 |
| already_represented | already_represented | incorporated | 2 |
| incorporated | already_represented | incorporated | 2 |
| incorporated | already_represented | not_durable | 2 |
| 그 밖 네 묶음 | | | 1개씩 |

- `not_durable` 로 본 후보는 라이브 9개, 기본 모델 15개, A 31개다.
- 라이브와 같은 판정은 기본 모델 37개, A 26개다.

## E-synth 90건

`tables.py` 의 `synth` 다. 무효 답은 모든 칸에서 틀린 것으로 센다.

| | 기본 모델 | A |
| --- | --- | --- |
| 유효한 답 | 82 | 78 |
| 생각 부분 없는 답 | 0 | 90 |
| 답 토큰 중앙값 | 2,371.5 | 1,135.5 |
| 지연 p50 | 34.5초 | 16.3초 |
| 남는 기억이 맞은 후보 (125) | 108 | 97 |
| 판정 단어가 맞은 후보 (125) | 106 | 96 |
| 지운 fact | 43 | 52 |
| 그중 라벨이 바란 지우기 | 34 | 32 |
| 그중 합쳐야 할 fact 를 지움 | 0 | 1 |
| 그중 라벨 밖 지우기 | 9 | 19 |
| 심은 낡은 상태를 지움 (81) | 18 | 18 |
| 쓸 날이 지난 기록을 지움 (16) | 2 | 1 |
| 쓸 날이 남은 기록을 지움 (34) | 7 | 6 |
| 라벨이 바란 합침을 함 (37) | 9 | 6 |
| 그중 중복 쌍 (23) | 1 | 0 |
| 흡수한 fact | 16 | 14 |

후보 종류별로 남는 기억이 맞은 수다.

| 종류 | 후보 | 기본 모델 | A |
| --- | --- | --- | --- |
| 보완 | 14 | 8 | 6 |
| 교정 | 21 | 15 | 15 |
| 새 지식 | 30 | 28 | 22 |
| 바꿔 말하기 | 27 | 25 | 21 |
| 일시 상태 | 33 | 32 | 33 |

- 두 모델의 답이 모두 유효한 요청은 74건이고 후보는 101개다. 남는 기억이 맞은 후보는 기본 모델 95개, A 92개다.
- 무효 사유는 기본 모델이 `new_claim_without_support` 6건과 `memory_claim_absent` 2건이다.
  A 는 `memory_claim_absent` 6건, `new_claim_without_support` 3건, `absorbs_dropped_memory_id` 2건, `supersedes_not_dropped` 1건이다.

## 블라인드 판정

판정자는 Claude Opus 하위 세션이다. 라벨, 답을 낸 모델, 다른 판정자의 결과를 받지 않는다(`tables.py` 의 `judged`).

| 판정 | case | 판정자 | 결과 |
| --- | --- | --- | --- |
| 라벨 밖 지우기 28개 | 15 | 2 | 28개 모두 keep. 기본 모델 9개, A 19개 |
| 흡수 30개 | 30 | 3 | mergeable 13개, loses_knowledge 13개, different_context 4개 |

| 흡수 판정 | 기본 모델 | A |
| --- | --- | --- |
| mergeable | 8 | 5 |
| loses_knowledge | 7 | 6 |
| different_context | 1 | 3 |
| 라벨이 바란 합침 37개 중 mergeable 로 판정된 합침 | 6 | 3 |

## 비용

공개 단가로 센 값이다. 판정 실행은 요청마다 두 번 부른다. 첫 호출이 캐시를 채우고 둘째 호출을 잰다.

| 실행 | 호출 | 비용 |
| --- | --- | --- |
| 교사 199건 | 204 | $1.4258 |
| 학습 | step 46번 | $28.5741 |
| 판정 E-real | 200 | $2.267 |
| 판정 E-synth | 360 | $1.9215 |

## 알아 둘 것

- 학습도 판정 실행도 한 번이다. A 를 다시 학습했을 때 숫자가 얼마나 흔들리는지는 재지 않았다.
- 기본 모델은 실행마다 흔들린다. 같은 고정값으로 잰 기준선 두 번에서 낡은 상태 재현율은 25/81 과 15/81, 라벨이 바란 합침은 12/37 과 9/37, 남는 기억 정확도는 111/125 와 108/125 였다([앞 기록](../2026-11-12-librarian-teacher-label-note/README.md)).
  A 의 18/81 은 그 사이에 든다.
- 학습 설정은 다른 값과 견주지 않았다. 학습률, rank, step 수, 한 step 의 예시 수가 그렇다.
- E-real 에서 A 가 지운 10개가 틀린 지우기인지는 판정하지 않았다. G2 는 라이브 답과 다른 지우기를 센다.
- 판정자의 흡수 판정을 라이브 흡수 게이트의 판정과 견주지 않았다.

## 다시 세는 법

```sh
python3 collect.py <artifacts/tinker/librarian> .   # verdict.json, runs.json, rows.jsonl 을 다시 쓴다
python3 tables.py .                                 # 이 글의 숫자를 낸다
```

판정에 쓴 명령이다. 예산 인자와 체크포인트 경로는 적지 않았다.

```sh
uv run --python 3.12 scripts/tinker/librarian/train_sft.py --requests <학습 요청> --teacher <교사 폴더> --out <train-A>
uv run --python 3.12 scripts/tinker/librarian/eval_admission.py run --set real --target base=<기본 모델> --target A=<체크포인트> --out <verdict-real>
uv run --python 3.12 scripts/tinker/librarian/eval_admission.py run --set synth --requests <E-synth> --target base=<기본 모델> --target A=<체크포인트> --out <verdict-synth>
uv run --python 3.12 scripts/tinker/librarian/e_synth_audit.py drops --requests <E-synth> --run <verdict-synth> --out <verdict-drops>
uv run --python 3.12 scripts/tinker/librarian/merge_cases.py --requests <E-synth> --run <verdict-synth> --out <verdict-merges>
uv run --python 3.12 scripts/tinker/librarian/eval_admission.py verdict --real <verdict-real> --synth <verdict-synth> --drops <verdict-drops> --merges <verdict-merges> --train A=<train-A>
```

E-real 실행은 `MASC_BASE_PATH` 로 E-real 사본을 가리킨다.
