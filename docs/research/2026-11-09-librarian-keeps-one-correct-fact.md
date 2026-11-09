# librarian 이 지식마다 맞는 fact 하나를 남기는가 — 남는 기억으로 다시 잰 값, 운영 사실, 프롬프트 충돌

- 날짜: 2026-11-09
- 근거 묶음: [측정 기록](../evidence/research/2026-11-09-librarian-memory-state/README.md). 이 문서의 측정값은 모두 그 묶음의 스크립트가 출력한다.
- 이 조사를 근거로 쓰는 결정: [RFC-0517](../rfc/RFC-0517-the-librarian-keeps-one-correct-fact-per-piece-of-knowledge.md)
- 측정 대상: T 스택 #50181 head `365233db560b`에 저장된 답과 라벨이다. 모델은 다시 부르지 않았다.
- 운영 사실: main `57b928783c0b`의 코드와 2026-11-09에 읽은 라이브 `runtime.toml`이다. 인용한 파일은 main `c46646dba7dc`까지 바뀌지 않았다.

## 0. 요약

- 같은 기본 모델 답을 판정 단어 대신 답이 남긴 기억으로 채점하면 0.838이 0.909가 된다. 고정 E-synth의 유효 답 109개다.
- 남는 기억으로 봐도 틀린 곳이 넷 있다.
  - 새 지식을 잃었다: 46개 중 8개.
  - 교정 뒤에도 옛 fact가 남았다: 28개 중 5개.
  - 같은 지식이 두 fact로 남았다: 34개 중 1개.
  - 심은 낡은 상태를 지우지 않았다: 101개 중 80개.
- 고정 E-synth의 낡은 상태 라벨 112개 중 27개는 MASC 계약 안에서 맞힐 수 없다. 그 요청에는 기억 변경을 지지할 후보가 없다.
  라벨대로 답해도 재현율은 0.759가 끝이다. G3의 재현율 통과선은 0.9다.
- 라이브 admission은 답 하나마다 기억을 평균 0.57개 늘린다(E-real 99건). 그중 11건은 지지할 판정이 없어 기억을 바꿀 수 없었다.
- 흡수는 Jev 게이트가 확인한다(라이브는 켜져 있다). 지우기는 아무도 확인하지 않는다.
  기억이 어떻게 바뀌는지와 게이트가 무엇을 판정했는지는 로그로만 남는다.
- librarian.md는 같은 상황을 여러 곳에서 다르게 말한다. 바꿔 쓰기, 낡은 상태, 정리할지 둘지, 중복 없애기, 재발이 그렇다.
- effort `high` 교사는 유효 답의 정확도를 올리지 않았다(0.750, 기본 0.751, 세트는 다르다). completion 토큰과 시간은 p50 기준 약 5.2배다.

## 1. 왜 다시 쟀나

사용자가 2026-11-09에 방향을 정했다.
틀린 fact는 지우거나 흡수·병합해서 맞는 fact 하나만 남긴다. 문장은 정리해서 올바르게 남긴다.

지금 하네스의 G3는 후보마다 판정 단어(`incorporated` 등)가 라벨과 같은지 본다.
판정 단어가 달라도 남는 기억이 같으면 Keeper가 읽는 기억은 같다.
판정 단어가 맞아도 같은 지식이 둘 남으면 기억은 틀렸다.
그래서 저장된 답을 남는 기억으로 다시 셌다.

## 2. 무엇을 쟀나

### 2.1 답

| 답 | 모델과 effort | 세트 | 수 |
| --- | --- | --- | --- |
| 기본 | `Inkling-2-Small`, `low`(0.2) | 고정 E-synth 119 (블라인드 라벨 감사를 통과한 것) | 유효 109 |
| 교사 | 같은 기본 모델, `high`(0.9) | 학습 split 404 | HTTP 200 시도 1,176, 유효 1,013 |
| 라이브 | MASC가 커밋한 답 | E-real 99 | 99 |
| 기본 (E-real) | `Inkling-2-Small`, `low` | E-real 99 | 유효 95 |

