# keeper-librarian 프롬프트 비교의 기준선, 2026-11-13

`scripts/tinker/librarian/prompt_lines.json` 에 두 모델의 기준선을 숫자로 고정했다.
[RFC-0517](../../../rfc/RFC-0517-the-librarian-keeps-one-correct-fact-per-piece-of-knowledge.md) §2.3 의 프롬프트 비교(`prompt_compare.py`)는 초안 실행을 이 숫자와 견준다.
[2026-11-12 재고정](../2026-11-12-librarian-harness-repin/README.md) 뒤로 기준선이 비어 있었다.

- 고정 템플릿(`config/prompts/librarian.md`, sha256 `575a6849…`)으로 고정 세트 둘을 쟀다. E-synth 는 90건, E-real 은 50건이다.
- Inkling 2 Small 기본 모델은 두 번, GLM `glm-5.3-flash` 는 한 번 쟀다. 횟수는 `prompt_lines.json` 의 `runs` 가 정한다.
- 실행마다 라벨 밖 지우기와 흡수를 블라인드 판정자가 판정한 뒤에 셌다.
- 고정한 숫자는 `prompt_compare.py baseline` 의 출력 그대로다.

이 폴더에는 숫자, 라벨, ID 만 있다. 요청 본문, 기억 문장, 모델 답 원문은 넣지 않았다.

## 고정한 숫자

`a/b` 는 맞은 수와 기회 수다. 비교는 「고정값」 열을 쓴다. Inkling 의 고정값은 두 실행을 더한 값이다.

| 지표 | inkling 1 | inkling 2 | inkling 고정값 | glm 고정값 |
| --- | --- | --- | --- | --- |
| `synth_valid_rate` | 86/90 = 0.956 | 82/90 = 0.911 | 168/180 = 0.933 | 80/90 = 0.889 |
| `real_valid_rate` | 44/50 = 0.880 | 46/50 = 0.920 | 90/100 = 0.900 | 40/50 = 0.800 |
| `memory_state_accuracy` | 111/125 = 0.888 | 108/125 = 0.864 | 219/250 = 0.876 | 109/125 = 0.872 |
| `stale_drop_recall` | 25/81 = 0.309 | 15/81 = 0.185 | 40/162 = 0.247 | 54/81 = 0.667 |
| `judged_merge_recall` | 9/37 = 0.243 | 6/37 = 0.162 | 15/74 = 0.203 | 17/37 = 0.459 |
| `drop_precision` | 41/55 = 0.745 | 31/41 = 0.756 | 72/96 = 0.750 | 74/95 = 0.779 |
| `absorb_precision` | 16/30 = 0.533 | 6/14 = 0.429 | 22/44 = 0.500 | 26/49 = 0.531 |

| 지표 | 뜻 |
| --- | --- |
| `synth_valid_rate` | 채점한 E-synth 요청 중 답이 검사기를 통과한 비율 |
| `real_valid_rate` | E-real 50건 중 답이 검사기를 통과한 비율. 엔드포인트가 거절한 요청도 분모에 든다 |
| `memory_state_accuracy` | 후보마다, 답을 적용한 뒤 남는 기억이 라벨과 같은 상태인 비율 |
| `stale_drop_recall` | 심은 낡은 상태 fact 중 답이 지운 비율 |
| `judged_merge_recall` | 라벨이 바란 합침 중, 답이 했고 판정자가 그 흡수를 모두 `mergeable` 로 본 비율 |
| `drop_precision` | 답이 지운 fact 중 라벨이 지우라고 한 비율 |
| `absorb_precision` | 답의 흡수 중 판정자가 `mergeable` 로 본 비율 |

기준선에는 그 숫자를 센 기준 셋의 sha256 이 같이 적혀 있다.

| 기준 | sha256 |
| --- | --- |
| `pass_lines.json` | `94c12b7943d1…` |
| 템플릿 `config/prompts/librarian.md` | `575a68497f00…` |
| `prompt_counts.py` | `a7a1fb47ac86…` |

셋 중 하나가 바뀌면 `prompt_lines.py` 가 파일을 거절한다. 그때는 기준선을 다시 세어 고정한다.

## 숫자가 나온 실행

