# librarian 답이 남긴 기억 측정 기록, 2026-11-09

[연구 문서](../../../research/2026-11-09-librarian-keeps-one-correct-fact.md)가 이 기록을 해석한다.
[RFC-0517](../../../rfc/RFC-0517-the-librarian-keeps-one-correct-fact-per-piece-of-knowledge.md)이 이 기록을 근거로 쓴다.
모델은 다시 부르지 않았다. 이미 저장된 답과 라벨을 다시 셌다.
스크립트는 숫자와 고정된 이름만 출력한다. 기억 본문과 답 원문은 출력하지 않는다.

## 무엇을 확인했나

- admission 답을 판정 단어 대신 답이 남긴 기억으로 채점하면 점수가 어떻게 달라지나.
- 고정한 E-synth의 낡은 상태 라벨 가운데 MASC 계약 안에서 맞힐 수 있는 몫은 얼마나 되나.
- admission 한 번이 기억을 얼마나 키우나. 같은 기록에서 라이브 답과 기본 모델 답을 견준다.
- effort `high` 교사가 effort `low` 기본 모델보다 나은가. 교사 필터는 학습 데이터를 어떻게 고르나.

## 소스와 입력

| 항목 | 값 |
| --- | --- |
| 하네스 | T 스택 `tinker/librarian-drop-adjudication`(#50181) head `365233db560b`. 잴 때 맨 위 층이었다. 그 checkout의 `scripts/tinker/librarian/`를 import 한다 |
| 고정값 | `pass_lines.json` sha256 `63fee812…`. `eval_admission.load_pass_lines()`로 고정 파일 19개가 모두 맞는지 확인했다 |
| 프롬프트 | `config/prompts/librarian.md` sha256 `ec5cb66f…`. main `57b928783c0b`의 파일과 같다 |
| E-real | 기록 99건. MASC 저장소(`MASC_BASE_PATH`)에서 제자리로 읽었다. manifest sha256 `16d3a90a…`는 `pass_lines.json`의 `e_real.manifest_sha256`과 같다 |
| effort | Tinker OpenAI 호환 문서에서 `low`는 0.2, `high`는 0.9다 (2026-11-09 확인) |

run은 git이 무시하는 `artifacts/tinker/librarian/` 아래에 있다. 모델 답과 E-real 기억 본문은 그 파일에만 있다.

| 파일 | 내용 | 줄 | sha256 |
| --- | --- | --- | --- |
| `e-synth-3/requests.jsonl` | 고정 E-synth 119건. `pass_lines.json`의 `e_synth.requests_sha256`과 같다 | 119 | `33060b5e…` |
| `synth-train-4/requests.jsonl` | 학습 split 404건 | 404 | `30388cbd…` |
| `eval-base-synth-3/calls.jsonl` | 기본 모델, effort `low`, 라벨 감사 전 144건. warm 호출 144개와 측정 호출 144개 | 288 | `1aa8b4f2…` |
| `eval-base-synth-3/rows.jsonl` | 같은 run의 채점 행 | 144 | `362a0021…` |
| `eval-base-real-3/calls.jsonl` | 기본 모델, effort `low`, E-real 99건 | 198 | `eab84bc8…` |
| `teacher-4/calls.jsonl` | 교사(같은 기본 모델, effort `high`), 학습 split. HTTP 200 시도 1,176개와 402 응답 65개 | 1,241 | `88709204…` |
| `teacher-4/accepted.jsonl` | `teacher_sample.py`가 학습용으로 남긴 답 | 185 | `8c38c92a…` |

## 명령

```sh
cd <365233db560b checkout; artifacts/tinker/librarian/ 에 위 run 이 있다>
for h in memory_state confusion effort_compare reachable_recall net_growth; do
  echo "## $h.py"
  MASC_BASE_PATH=<base> PYTHONDONTWRITEBYTECODE=1 uv run --quiet --python 3.12 <이 폴더>/$h.py
done > outputs.txt
```

`MASC_BASE_PATH`는 `net_growth.py`만 쓴다.
2026-11-09 02:53Z에 이 명령을 돌렸다.
head의 `scripts/tinker/librarian/`와 `config/prompts/librarian.md`만 `git archive`로 따로 풀고, `artifacts/`를 그 옆에 링크했다.

프롬프트 금지 명령형은 아래처럼 셌다.

```sh
P='마세요|지 말고|안 됩니다|[Dd]o not|[Nn]ever|must not'
sed -n 1,422p config/prompts/librarian.md | rg -o "$P" | wc -l    # 본문: 46
sed -n 423,651p config/prompts/librarian.md | rg -o "$P" | wc -l  # 슬롯: 23
sed -n 143,208p config/prompts/librarian.md | rg -o "$P" | wc -l  # 유지·삭제·교정: 12
```

## 결과

원문은 [`outputs.txt`](outputs.txt)다. 아래 표는 그 값을 옮겼다.

### 남는 기억 (`memory_state.py`)

후보가 "더한다"는 것은 판정이 incorporated이고 그 claim이 답이 새로 더한 claim이라는 뜻이다.

| 후보 종류 | 남는 기억이 맞는 조건 |
| --- | --- |
| 새 사실 (`new`) | 더한다 |
| 교정 (`corrects`) | 더하고, 교정 대상이 기억에서 빠진다 (`dropped` 또는 `absorbs`) |
| 바꿔 말하기 (`restates`) | 더하지 않고 원래 fact가 남는다. 또는 후보가 가리킨 최종 claim이 원래 fact를 흡수한다 |
| 일시 상태 (`transient`) | 더하지 않는다 |

판정 단어는 G3가 지금 채점하는 방식이다. 판정이 라벨과 같고 `eval_admission.claim_matches`가 맞아야 한다.

리뷰에서 원래 fact를 지우고 무관한 fact를 가리키는 유효 답을 반례로 확인해, 원래 fact가 남는지도 검사하도록 보완했다.
`already_represented`가 새 claim을 가리키고 그 claim이 원래 fact를 흡수한 답은 남는 기억이 맞으므로 계속 인정한다.
같은 고정 하네스와 저장된 답으로 보완 전후를 다시 셌으며, `memory_state.py`의 세 출력은 `outputs.txt`의 해당 줄과도 모두 같았다. 모델은 부르지 않았다.

| 답 | 유효 | 판정 단어 | 남는 기억 |
| --- | --- | --- | --- |
| 기본, 고정 E-synth | 109/119 | 0.838 | 0.909 |
| 교사, 학습 split 시도 | 1,013/1,176 | 0.750 | 0.901 |

| 후보 종류 | 기본 n | 판정 단어 | 남는 기억 | 남는 기억이 틀림 | 교사 n | 판정 단어 | 남는 기억 | 남는 기억이 틀림 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 새 사실 | 46 | 0.826 | 0.826 | 8 | 663 | 0.813 | 0.813 | 124 |
| 교정 | 28 | 0.714 | 0.821 | 5 | 193 | 0.611 | 0.902 | 19 |
| 바꿔 말하기 | 34 | 0.941 | 0.971 | 1 | 183 | 0.792 | 1.000 | 0 |
| 일시 상태 | 46 | 0.848 | 1.000 | 0 | 508 | 0.707 | 0.980 | 10 |

| 유효 답의 심은 낡은 fact | 지움 | 흡수 | 남김 |
| --- | --- | --- | --- |
| 기본 (101개) | 20 | 1 | 80 |
| 교사 (1,081개) | 626 | 1 | 454 |

- 흡수: 기본은 유효 답 109개 중 18개가 fact 30개를 흡수했다. 심은 낡은 fact 1, 교정 대상 3, 나머지 26이다.
- 교사는 유효 답 1,013개 중 430개가 fact 1,049개를 흡수했다. 심은 낡은 fact 1, 교정 대상 56, 나머지 992다.
- 교사 필터가 남긴 답 185개에는 흡수가 없다.
- 바꿔 말하기 후보에 claim을 더한 답: 기본 1개는 원래 fact를 흡수하지 않았다. 교사 37개는 모두 흡수했다.

### 종류별 판정 (`confusion.py`)

| 후보 종류 | 기본이 고른 판정 | 교사가 고른 판정 |
| --- | --- | --- |
| 새 사실 | incorporated 38, already_represented 8 | incorporated 539, already_represented 124 |
| 교정 | incorporated 20, incorporated(다른 claim) 5, already_represented 3 | incorporated 118, incorporated(다른 claim) 66, already_represented 8, deferred 1 |
| 바꿔 말하기 | already_represented 32, already_represented(다른 claim) 1, incorporated 1 | already_represented 145, already_represented(다른 claim) 1, incorporated 37 |
| 일시 상태 | not_durable 39, already_represented 7 | not_durable 359, already_represented 135, incorporated 10, deferred 4 |

"다른 claim"은 판정은 라벨과 같지만 `claim_matches`가 틀린 경우다.
일시 상태를 already_represented로 답한 답이 가리킨 claim은 기본 7개 모두 다른 현재 fact다.
교사는 134개가 다른 현재 fact, 1개가 그 답이 더한 claim이다. 심은 낡은 fact를 가리킨 답은 없다.

교정 후보에서 교정 대상이 어떻게 됐는지는 `memory_state.py`의 `corrects`에 있다.
기본은 claim을 더하고 대상을 지운 것이 20, 흡수한 것이 3, 남긴 것이 2다. 3개는 아무것도 더하지 않고 대상을 남겼다(already_represented).
교사는 지운 것 118, 흡수한 것 56, 남긴 것 10이다. 9개는 아무것도 더하지 않고 대상을 남겼다(already_represented 8, deferred 1).

### 계약이 허락하는 낡은 상태 지우기 (`reachable_recall.py`)

MASC는 incorporated나 already_represented 후보가 지지할 때만 기억 변경을 받는다.
라벨 후보가 전부 not_durable인 요청에서는 라벨대로 답하면 기억을 바꿀 수 없다.

| 세트 | 요청 | 심은 낡은 fact | 지울 수 있는 fact | 라벨대로 답할 때 최고 재현율 | 심은 fact가 있는 요청: 지지 후보 있음 / 없음 |
| --- | --- | --- | --- | --- | --- |
| 고정 E-synth | 119 | 112 | 85 | 0.759 | 60 / 17 |
| 학습 split | 404 | 402 | 311 | 0.774 | 239 / 61 |

| 기본 모델, 심은 fact가 있는 E-synth 요청 | 유효하지 않음 | 하나 이상 지움 | 모두 남김 | 유효 답의 fact: 지움 / 흡수 / 남김 |
| --- | --- | --- | --- | --- |
| 지지 후보 있음 (60) | 5 | 10 | 45 | 16 / 1 / 62 |
| 지지 후보 없음 (17) | 3 | 2 | 12 | 4 / 0 / 18 |

지지 후보가 없는 요청에서 지운 4개는 일시 상태 후보를 지지할 수 있는 판정으로 잘못 답했기 때문에 받아들여졌다.

### 기억 크기 (`net_growth.py`)

더한 claim은 답마다 서로 다른 claim 수, 뺀 fact는 `dropped`나 `absorbs`로 빠진 서로 다른 ID 수다.

| 답 | 답 수 | 더한 claim | 뺀 fact | 답 하나의 순증가 |
| --- | --- | --- | --- | --- |
| E-real 라이브 | 99 | 103 | 47 | +0.57 |
| E-real 기본 모델 (유효 답) | 95 | 85 | 27 | +0.61 |
| 같은 95건의 라이브 | 95 | 99 | 44 | +0.58 |
| 고정 E-synth 라벨 | 119 | 79 | 140 | −0.51 |
| 고정 E-synth 기본 모델 (유효 답) | 109 | 64 | 70 | −0.06 |

- 라이브 답 99개 중 30개가 fact 36개를 흡수했고, 지운 fact는 11개다.
- 라이브 답 99개 중 11개는 지지할 수 있는 판정이 하나도 없다. 그래서 기억이 그대로였다. 기억을 바꾼 라이브 답은 82개다.
- 기본 모델은 E-real 유효 답 95개 중 12개가 fact 15개를 흡수했고 12개를 지웠다.
- 라이브가 남긴 fact를 기본 모델이 지운 것은 1개, 흡수한 것은 7개다.
- E-synth 라벨의 뺀 fact 140개에는 지지 후보가 없어 뺄 수 없는 27개가 들어 있다.

### effort (`effort_compare.py`)

| 답 | 수 | 유효 | 정확도 | 유효 답만의 정확도 | 낡은 상태 재현율 | 지우기 정밀도 | completion 토큰 p50 | 시간 p50 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 교사 `high`, 학습 split 시도 | 1,176 | 0.861 | 0.642 | 0.750 | 0.496 | 0.989 | 11,910.5 | 57.285초 |
| 기본 `low`, 라벨 감사 전 E-synth | 144 | 0.924 | 0.689 | 0.751 | 0.188 | 0.980 | 2,298.5 | 11.095초 |

교사 답 163개가 유효하지 않았다. 81개는 `finish_reason`이 `length`였고 82개는 `stop`이었다.
`stop` 82개에서 검사기의 첫 문제는 `new_claim_without_support` 41, `memory_claim_absent` 28, `changes_without_support` 6, `missing_required_key` 5, `invalid_json` 2다.

### 교사 필터 (`confusion.py`)

| 값 | 학습 split 404 | 필터가 남긴 185 |
| --- | --- | --- |
| 요청당 심은 낡은 fact | 1.0 | 0.82 |
| 심은 fact가 있는 요청 | 0.74 | 0.63 |
| 심은 fact가 있는데 지지 후보가 없는 요청 | 0.15 | 0.00 |
| 후보 중 새 사실 | 0.39 | 0.28 |
| 후보 중 교정 | 0.12 | 0.14 |
| 후보 중 바꿔 말하기 | 0.17 | 0.27 |
| 후보 중 일시 상태 | 0.32 | 0.31 |

## 파일

| 파일 | sha256 | 설명 |
| --- | --- | --- |
| `stored.py` | `acc5ccdc…` | 다섯 스크립트가 같이 쓰는 run 경로, 라벨 읽기, 후보 종류 정의 |
| `memory_state.py` | `88d29a58…` | 남는 기억 채점, 흡수, 심은 낡은 fact, 교정 대상 |
| `confusion.py` | `4533bda9…` | 종류별 판정, 일시 상태가 가리킨 claim, 교사 필터 |
| `effort_compare.py` | `72abf0de…` | effort 비교와 교사 답이 유효하지 않은 이유 |
| `reachable_recall.py` | `3ccd2769…` | 계약이 허락하는 최고 재현율 |
| `net_growth.py` | `313035ce…` | 기억 크기와 라이브 흡수 |
| `outputs.txt` | `63181b57…` | 위 명령의 출력 19줄 |

다섯 스크립트는 `ruff check`를 통과하고, 하네스를 import 경로에 둔 `pyright` strict에서 오류가 없다.

## 확인하지 않은 것

- 학습 split의 라벨 잡음. 블라인드 라벨 감사는 E-synth 144건에만 했다. 학습 split 404건은 감사하지 않았다.
- 같은 세트에서 두 effort를 견주지 않았다. 교사는 학습 split, 기본 모델은 감사 전 E-synth 144건이다.
- 흡수 게이트. 하네스는 Jev 흡수 게이트를 돌리지 않는다. 교정 대상을 흡수한 답(기본 3, 교사 56)과 라벨 밖 흡수를 남는 기억에서 그대로 받았다. 라이브에서는 게이트가 그 흡수를 거절할 수 있다.
- Claude 판정자와 Jev가 합침을 같게 보는지.
- durable·continuity·cleanup 패스. 모든 수치가 admission 답이다.
- 일시 상태를 already_represented로 답한 142개가 정말 이미 있는 지식인지. 사람이 보지 않았다.
- 금지 명령형 수는 표현 패턴으로 센 대리 값이다. 평서문으로 쓴 규칙은 빠지고, 설명 속 표현도 들어간다.
- 참고 글 두 편의 숫자. Google 글은 관측 자료의 회귀 결과다. Anthropic 글의 실험은 Claude 모델만 썼다.