effort 문자열은 Tinker OpenAI 호환 API가 숫자로 바꾼다. `low`는 0.2, `high`는 0.9이고, 생략하면 0.9다.
"유효"는 MASC의 검사가 답을 받아들였다는 뜻이다.

### 2.2 남는 기억 채점

후보가 "더한다"는 것은 판정이 `incorporated`이고, 그 claim이 답이 새로 더한 claim이라는 뜻이다.

| 후보 종류 (라벨) | 남는 기억이 맞는 조건 |
| --- | --- |
| 새 사실 | 더한다 |
| 교정 | 더하고, 교정 대상이 빠진다 (`dropped` 또는 `absorbs`) |
| 바꿔 말하기 | 더하지 않는다. 또는 더한 claim이 라벨이 가리킨 원래 fact를 흡수한다 |
| 일시 상태 | 더하지 않는다 |

심은 낡은 fact는 `dropped`로 빠져야 맞다. librarian.md 133-135행이 그렇게 말한다. 흡수로 빠진 것은 따로 센다.
판정 단어 점수는 지금 G3의 방식이다. 판정이 라벨과 같고, `claim_matches`가 맞아야 한다.

T 스택 #50325(Draft)가 이 채점을 하네스에 넣는다. 그 PR이 저장된 기본 답을 다시 센 값도 0.838과 0.909다.
#50325는 바꿔 말하기에 `already_represented`만 받고, 흡수로 빠진 낡은 fact를 안 지운 것으로 센다. 기본 답에서는 정확도가 같다.

## 3. 남는 기억으로 본 답

| 답 | 판정 단어 | 남는 기억 |
| --- | --- | --- |
| 기본, 고정 E-synth (유효 109) | 0.838 | 0.909 |
| 교사, 학습 split (유효 1,013) | 0.750 | 0.901 |

| 후보 종류 | 기본 n | 판정 단어 | 남는 기억 | 교사 n | 판정 단어 | 남는 기억 |
| --- | --- | --- | --- | --- | --- | --- |
| 새 사실 | 46 | 0.826 | 0.826 | 663 | 0.813 | 0.813 |
| 교정 | 28 | 0.714 | 0.821 | 193 | 0.611 | 0.902 |
| 바꿔 말하기 | 34 | 0.941 | 0.971 | 183 | 0.792 | 1.000 |
| 일시 상태 | 46 | 0.848 | 1.000 | 508 | 0.707 | 0.980 |

### 3.1 판정 단어만 틀린 답

남는 기억은 맞는데 G3가 틀렸다고 본 답이다.

- 일시 상태를 `already_represented`로 답했다. 기본 46개 중 7개, 교사 508개 중 135개다. 교사 4개는 `deferred`로 답했다.
  - 아무것도 더하지 않으니 기억은 그대로다.
  - 답이 가리킨 claim은 이미 있는 다른 현재 fact였다. 교사 1개만 그 답이 더한 claim을 가리켰다.
  - 심은 낡은 fact를 가리킨 답은 없다.
- 교정 대상을 흡수로 뺐다. 기본 3개, 교사 56개다.
  - G3는 교정을 `supersedes`와 `dropped`로만 맞다고 본다. 남는 기억은 같다.
  - 라이브에서는 흡수 게이트가 이 흡수를 따로 판정한다. 하네스는 게이트를 돌리지 않는다.
- 바꿔 말하기를 `incorporated`로 답하고, 새 claim이 원래 fact를 흡수했다. 교사 37개다. 기본은 없다.
- 바꿔 말하기를 `already_represented`로 답했지만 라벨과 다른 fact를 가리켰다. 기본·교사 1개씩이다.

### 3.2 남는 기억도 틀린 답