| 실행 | 모델 | E-synth `rows.jsonl` sha256 | E-real `rows.jsonl` sha256 |
| --- | --- | --- | --- |
| inkling 1 | `thinkingmachines/Inkling-2-Small:peft:262144` | `d9cc7735fa6b…` | `f79b01818b37…` |
| inkling 2 | `thinkingmachines/Inkling-2-Small:peft:262144` | `c93a276302c0…` | `6280af109ca3…` |
| glm 1 | `glm-5.3-flash` | `3c76f9fa739e…` | `c6bced504463…` |

- 전체 sha256 은 `prompt_lines.json` 과 `counts.json` 에 있다.
- 실행 폴더와 판정 폴더의 경로는 `baseline-runs.json` 에 있다. 모두 `artifacts/tinker/librarian/` 아래이고 git 이 무시한다.
- 비교는 이 폴더들을 읽지 않는다. 고정한 숫자를 다시 확인할 때만 읽는다.

## 답이 끝난 모양

| 실행 | 세트 | 유효/요청 | 200 응답 | HTTP | 200 응답의 finish | 무효 사유 | 답 토큰 p50 | 초 p50 | 실행 전체 비용 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| inkling 1 | E-synth | 86/90 | 90 | 200 90 | stop 90 | memory_claim_absent 1, new_claim_without_support 3 | 2,193 | 22.84 | $0.6892 |
| inkling 1 | E-real | 44/50 | 49 | 200 49, 400 1 | stop 49 | evidence_not_in_input 1, memory_claim_absent 4, no_answer 1 | 1,902 | 22.89 | $1.1643 |
| inkling 2 | E-synth | 82/90 | 90 | 200 90 | stop 90 | memory_claim_absent 4, new_claim_without_support 4 | 2,016.5 | 23.55 | $0.5048 |
| inkling 2 | E-real | 46/50 | 49 | 200 49, 400 1 | length 1, stop 48 | memory_claim_absent 2, no_answer 2 | 2,188 | 22.82 | $0.3528 |
| glm 1 | E-synth | 80/90 | 90 | 200 90 | length 7, stop 83 | memory_claim_absent 1, new_claim_without_support 2, no_answer 7 | 16,010.5 | 286.87 | — |
| glm 1 | E-real | 40/50 | 50 | 200 50 | length 5, stop 45 | memory_claim_absent 1, missing_required_key 1, new_claim_without_support 3, no_answer 5 | 13,599 | 234.61 | — |

- 「유효/요청」은 그 모델에 보낸 요청 전부를 센다. `synth_valid_rate` 는 판정자의 지우기 판정으로 채점에서 빠진 기억의 요청을 뺀다. 이번에는 빠진 기억이 없어서 두 값이 같다.
- 「200 응답」은 HTTP 200 이고 본문에 오류가 없는 호출이다(`eval_admission.summarize` 와 같은 셈). finish, 답 토큰, 초는 이 호출만 센다.
- `prompt_lines.json` 의 `answered_sha256` 은 행마다 호출 하나를 고정한다. 엔드포인트가 HTTP 400 으로 거절한 호출도 든다. 그래서 Inkling 실행은 200 응답 139건(90 + 49)보다 하나 많은 140건을 고정한다. `counts.json` 의 `answered_calls` 가 이 수다.
- 「실행 전체 비용」은 그 실행이 쓴 공개 단가 금액 전부다. Tinker 실행은 요청마다 같은 프롬프트를 두 번 보내고, 첫 번째(warm) 호출의 금액도 여기에 든다.
- Inkling 두 실행의 비용 차이는 거의 입력 캐시에서 온다. 캐시 안 된 입력은 E-synth 에서 644,812토큰과 11,596토큰, E-real 에서 3,007,558토큰과 6,470토큰이다. 공개 단가로 E-synth 차이 $0.1844 중 $0.1710, E-real 차이 $0.8115 중 $0.8103 이 캐시 몫이다.
- E-real 의 한 요청(`7ac0f0a0dd5ae910`)은 Tinker 엔드포인트가 두 번 모두 HTTP 400 으로 거절했다. 후보 A 판정 실행에서도 같은 요청이 거절됐다.
- GLM 답 12건(E-synth 7건, E-real 5건)은 고정 상한 `max_tokens` 32,768 에서 잘렸다. 모두 `length` 로 끝나 `no_answer` 로 무효다. Tinker 가 거절한 `7ac0f0a0dd5ae910` 도 GLM 은 받았지만 같은 상한에서 잘렸다. 라이브 GLM 슬롯은 아직 `max_tokens` 를 보내지 않는다([README](../../../../scripts/tinker/librarian/README.md)). 라이브에서도 이만큼 잘리는지는 이 실행으로 알 수 없다. GLM 호출은 금액 대신 키의 사용량 한도를 써서 비용 칸은 `—` 다.

