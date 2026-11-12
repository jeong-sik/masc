# 교사에게 라벨을 보여 주는 변경의 측정 기록, 2026-11-12

[#51431](https://github.com/jeong-sik/masc/pull/51431)이 이 기록을 근거로 쓴다.
이 폴더에는 숫자와 이름만 있다. 합성 요청 본문과 모델 답 원문은 넣지 않았다.

## 무엇을 확인했나

- 라벨을 모르고 답한 기본 모델의 답이 교사 필터를 얼마나 통과하는가.
- 기본 답이 라벨과 같으면 라벨이 맞다고 볼 수 있는가.
- 라벨 글을 받은 교사의 답이 필터를 얼마나 통과하는가.
- 그 답의 reason 이 라벨 글을 출처로 말하는가. 라벨 글의 말을 얼마나 되풀이하는가.

## 소스와 입력

| 항목 | 값 |
| --- | --- |
| 코드 | #51416 head `59b4a6b1144f`의 `scripts/tinker/librarian/`에 이 PR의 변경을 더한 사본. main `14011f5077b8`의 같은 폴더와 트리가 같다 |
| 고정값 | `pass_lines.json` sha256 `94c12b79…`, 템플릿 sha256 `575a6849…` |
| 모델 | Tinker `thinkingmachines/Inkling-2-Small:peft:262144`, `reasoning_effort` low, `max_tokens` 32,768 |
| 기준선 요청 | 합친 E-synth 90건, `requests_sha256` `8aa43fde…` |
| 파일럿 1 요청 | E-synth 배치 2 생성본 136건 중 라벨 감사가 뺀 83건에서 seed 20261112로 뽑은 20건 |
| 파일럿 2 요청 | 같은 생성본에서 라벨 감사가 남긴 53건에서 seed 20261112로 뽑은 20건 |

- 파일럿 2의 20건은 고정된 E-synth 에 든 요청이다. 파일럿 1의 20건은 E-synth 에 없다.
- 두 파일럿의 답은 학습에 쓰지 않는다. `train_sft.py`는 평가용 Keeper 의 요청을 받지 않는다.

## 라벨 없이 답한 기본 모델

고정값으로 잰 기준선 두 번의 답을 `teacher_sample.rejection`으로 다시 봤다(`filter_pass.py`).
기준선은 요청과 스키마 안내만 받는다.

| | 실행 1 | 실행 2 |
| --- | --- | --- |
| 요청 | 90 | 90 |
| 필터 통과 | 35 | 32 |
| 유효하지 않은 답 | 4 | 8 |
| `outcome` | 11 | 12 |
| `memory_state` | 4 | 1 |
| `stale_kept` | 26 | 31 |
| `duplicate_kept` | 6 | 4 |
| `unexpected_drop` | 4 | 2 |

통과 건수를 요청의 종류로 나누면 아래와 같다.
후보가 기억 변경을 지지하는 71건은 요청에 심긴 낡은 상태와 중복 쌍의 수로 나눴다.

| 요청 | 건수 | 실행 1 통과 | 실행 2 통과 |
| --- | --- | --- | --- |
| 지지 후보 있음, 심긴 것 0 | 19 | 16 | 14 |
| 지지 후보 있음, 심긴 것 1 | 15 | 0 | 0 |
| 지지 후보 있음, 심긴 것 2 이상 | 37 | 3 | 3 |
| 지지 후보 없음 | 19 | 16 | 15 |

- 지지 후보가 없는 요청은 기억을 바꾸지 않는 답이 맞다.
- 같은 두 실행에서 하네스가 낸 점수다. 낡은 상태 재현율은 25/81과 15/81이다. 라벨 합침 재현율은 12/37과 9/37이다. 남는 기억 정확도는 111/125와 108/125다.

## 기본 답이 라벨과 같아도 라벨이 틀린 경우

E-synth 라벨 감사는 기본 답이 라벨과 달랐던 요청을 모두 판정하고, 나머지를 표본으로 판정한다.
나머지는 기본 답이 라벨과 같았거나 유효하지 않았던 요청이다. 아래 두 감사는 나머지도 전부 판정했다(`audit_strata.py`).

| 감사 | 뽑힌 까닭 | case | 라벨이 판정과 어긋남 | 그중 후보 라벨 | 그중 기억 라벨만 |
| --- | --- | --- | --- | --- | --- |
| 배치 2 | 기본 답이 라벨과 다름 | 79 | 35 | 14 | 21 |
| 배치 2 | 같았거나 무효 | 57 | 21 | 8 | 13 |
| 배치 1 둘째 | 기본 답이 라벨과 다름 | 28 | 6 | 3 | 3 |
| 배치 1 둘째 | 같았거나 무효 | 29 | 3 | 1 | 2 |

## 파일럿: 라벨 글을 받은 교사

두 번 돌렸다.

| | 파일럿 1 | 파일럿 2 |
| --- | --- | --- |
| 라벨 글 | 처음 쓴 문장 | 이 PR의 문장 |
| 요청 | 감사가 뺀 요청 20건 | 감사가 남긴 요청 20건 |
| `sample`이 감사를 확인했나 | 확인하지 않던 때다 | `--audit`으로 배치 2 감사를 받았다 |

파일럿 1 뒤에 라벨 글의 네 줄을 고쳤다. 나머지 줄은 같다.

| 줄 | 파일럿 1 | 파일럿 2 |
| --- | --- | --- |
| 심긴 낡은 상태 | 한 시점의 상태만 적은 낡은 기억입니다. | 한 시점의 상태만 적은 기억입니다. |
| 일시적 후보 | 한 시점의 일시 상태입니다. | 한 시점의 일시적 상태입니다. |
| 이미 기억에 있는 지식 | 이 후보로 새 claim 을 쓰지 않습니다. | 이 후보로 새 claim 을 쓰지 않고, 대상은 그대로 남습니다. |
| 마지막 줄 | 그 밖의 기억은 모두 그대로 남습니다. | 이 글에 ID 가 나오지 않는 기억은 모두 그대로 남습니다. |

- 「낡은 기억」과 「일시 상태」는 고정 템플릿에 없는 말이다. 「한 시점의 상태만 적은 기억」과 「일시적 상태」는 템플릿에 있다.
- 고치기 전의 마지막 줄은 교정과 보완의 대상까지 그대로 남는다고 읽혔다.
- 파일럿 1의 문장은 저장소에 없다. 이 PR의 `sample`은 파일럿 1의 요청을 받지 않는다. 감사가 뺀 요청이기 때문이다.

표본 20건의 구성이다(`pilot_subset.py`).

| 항목 | 파일럿 1 | 파일럿 2 |
| --- | --- | --- |
| 기억 | 16개 | 14개 |
| 후보 new_durable | 9 | 5 |
| 후보 correction | 6 | 5 |
| 후보 complement | 1 | 4 |
| 후보 paraphrase | 10 | 7 |
| 후보 transient | 6 | 8 |
| 후보가 기억 변경을 지지하는 요청 | 18건 | 15건 |
| 그 요청에서 라벨이 빼라고 하는 낡은 상태 | 28개 | 21개 |
| 그 요청에서 라벨이 합치라고 하는 중복 쌍 | 5개 | 4개 |
| 그 요청에서 쓸 날이 남은 기록 | 4개 | 5개 |

`teacher_sample.py sample`의 결과다(`summary.json`, `call_stats.py`).

| 항목 | 파일럿 1 | 파일럿 2 |
| --- | --- | --- |
| 필터 통과 | 20건 중 20건 | 20건 중 20건 |
| 바로 채택(`kept.jsonl`) | 15건 | 12건 |
| 흡수가 있어 합침 판정을 기다림(`pending.jsonl`) | 5건 | 8건 |
| 통과한 시도 | 첫 시도 19건, 둘째 시도 1건 | 첫 시도 20건 |
| 통과하지 못한 시도 | 1건, `memory_claim_absent` | 없음 |
| 호출 | 21번. 모두 HTTP 200, finish `stop` | 20번. 모두 HTTP 200, finish `stop` |
| 답 토큰 중앙값 (최소~최대) | 2,373 (364~7,394) | 2,025 (320~4,756) |
| 호출 시간 중앙값 (최소~최대) | 52.2초 (5.1~133.5초) | 32.8초 (4.7~70.2초) |
| 입력 토큰 중앙값 (최소~최대) | 43,498 (31,526~71,525) | 63,038 (24,120~84,570) |
| 입력 토큰 중 캐시에서 읽은 비율 | 0.90 | 0.32 |
| 비용(공개 단가) | $0.1186 | $0.2929 |

- 파일럿 1의 요청 20건은 모두 감사가 뺀 요청이다. 감사가 라벨이 판정과 어긋난다고 본 요청과 기억에서도 교사는 라벨대로 답했다.
  교사 필터는 라벨이 틀린 요청을 걸러 내지 못한다. `sample`이 감사를 통과한 요청만 받는 까닭이다.

## reason 읽기

통과한 답 20개의 reason 을 셌다(`teacher_reasons.py`).

| | 파일럿 1 | 파일럿 2 |
| --- | --- | --- |
| reason | 66개 | 55개 |
| 지운 기억의 사유 | 34개 | 26개 |
| 후보 판정의 사유 | 32개 | 29개 |
| 생각 글 | 21개 | 20개 |

파일럿마다 reason 을 두 번 읽었다. 첫째는 이 PR을 쓴 세션이고, 둘째는 새로 띄운 Claude Opus 하위 세션이다.

- 파일럿 1의 하위 세션은 라벨 글을 만드는 코드와 reason 66개를 받았다.
- 파일럿 2의 하위 세션은 라벨 글을 만드는 코드, 고정 템플릿, reason 55개를 받았다.
- 두 하위 세션은 요청 본문과 첫째 판독의 결과를 받지 않았다.
- 네 판독 모두 라벨 글을 출처로 말한 reason 을 0개로 봤다.

라벨 글의 말이 든 reason 과 생각 글의 수다. 칸은 「reason / 생각 글」이다.

| 말 | 지금 라벨 글 | 고정 템플릿 | 파일럿 1 | 파일럿 2 |
| --- | --- | --- | --- | --- |
| 「확인한 사실」 | 머리말 | 없음 | 0 / 1 | 0 / 5 |
| 「아래 사실」 | 머리말 | 없음 | 0 / 1 | 0 / 2 |
| 「이 글」 | 머리말과 마지막 줄 | 없음 | 0 / 0 | 0 / 1 |
| 「낡은 기억」 | 없음 | 없음 | 10 / 3 | 0 / 0 |
| 「일시 상태」 | 없음 | 없음 | 2 / 1 | 0 / 0 |
| 「현재 기억에 없는」 | 있음 | 없음 | 6 / 0 | 4 / 0 |
| 「쓸 날이 이미 지난」 | 있음 | 없음 | 2 / 0 | 0 / 1 |
| 「더는 맞지 않」 | 있음 | 없음 | 2 / 0 | 4 / 0 |
| 「두 내용을 합」 | 있음 | 없음 | 0 / 0 | 1 / 0 |
| 「한 시점의 일시적」 | 있음 | 없음 | 0 / 0 | 1 / 1 |
| 「한 시점의 상태만 적은」 | 있음 | 있음 | 0 / 1 | 1 / 0 |
| 「표현만 바꿔」 | 있음 | 있음 | 1 / 0 | 1 / 1 |
| 「일시적 상태」 | 있음 | 있음 | 2 / 1 | 2 / 3 |

- 머리말의 말은 생각 글에만 나온다. 학습 예시에는 답만 들어가고 생각 글은 들어가지 않는다.
- 하위 세션은 라벨 글에 있고 고정 템플릿에 없는 말을 되풀이한 reason 을 꼽았다. 파일럿 1은 66개 중 25개다. 파일럿 2는 55개 중 12개다.
- 파일럿 2에는 「대상 mN」으로 시작하는 reason 이 4개 더 있다. 라벨 글은 대상을 「(대상 mN)」으로 적는다. 넷을 더하면 16개다.
- 파일럿 2에서 템플릿에도 있는 말을 되풀이한 reason 은 6개다.

## 파일

run은 git이 무시하는 `artifacts/tinker/librarian/` 아래에 있다. 모델 답과 reason 원문은 그 폴더에만 있다.

| 파일 | 줄 | sha256 |
| --- | --- | --- |
| `base-inkling-synth-1/rows.jsonl` (기준선 실행 1) | 90 | `d9cc7735fa6b…` |
| `base-inkling-synth-2/rows.jsonl` (기준선 실행 2) | 90 | `c93a276302c0…` |
| `e-synth-s2-audit/audit.json` (배치 2 감사) | 1,145 | `28aa3d588128…` |
| `e-synth-s2-audit/key.jsonl` | 136 | `e3e90c75d9ac…` |
| `scratch/pool-check/audit/audit.json` (배치 1 둘째 감사) | 440 | `ea7f289d6932…` |
| `scratch/pool-check/audit/key.jsonl` | 57 | `37640cfafeb5…` |
| `pilot-note-1/removed.jsonl` (감사가 뺀 요청) | 83 | `bf86b1d5b830…` |
| `pilot-note-1/requests.jsonl` (파일럿 1 요청) | 20 | `0f3036f79243…` |
| `pilot-note-1/teacher/calls.jsonl` | 21 | `eda7078e279b…` |
| `pilot-note-1/teacher/kept.jsonl` | 15 | `48bcb6e1e70b…` |
| `pilot-note-1/teacher/pending.jsonl` | 5 | `efe8effd02c0…` |
| `pilot-note-1/reader/reasons.txt` (하위 세션이 받은 reason 66개) | 106 | `d22cb6ef5c5c…` |
| `pilot-note-1/reader/report.md` (하위 세션의 보고) | 57 | `451294205918…` |
| `e-synth-s2/requests.jsonl` (감사가 남긴 요청) | 53 | `785fb4b56d58…` |
| `pilot-note-2/requests.jsonl` (파일럿 2 요청) | 20 | `5bc83a47c2fe…` |
| `pilot-note-2/teacher/calls.jsonl` | 20 | `949110867204…` |
| `pilot-note-2/teacher/kept.jsonl` | 12 | `8f47c7687040…` |
| `pilot-note-2/teacher/pending.jsonl` | 8 | `743385075730…` |
| `pilot-note-2/reader/reasons.txt` (하위 세션이 받은 reason 55개) | 95 | `b6942b5fe0fd…` |
| `pilot-note-2/reader/report.md` (하위 세션의 보고) | 57 | `4ebe0eafe6a5…` |

## 명령

```sh
cd <이 PR의 checkout>
H=scripts/tinker/librarian
B=docs/evidence/research/2026-11-12-librarian-teacher-label-note
A=artifacts/tinker/librarian
WORDS=("이 글" "확인한 사실" "아래 사실" "낡은 기억" "일시 상태" "현재 기억에 없는" "쓸 날이 이미 지난"
       "더는 맞지 않" "두 내용을 합" "한 시점의 일시적" "한 시점의 상태만 적은" "표현만 바꿔" "일시적 상태")

uv run $B/filter_pass.py $A/e-synth-pooled/requests.jsonl $A/base-inkling-synth-1
uv run $B/filter_pass.py $A/e-synth-pooled/requests.jsonl $A/base-inkling-synth-2
python3 $B/audit_strata.py $A/e-synth-s2-audit
python3 $B/audit_strata.py $A/scratch/pool-check/audit

# 파일럿 2
python3 $B/pilot_subset.py $A/e-synth-s2/requests.jsonl 20 20261112 $A/pilot-note-2/requests.jsonl
uv run $H/teacher_sample.py sample --requests $A/pilot-note-2/requests.jsonl \
  --audit $A/e-synth-s2-audit --out $A/pilot-note-2/teacher --budget 1.2
python3 $B/call_stats.py $A/pilot-note-2/teacher
python3 $B/teacher_reasons.py $A/pilot-note-2/teacher 400 "${WORDS[@]}"

# 파일럿 1: 요청 파일과 남은 호출 로그를 다시 센다. `sample` 호출은 이 PR의 코드로 되풀이할 수 없다.
python3 $B/pilot_subset.py $A/pilot-note-1/removed.jsonl 20 20261112 $A/pilot-note-1/requests.jsonl
python3 $B/call_stats.py $A/pilot-note-1/teacher
python3 $B/teacher_reasons.py $A/pilot-note-1/teacher 400 "${WORDS[@]}"
```

- `removed.jsonl`은 배치 2 생성본에서 감사 뒤 파일에 없는 줄을 생성본 순서로 모은 파일이다.
- `reasons.txt`는 `kept.jsonl`과 `pending.jsonl`의 reason 을 답 순서대로 번호를 붙여 적은 파일이다.
- 스크립트 다섯은 숫자를 센 스크립트의 사본이다. 하네스는 이 스크립트를 부르지 않는다.

## 확인하지 못한 것

- 파일럿 요청은 모두 평가용 Keeper 의 요청이다. 학습 split 은 이 기록을 쓸 때 라벨 감사를 받기 전이었다.
- 흡수 답은 합침 판정을 받지 않았다. 파일럿 1에 5건, 파일럿 2에 8건이다.
- 판독자는 요청 본문 없이 reason 만 읽었다. reason 에 적힌 내용이 그 요청의 기억과 후보에 있는지는 대조하지 않았다.
- 교사의 reason 이 라벨 글의 말을 되풀이하면 학습한 모델의 reason 이 어떻게 달라지는지는 재지 않았다.
- 교사 필터는 reason 의 글을 보지 않는다. 파일럿 2의 reason 하나에는 키릴 글자 조각이 섞여 있고, 그 답은 `kept.jsonl`에 있다.
- 감사 기록에는 판정한 요청 파일의 sha256 이 없다. `sample`은 요청과 case 를 item ID 로만 맞춘다([#51432](https://github.com/jeong-sik/masc/issues/51432)).
- 라벨 글로 만든 답으로 학습한 모델이 게이트를 넘는지는 이 기록으로 알 수 없다.
- 배치 1 첫째 감사의 case별 판정은 2026-11-11에 지워져서 위 표에 없다.