- 새 지식을 잃었다. 기본 8/46, 교사 124/663이다. 모두 `already_represented`로 답해 claim을 더하지 않았다.
- 교정 뒤 옛 fact가 남았다. 기본 5/28이다.
  - 3개는 교정을 `already_represented`로 답했다. 새 사실도 잃었다.
  - 2개는 새 claim을 더했지만 옛 fact를 지우지 않았다.
  - 교사는 19/193이다. 10개는 새 claim을 더했지만 대상을 남겼고, 9개는 아무것도 더하지 않았다.
- 같은 지식이 두 fact로 남았다. 기본 1/34다.
  - 바꿔 말하기 후보에 claim을 더하면서 다른 fact 둘을 흡수했다. 라벨이 가리킨 원래 fact는 남겼다.
  - #50325가 같은 후보를 따로 찾았다.
- 일시 상태를 기억에 더했다. 교사 10/508이다.
- 심은 낡은 상태를 남겼다. 기본은 101개 중 80개, 교사는 1,081개 중 454개다. 가장 큰 오류다.

## 4. 낡은 상태 — 계약이 막는 몫

MASC는 기억 변경에 지지를 요구한다(`lib/keeper/keeper_memory_admission_judgment.ml:109-130`).
지지는 `incorporated`나 `already_represented` 후보만 할 수 있다.
후보가 전부 `not_durable`이면 기억을 바꾸는 답은 받아들여지지 않는다.

| 세트 | 심은 낡은 fact | 지지 후보가 있는 요청의 fact | 라벨대로 답할 때 최고 재현율 | 심은 fact가 있는 요청: 지지 있음 / 없음 |
| --- | --- | --- | --- | --- |
| 고정 E-synth | 112 | 85 | 0.759 | 60 / 17 |
| 학습 split | 402 | 311 | 0.774 | 239 / 61 |

- 고정한 G3 재현율 0.9는 완벽한 답으로도 닿을 수 없다. 이 선은 모델이 아니라 라벨 생성기를 잰다.
- 기본 모델은 지지 후보가 있는 요청의 fact 79개 중 16개를 지우고 1개를 흡수했다. 62개는 남겼다.
- 지지 후보가 없는 요청에서도 4개를 지웠다. 일시 상태 후보를 지지할 수 있는 판정으로 잘못 답했기 때문에 받아들여졌다.
- 라이브 답 99개 중 11개는 지지할 수 있는 판정이 하나도 없다. 그 admission은 기억을 정리할 수 없었다.

admission이 아닌 정리 패스는 카테고리 한도를 넘을 때만 돈다(§7).
그래서 후보와 무관한 낡은 상태는 지지 후보가 오거나 한도를 넘을 때까지 남는다.

## 5. 흡수와 기억 크기

| 답 | 답 수 | 더한 claim | 뺀 fact | 답 하나의 순증가 |
| --- | --- | --- | --- | --- |
| E-real 라이브 | 99 | 103 | 47 | +0.57 |
| E-real 기본 모델 (유효) | 95 | 85 | 27 | +0.61 |
| 같은 95건의 라이브 | 95 | 99 | 44 | +0.58 |
| 고정 E-synth 라벨 | 119 | 79 | 140 | −0.51 |
| 고정 E-synth 기본 모델 (유효) | 109 | 64 | 70 | −0.06 |

- 라이브는 admission 한 번에 기억을 늘린다. 뺀 47개 중 36개는 흡수, 11개는 지우기다. 흡수를 쓴 답은 99개 중 30개다.
- 같은 95건에서 기본 모델은 27개를 뺐다. 라이브는 44개를 뺐다.
- 라이브가 남긴 fact를 기본 모델이 흡수한 것은 7개, 지운 것은 1개다. 사람이 볼 목록이고 통과선이 아니다.
- E-synth 라벨은 기억을 줄이라고 한다(−0.51). 그 140개에는 계약상 뺄 수 없는 27개가 들어 있다.
- 교사의 유효 답 1,013개 중 430개(42%)가 흡수를 썼다. 흡수한 1,049개 중 992개는 낡은 fact도 교정 대상도 아니다.
  head `365233db560b`의 라벨에는 흡수를 바라는 종류가 없다. #50290이 COMPLEMENT 후보와 중복 쌍을 더한다.