## E-real 기록

비교는 아래 값을 판정에 쓰지 않는다. RFC-0517 §2.3 은 바뀐 지우기 목록을 사람이 보게 한다.

| 실행 | 라이브와 같은 판정 | 라이브가 남긴 기억을 지운 수 |
| --- | --- | --- |
| inkling 1 | 44/64 = 0.688 | 3 |
| inkling 2 | 44/57 = 0.772 | 1 |
| glm 1 | 39/46 = 0.848 | 1 |

- 분모는 유효한 답이 다룬 후보 수다. 실행마다 유효한 요청이 달라서 분모도 다르다.
- `eval_admission.py` 요약의 `outcome_agreement` 는 무효인 답의 후보까지 분모에 넣는다. 그래서 위 값과 다르다.

## 판정자

| 실행 | 라벨 밖 지우기의 판정 | 채점에서 빠진 기억 | 흡수의 판정 | 지우기 판정 파일 sha256 | 흡수 판정 파일 sha256 |
| --- | --- | --- | --- | --- | --- |
| inkling 1 | keep 13 | 0 | loses_knowledge 14, mergeable 16 | `5e3b256a1785…` | `a715ca2e428e…` |
| inkling 2 | keep 10 | 0 | loses_knowledge 8, mergeable 6 | `381919bbe9c3…` | `9bac6e76b9ea…` |
| glm 1 | keep 21 | 0 | loses_knowledge 23, mergeable 26 | `74d60ef1c3bd…` | `c958a2dc3ebd…` |

- 판정자는 Claude Opus 하위 에이전트다. 라벨, 대상 모델, 다른 판정자의 폴더는 보지 못한다.
- 지우기 사례는 요청의 후보와 기억 fact 를 보여 주고, 답은 보여 주지 않는다. 흡수 사례는 흡수된 fact, 합친 claim, 그 claim 이 인용한 후보를 보여 준다.
- 지우기 사례는 실행마다 판정자 한 명이 모두 봤다(inkling 1 8건, inkling 2 6건, glm 1 14건). 흡수 사례는 inkling 1 의 30건을 세 명이, inkling 2 의 14건을 한 명이, glm 1 의 43건을 네 명이 나눠 봤다. 사례 하나가 지우기나 흡수 여럿을 담을 수 있어서, 위 표는 판정을 지우기와 흡수마다 센다.
- Inkling 두 실행의 판정자는 따로, 같은 요청(`eval-support-triage-08-087`)의 fact 하나(`m11`)를 `drop` 으로 봤다. 라벨은 `keep` 이다. 세 실행의 어느 답도 `m11` 을 지우지 않아서 이 판정은 채점에 쓰이지 않았다.
- 판정 파일의 sha256 은 숫자를 센 때의 값이다. `prompt_lines.json` 은 판정 파일을 고정하지 않고 센 숫자를 고정한다.

## 초안이 넘어야 하는 선

`prompt_lines.json` 의 폭은 나빠짐 2.5σ, 좋아짐 2σ 다. 아래는 기회 수가 기준선과 같은 초안이 그 선을 넘는 맞은 수다.

| 모델 | 지표 | 기준선 | 나빠짐 | 채택 근거가 되는 좋아짐 |
| --- | --- | --- | --- | --- |
| inkling | `synth_valid_rate` | 168/180 = 0.933 | 153 이하 | — |
| inkling | `real_valid_rate` | 90/100 = 0.900 | 76 이하 | — |
| inkling | `memory_state_accuracy` | 219/250 = 0.876 | 198 이하 | 233 이상 |
| inkling | `stale_drop_recall` | 40/162 = 0.247 | 22 이하 | 57 이상 |
| inkling | `judged_merge_recall` | 15/74 = 0.203 | 4 이하 | 26 이상 |
| inkling | `drop_precision` | 72/96 = 0.750 | 55 이하 | — |
| inkling | `absorb_precision` | 22/44 = 0.500 | 10 이하 | — |
| glm | `synth_valid_rate` | 80/90 = 0.889 | 67 이하 | — |
| glm | `real_valid_rate` | 40/50 = 0.800 | 28 이하 | — |
| glm | `memory_state_accuracy` | 109/125 = 0.872 | 93 이하 | — |
| glm | `stale_drop_recall` | 54/81 = 0.667 | 38 이하 | — |
| glm | `judged_merge_recall` | 17/37 = 0.459 | 6 이하 | — |
| glm | `drop_precision` | 74/95 = 0.779 | 58 이하 | — |
| glm | `absorb_precision` | 26/49 = 0.531 | 13 이하 | — |