- 교사 필터는 흡수가 하나라도 있으면 답을 버린다(`teacher_sample.py:57-58`, head `365233db560b`). 그래서 학습용으로 남긴 185개에 흡수가 없다.
  이 데이터로 학습하면 모델은 흡수 없는 답만 본다. 라이브는 답의 30%가 흡수를 쓴다.

## 6. 교사 답과 effort

| 답 | 유효 | 정확도 | 유효 답만 | 낡은 상태 재현율 | 지우기 정밀도 | completion 토큰 p50 | 시간 p50 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 교사 `high`, 학습 split 1,176 | 0.861 | 0.642 | 0.750 | 0.496 | 0.989 | 11,910.5 | 57.285초 |
| 기본 `low`, 감사 전 E-synth 144 | 0.924 | 0.689 | 0.751 | 0.188 | 0.980 | 2,298.5 | 11.095초 |

정확도는 G3처럼 판정 단어로 센다. 정확도와 재현율은 유효하지 않은 답도 분모에 넣는다. 지우기 정밀도는 유효 답의 지우기만 본다.

- effort `high`는 유효 답의 정확도를 올리지 않았다. 토큰과 시간은 p50 기준 약 5.2배다.
- 낡은 상태 재현율은 교사가 높다. 세트가 다르니 effort만의 효과라고 말할 수 없다.
- 유효하지 않은 교사 답 163개 중 81개는 출력 한도(32,768)에서 잘렸다.
  끝까지 쓴 82개에서 검사기의 첫 문제는 지지 없는 새 claim 41, 기억에 없는 `memory_claim` 28이다. 그 밖에 지지 없는 변경 6, 빠진 키 5, JSON 오류 2다.

교사 필터는 학습 데이터를 한쪽으로 고른다.

| 값 | 학습 split 404 | 필터가 남긴 185 |
| --- | --- | --- |
| 요청당 심은 낡은 fact | 1.0 | 0.82 |
| 심은 fact가 있는 요청 | 0.74 | 0.63 |
| 심은 fact가 있는데 지지 후보가 없는 요청 | 0.15 | 0.00 |
| 후보 중 새 사실 / 교정 / 바꿔 말하기 / 일시 상태 | 0.39 / 0.12 / 0.17 / 0.32 | 0.28 / 0.14 / 0.27 / 0.31 |

필터는 심은 낡은 fact가 모두 지워진 답만 남긴다(`teacher_sample.py:55-56`).
지지 후보가 없는 요청에서는 라벨대로 답한 답이 이 조건을 넘을 수 없다. 그래서 그 요청이 학습 데이터에서 빠진다.

## 7. 운영 사실

main `57b928783c0b` 기준이다. 라이브 설정은 2026-11-09에 읽기만 했다.

| 사실 | 위치 |
| --- | --- |
| 패스 순서는 explicit admission → durable → continuity → working context → cleanup이다 | `lib/keeper/keeper_librarian_queue_refresh.ml:914-940`, `:992-999` |
| continuity·working context는 fact를 바꾸지 않는다(`Context_only`) | `lib/keeper/keeper_librarian_runtime.mli:65-73` |
| cleanup은 카테고리 수나 카테고리별 항목 수가 한도를 넘을 때만 돈다. 기본 한도는 30과 30이다 | `lib/keeper/keeper_memory_cleanup.ml:41`, `lib/keeper/keeper_memory_limits.ml:28-31`, `lib/config/env_config_keeper.ml:320-322` |
| 현재 facts의 커밋 한도는 기본 512 KiB다. Librarian은 이 기억 전체를 프롬프트로 읽는다 | `lib/config/env_config_keeper.ml:292` |
| 기억 변경은 `incorporated`·`already_represented` 후보의 지지가 있어야 받아들여진다 | `lib/keeper/keeper_memory_admission_judgment.ml:109-130` |
| 흡수 게이트의 기본값은 꺼짐이다. 라이브는 켜져 있다 | `lib/runtime/runtime_schema.ml:596`, 라이브 `runtime.toml`의 `[typesafeai] absorb_gate` |
| 흡수 게이트는 원문마다 forward 판정(mergeable·different_context·loses_knowledge·uncertain)을, 흡수 없는 새 claim마다 reverse 판정(copy·carries_new_statement·not_judged)을 낸다. 결과는 로그 한 줄씩이다 | `lib/keeper/keeper_librarian_absorb_gate.ml:200`, `:643-655`, `:1415-1445`, `:1605-1615` |
| 지우기는 조건 없이 통과한다. "Plain drops have no destination and remain unconditional" | `lib/keeper/keeper_memory_os_disposition_core.mli:27-28` |
| Keeper 턴은 기억 본문 없이 revision·fact 수·검색 안내만 받는다. `memory_recall`을 켠 Keeper는 고른 fact 본문도 받는다 | `lib/keeper/keeper_run_tools_hooks.ml:1151-1210`, `lib/keeper/keeper_memory_os_recall.ml:113-147` |
| 기억 건강 행은 fact 수, 바이트, 마지막 변경의 `added`·`removed` 수를 보인다. 패스별·종류별 수, 크기 추이, 게이트 판정 칸은 없다 | `lib/server/server_dashboard_http_keeper_memory_health.ml:410-428`, `:669-770` |
| Prometheus의 기억 지표는 실패, 레인, recall 수다. 기억 변경 수, 기억 크기, 게이트 판정 지표는 없다 | `lib/keeper_metrics/keeper_metrics.ml:275-367` |
| 커밋마다 journal 한 줄이 남는다. 변경과 지운 fact의 사유가 들어 있다. 어느 패스가 썼는지는 `Librarian` 하나로만 적힌다 | `lib/keeper/keeper_memory_os_current.mli:14-22`, `:245-253` |
| admission 프롬프트는 대화·도구·상대방·과거 Task·continuity 칸을 빈 값(`[no messages]`, `[]`, `null`)으로 그린다. E-real 99건이 모두 이 값으로 읽힌다 | T 스택 `admission_template.py`의 `ADMISSION_CONSTANTS` |

## 8. 프롬프트 안의 충돌

대상은 `config/prompts/librarian.md`다. sha256 `ec5cb66f…`, 651줄, 48,034바이트다.
본문(8-422행)은 admission·durable·cleanup이 같이 쓴다. admission은 그 뒤에 영어 `admission_policy`(586-617행)를 붙인다.

이 파일은 석 달 동안 여섯 배로 자랐다. 이 경로의 커밋은 50개다.

| 날짜 | 바이트 | 커밋 |
| --- | --- | --- |
| 2026-08-06 | 7,812 | #27032 (지금 경로의 첫 커밋) |
| 2026-09-02 | 16,329 | #32629 Board 출처 |
| 2026-10-07 | 26,904 | #41568 카테고리 한도 |
| 2026-10-08 | 37,793 | #41908 정리에 전체 검토 요구 |
| 2026-10-09 | 40,984 | #41910 흡수를 맥락 지식으로 판정 |
| 2026-11-01 | 47,360 | #46965 |
| 2026-11-03 | 48,034 | #47873 (지금) |