- 채택 근거가 되는 좋아짐은 `inkling` 의 `memory_state_accuracy`, `stale_drop_recall`, `judged_merge_recall` 뿐이다(`better_from`). 나머지 줄의 좋아짐은 기록만 되어서 `—` 로 적었다.
- 초안의 기회 수는 기준선과 다를 수 있다. `drop_precision` 과 `absorb_precision` 은 각각 초안이 지운 수와 흡수한 수가 기회 수다.
- 판정자가 초안의 라벨 밖 지우기 하나를 `keep` 이 아니라고 보면, 그 기억의 요청은 모두 채점에서 빠진다(`audit_decisions.Adjudication.scored`). 그러면 `synth_valid_rate`, `memory_state_accuracy`, `stale_drop_recall`, `judged_merge_recall` 의 기회 수도 준다.
- 표는 기회 수가 기준선과 같을 때의 값이다.
- 차이가 폭과 정확히 같으면 나빠짐도 좋아짐도 아니다.

## 재지 않은 것과 남는 조건

- GLM 은 한 번 쟀다. 실행 사이의 퍼짐은 모른다. Inkling 두 실행은 `stale_drop_recall` 이 25/81 과 15/81 로 달랐다.
- 블라인드 판정자와 라이브 흡수 게이트가 같은 흡수를 같게 보는지는 재지 않았다.
- 실행 폴더와 판정 폴더는 한 대의 디스크에만 있다. 없어져도 비교는 돈다. 다만 고정한 숫자를 `baseline_counts.py` 로 다시 확인할 수는 없게 된다.
- CI 는 이 폴더의 스크립트를 돌리지 않는다.

## 다시 확인하는 법

저장소 루트에서 돌린다. `baseline-runs.json` 의 경로는 루트 기준이다.

```sh
# 고정한 숫자가 실행 폴더에서 다시 나오는지
uv run docs/evidence/research/2026-11-13-librarian-pinned-baseline/baseline_counts.py \
  docs/evidence/research/2026-11-13-librarian-pinned-baseline/baseline-runs.json > counts.json
python3 docs/evidence/research/2026-11-13-librarian-pinned-baseline/tables.py counts.json
```

`baseline_counts.py` 는 두 모델의 실행이 센 숫자가 고정값과 모두 같을 때만 0 으로 끝난다. 이 폴더의 `counts.json` 은 그렇게 끝난 실행의 출력이다.

표 밖의 숫자 가운데 몇 개는 `counts.json` 에 없다. 캐시 안 된 입력 토큰, 거절되거나 잘린 요청의 ID, 판정 사례 수와 판정자 수, `m11` 판정이 그렇다. 이 값들은 실행 폴더와 판정 폴더에서 직접 셌다.

기준선을 처음부터 다시 만드는 순서는 아래와 같다.

```sh
# 실행 (E-real 은 MASC_BASE_PATH 로 스냅샷을 준다)
uv run scripts/tinker/librarian/eval_admission.py run --set synth --requests <E-synth requests.jsonl> \
  --provider tinker --target base=thinkingmachines/Inkling-2-Small:peft:262144 --out <synth run>
uv run scripts/tinker/librarian/eval_admission.py run --set synth --requests <E-synth requests.jsonl> \
  --provider glm --target glm=glm-5.3-flash --max-calls <n> --out <synth run>

# 판정 사례. 판정자가 decisions.jsonl 을 쓴 뒤에 다음으로 간다
uv run scripts/tinker/librarian/e_synth_audit.py drops --requests <E-synth requests.jsonl> --run <synth run> --out <drops>
uv run scripts/tinker/librarian/merge_cases.py --requests <E-synth requests.jsonl> --run <synth run> --out <merges>

# 기준선 숫자. 출력을 prompt_lines.json 의 baseline 에 넣는다
uv run scripts/tinker/librarian/prompt_compare.py baseline --runs <runs.json>
```