| 주제 | 행 | 무엇이 부딪히나 |
| --- | --- | --- |
| 바꿔 쓰기 | 60, 154-155, 192 | 60행은 같은 지식이면 기존 기억을 두고 중복을 `absorbs`로 흡수하라고 한다. 154-155행은 새 내용이 없으면 바꿔 쓴 문장을 더하지 말라고 한다. 192행은 표현을 고칠 때 `absorbs`로 원문을 연결하라고 한다. 같은 상황에 세 답이 있다 |
| 중복 없애는 법 | 60, 151, 162, 172-178, 179-181, 199-201 | 여섯 곳에서 따로 말한다. 172-178행은 남길 문장을 기호 하나 바꾸지 말고 복사해 자기 ID와 함께 `absorbs`에 적으라는 절차다 |
| 낡은 상태 | 62, 133-138, 191, 622 | 133-135행은 낡은 상태를 `dropped`로 지우고 `absorbs`로 없애지 말라고 한다. 136-138행은 "의미 있는 전이"를 한 기록이 설명하면 `absorbs`로 통합할 수 있다고 한다. 이 말은 정의가 없다. 622행(`absorb_forward`)은 나중의 해결이 앞의 미해결 관측을 이어받을 수 있다고 본다 |
| 정리할지 둘지 | 26-27, 68-69, 86-87, 130-132, 212 / 30, 78, 91-96, 340-341 | 앞쪽은 관련이 적다는 이유로 버리지 말고(26-27, 68-69에 같은 말이 두 번), 안전한 선택이 없거나 확실하지 않으면 두라고 한다. 뒤쪽은 여유가 있어도 낡은 상태를 정리하고, 새 증거가 없다는 이유로 빈 변경을 고르지 말라고 한다. 340-341행은 빈 배열을 "이번에 바꿀 것이 없다"는 정상 답으로 정의한다 |
| 정리와 지지 규칙 | 30, 91 / 611-615 | 본문은 한도에 여유가 있어도 낡은 상태를 정리하라고 하고(30행), 대화 기록이 비어도 현재 기억이 정리 대상이라고 한다(91행). `admission_policy`는 지지 후보 없는 변경을 막는다. 후보가 전부 일시 상태인 admission에서는 정리할 길이 없다 |
| 재발 | 53, 622 / 66-67, 152-153 | 같은 원인의 재발도 별도 발생으로 보존하라고 한다. 다른 곳은 같은 교훈을 새 PR 번호·날짜로 다시 관측했다고 새 기억이 필요하지 않다고 한다 |
| `already_represented` | 596, 608-610 | 596행은 남아 있는 claim이 이미 그 지식을 담을 때라고 한다. 608-610행은 새로 쓴 claim이든 남은 claim이든 최종 claim을 가리키라고 한다. 다시 쓴 claim을 가리킬 때 어느 판정인지 정해지지 않는다 |
| `first_seen` 정의 | 88, 119-120 | 같은 정의가 두 번 나온다 |
| 빈 입력 칸 | 343-359, 385-422 | admission은 이 칸을 빈 값으로 그린다. 그 칸을 읽는 법을 설명하는 3,618바이트도 같이 간다 |
| 슬롯 사이 반복 | 14-23 / 432-439 / 509-516, 378-383 / 488-491 / 554-556 | 역할 경계와 Goal 설명이 슬롯마다 조금씩 다른 말로 되풀이된다 |

금지 명령형(`마세요`, `지 말고`, `안 됩니다`, `Do not`, `never`, `must not`)은 본문에 46개, 슬롯에 23개다.
유지·삭제·교정 절(143-208행)에만 12개다. 세는 명령은 근거 묶음 README에 있다.

## 9. 참고 글 두 편

### 9.1 Anthropic, "The components of agent memory"

2026-11-06, Lance Martin. GeekNews [topic 36775](https://news.hada.io/topic?id=36775)가 이 글을 한국어로 요약했다.

| 절 | 내용 |
| --- | --- |
| Steering Claude to write memory | "For stronger models, giving them freedom to judge salience was more effective than setting fixed rules in advance". 고정 규칙은 성능을 떨어뜨릴 수 있다고 한다. "record only failures" 규칙을 주자 기억이 주던 이득이 Opus 5에서 0.234, Opus 4.7에서 0.150, Sonnet 4.6에서 0.020 줄었다(Figure 5 오른쪽) |
| 같은 절 | 약한 모델은 반대였다. Sonnet 4.6의 CL-Bench database 과제 점수는 기억 없이 0.330, 기억과 함께 0.364, 기억과 다듬은 지시로 0.641이다(Figure 5 왼쪽) |
| Dreaming can correct memory | Pokémon의 Mt. Moon에서 틀린 메모가 같은 실패를 되풀이하게 했다. "The transcript gave Claude a ground truth to validate its memory against." 세션 기록과 대조해 메모를 고치자 앞으로 나아갔다(Figure 6-8) |
| Dreaming can build new memory representations | Stainless 내부 파일 약 35만 개로 Opus 5 에이전트가 128세션 동안 위키를 쓰고 고쳤다. 지시에 "merge duplicates, and check claims against the sources"가 들어 있다. 세션을 2개에서 128개로 늘리자 질문 25개의 채점 기준 충족이 13%에서 48%로 올랐다 |
| 같은 절 | 다른 과제에서는 문서 10개(115 KB)로 만든 위키가 68쪽, 203 KB가 됐다. 원본의 1.77배다(Figure 12) |
| Dreaming can promote notes up the memory hierarchy | "Injected memories use up valuable tokens, and an incorrect note can be carried into every session." |
| Dreaming can focus memory on a specific goal | 에이전트 넷이 한 페이지에 쓰자 "one agent's save erases another's lines"였다. fact 57개 중 41개(72%)만 남았다. 계약마다 페이지를 나누자 57개가 모두 남았다(Figure 14) |
| Thinking backward, looking forward | "Memory can also drift and become irrelevant as the environment changes." |

한계: 실험 모델은 모두 Claude다. Pokémon 비교는 모델마다 한 번씩 돌렸다. CL-Bench는 과제 하나, Stainless 위키 평가는 말뭉치 하나와 질문 25개다.

### 9.2 Google, "Agent Distraction"

2026-11-06, Sam Saccone·Madhuri Garikapati. 수치는 모두 "The Cost" 절이다.

- 세션의 13%가 `TODO(bug/...)`·`FIXME(bug/...)` 참조를 만났다.
- 만난 경우의 94%는 무시했고 6%는 그 버그 ID로 뭔가를 했다. 그 행동의 83%는 사용자가 시키지 않은 일이었다.
- 시키지 않은 우회의 2/5 넘게가 이미 닫힌 티켓을 쫓았다. 고쳐진 버그 32%, 폐기된 버그 9%, 그 밖에 중복·제한 티켓 2%다.
- 아직 열린 버그였던 경우는 61%가 조회만 했고 39%가 코드를 고쳤다.
- 시키지 않은 우회가 있는 세션은 step 70%, 토큰 77%, 대기 시간 105%가 더 들었다(p<0.0001).
  개발자 단위 군집 표준오차를 쓴 다중 고정효과 회귀다.
- "What we did" 절: 낡은 참조를 지우는 도구가 6개월 동안 수천 건을 지웠다. 사람 리뷰어 수락률은 95%를 넘었다.

한계: 운영 기록의 관측 연구라 인과를 보여 주지 않는다. 한 조직의 버그 ID 참조만 쟀다. 낡은 참조를 지운 뒤 에이전트 성과가 어떻게 바뀌었는지는 재지 않았다.

### 9.3 MASC에 옮길 수 있는 것

- 고정 규칙을 더하기보다 목적을 판단하게 두는 편이 강한 모델에서 나았다. librarian.md의 금지문 69개와 맞물린다.
  다만 약한 모델은 자세한 지시로 좋아졌다. `Inkling-2-Small`이 어느 쪽인지는 모른다. 정리안을 두 모델(Inkling·GLM)로 재야 하는 이유다.
- 틀린 메모는 다음 판단으로 옮겨 간다. MASC에서 틀린 fact가 판단에 들어가는 길은 둘이다.
  Librarian은 기억 전체를 프롬프트로 읽는다. `memory_recall`을 켠 Keeper는 고른 fact 본문을 턴마다 받는다(§7).
- Anthropic의 에이전트는 중복을 합치고 원본과 대조했다. MASC에서 합치기는 흡수다. Jev 게이트가 합친 claim이 원래 fact의 지식을 잃지 않는지 본다.
  지우기는 아무것도 확인하지 않는다.
- 한 페이지에 여럿이 쓰면 fact가 덮어써져 사라졌다. MASC에서 확인 없이 사라지는 길은 지우기다.
- Google은 에이전트에게 무시하라고 하지 않고 낡은 참조를 원천에서 지웠다. 기억에서도 낡은 상태는 남겨 두고 피하게 하기보다 지우는 쪽이다.
- Google의 비용 수치는 다른 조직, 다른 종류의 낡은 맥락이다. 기억에 그대로 옮길 수 없다.

## 10. 불확실한 점

- 학습 split 404건의 라벨은 감사하지 않았다. 블라인드 라벨 감사는 E-synth 144건에만 했다.
- effort 비교는 세트가 다르다. 같은 세트에서 두 effort를 견주지 않았다.
- 하네스는 흡수 게이트를 돌리지 않는다. 교정 대상을 흡수한 답(기본 3, 교사 56)은 라이브에서 거절될 수 있다.
- Claude 판정자와 Jev가 합침을 같게 보는지 재지 않았다.
- 모든 수치가 admission 답이다. durable·cleanup 패스는 같은 프롬프트 본문을 쓰지만 재지 않았다.
- E-real의 라이브 답은 정답이 아니다. "라이브와 같다"는 "맞다"가 아니다.
- 일시 상태를 `already_represented`로 답한 142개가 정말 이미 있는 지식인지 사람이 보지 않았다. 라벨 잡음일 수 있다.
- 금지 명령형 수는 표현 패턴으로 센 대리 값이다. 평서문 규칙은 빠지고, 설명 속 같은 표현은 들어간다.
- COMPLEMENT 후보와 중복 쌍(#50290)은 이 수치에 없다. head `365233db560b`의 세트에는 그 종류가 없다.
- Anthropic 글은 Claude 모델만, Google 글은 한 조직의 관측 자료만 썼다.

## 11. 출처

| 출처 | 확인 | 신뢰도 |
| --- | --- | --- |
| [측정 기록](../evidence/research/2026-11-09-librarian-memory-state/README.md), T 스택 head `365233db560b` | 2026-11-09 02:53Z 실행 | High |
| main `57b928783c0b` 코드 (§7 위치), `c46646dba7dc`까지 그대로 | 2026-11-09 직접 읽음 | High |
| 라이브 `runtime.toml` `[typesafeai]` | 2026-11-09 읽음 | High (그 시각 기준) |
| `config/prompts/librarian.md` 행 번호와 `git log` 크기 | 2026-11-09 | High |
| T 스택 #50290·#50325 본문 | 2026-11-09 읽음 | Medium (열린 PR) |
| [The components of agent memory](https://www.anthropic.com/research/components-of-agent-memory) | 2026-11-09 원문 확인 | Medium (Claude 모델 실험) |
| [Agent Distraction](https://developers.googleblog.com/agent-distraction/) | 2026-11-09 원문 확인 | Medium (관측 연구) |
| [GeekNews topic 36775](https://news.hada.io/topic?id=36775) | 2026-11-09 | Low (요약) |
| [OpenAI API Compatible Inference](https://tinker-docs.thinkingmachines.ai/tinker/compatible-apis/openai/) (Tinker 문서, effort 대응) | 2026-11-09 | High |
