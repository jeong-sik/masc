---
rfc: "librarian-absorb-gate"
title: "Keep the originals a merged claim does not convey"
status: Draft
created: 2026-09-21
updated: 2026-09-21
author: vincent
related: []
---

# 전하지 못한 원문은 흡수하지 않는다 — Librarian 흡수 관문

## 1. 문제

Librarian 은 현재 기억 여러 개를 claim 하나로 묶고(`new_claims[].absorbs`, RFC-0456 §4.2)
묶인 원문을 스냅숏에서 뺀다. 묶은 claim 이 원문의 내용을 다 담지 못하면 keeper 는 그
내용을 잃는다. 원문은 `memory-absorbed.jsonl` 에 남지만, keeper 가 보는 것은 스냅숏이다.

잰 값(이슈 #37079, 2026-09-19~20, 자세한 조건은 그 이슈의 덧붙임):

- 운영에서 묶은 claim 이 원문 문장을 전하는 비율(문장별 Jev `noul`, 양 끝 0.94/0.10 으로
  보정한 자): `glm-5.3-flash` 0.66, `deepseek-v4.1-flash` 0.53, `gemini-3-8-flash-high`(CLI) 0.13.
- 프롬프트에 "조건·수치·교훈을 빠뜨리지 말 것"을 넣은 뒤(#37124): 형식은 바로 바뀌었다(한 문장짜리
  묶음 85% → 11%). 내용이 얼마나 더 남았는지는 채점 중이다. 프롬프트로는 0.79 까지 갔고 그 이상은 못
  갔다(실험 D 갈래, 66쌍). 재료가 5개 이상이면 0.63.

프롬프트는 잃는 양을 줄이지만 0 으로 만들지 못한다. 잃은 것을 **묶기 전에** 알아내서, 잃는 원문은
스냅숏에 그대로 두는 장치가 필요하다.

## 2. 결정

Librarian 답을 받아들이기 전에, 묶이는 원문마다 **묶은 claim 이 그 원문의 각 문장을 전하는지** 판정
모델(TypeSafe Jev)에게 묻는다. 한 문장이라도 전하지 못한 원문은 `absorbed` 목록에서 뺀다. 그 원문은
현재 기억에 남고, 새 claim 도 그대로 들어간다. 나머지(다 전한 원문)는 전처럼 흡수된다.

한 바퀴:

1. `execute_exact_output_classified` 가 `selection` 을 돌려준다(`new_claims`, `absorbed : {absorbed; into}`, `facts`).
2. `absorbed` 를 `into` 별로 묶는다. `into` 의 claim 본문은 `new_claims` 에서, 원문 본문은 해당 회차가 읽은 입력 스냅숏의 `current.facts` 에서 id 로 찾는다. `selection.facts` 는 이미 흡수될 원문을 뺀 결과이므로 검사 재료로 쓰지 않는다.
3. 원문마다 문장으로 자른다(줄바꿈 → 문장 끝 `. ! ? 다.` `;` ` — `, 마크업 제거, 20자 미만 조각은 다음 조각에 붙임). 문장 경계는 #37079 의 채점기와 같고, 표집 없이 모든 문장을 검사한다. 요청은 64개 질문씩 나눈다.
4. `into` 하나당 Jev 요청 하나: `state` = 묶은 claim, `questions` = 그 `into` 에 묶이는 모든 원문의 모든 문장, 각각 `noul`
   "The claim under review conveys this statement, in any wording." + criteria(true: 읽는 이가 claim 만으로 그 문장을 알 수 있다 / false: claim 이 말하지 않거나 더 막연하게만 말한다).
   질문은 한 요청 안에서 병렬로 평가되므로 문장 수는 지연에 거의 영향이 없다(fan-out).
5. 문장의 `noul < 0.5` 이면 "전하지 못함". 원문 하나에 그런 문장이 하나라도 있으면 그 원문의 `absorbed` 항목을 뺀다.
   0.5 는 조정한 값이 아니라 yes/no 확률의 경계다. #37079 에서 목록 자와의 문장 단위 일치 88% 를 잰 경계도 이것이다.
6. 걸러진 `absorbed` 로 `apply_disposition` 을 부른다. 나머지 흐름(dropped, working_contexts, 이벤트)은 그대로.
7. 결과를 기록한다: keeper 로그 한 줄(흡수한 원문 수, 남긴 원문 수와 전하지 못한 문장 수, 판정 못 한 수, 요청 수). 흡수 행·스냅숏에
   새 필드는 넣지 않는다 — 판정은 증거이지 저장소의 진실이 아니다. keeper 결정 로그의 이벤트(숫자와 id 만)는 §6 의 첫 측정 뒤에
   필요하면 더한다.

Jev 를 못 부르면(키 없음, `MASC_TYPESAFEAI_ENABLED=false`, HTTP 4xx/5xx, 시간 초과, 응답 모양 오류) 관문은 **열린다**:
Librarian 답을 그대로 적용하고 로그에 이유를 남긴다. 지금과 같은 동작이다. 관문이 닫히는 방향의 실패는 없다 — 판정
모델이 죽어도 기억 정리는 멈추지 않는다.

## 3. 경계

| 부분 | 성질 | 어디 |
|---|---|---|
| 문장 자르기 | 결정론 | 코드. 같은 원문은 항상 같은 문장 목록 |
| "전하는가" 판정 | 비결정론(보정된 확률) | Jev. 코드는 값을 받기만 한다 |
| 0.5 경계, "한 문장이라도" 규칙, `absorbed` 거르기 | 결정론 | 코드 |
| 실패 시 열림 | 선언 | `Typesafeai_config`(`TYPESAFEAI_API_KEY`, `MASC_TYPESAFEAI_ENABLED`, `MASC_TYPESAFEAI_ENDPOINT`, `MASC_TYPESAFEAI_MODEL`) |
| 외부 연결 | `Typesafeai_client.evaluate`(`Masc_http_client` 풀, 공용 시간 상한) | 이미 main 에 있음(#36970) |

Jev 는 글을 만들지 않으므로 "왜 못 전했나"를 문장으로 내지 않는다. 대신 **어느 문장을 못 전했는지**가 답이다. 이
RFC 에서는 그 답으로 원문을 남긴다. 그 목록을 Librarian 에게 되돌려 한 번 다시 쓰게 하는 것(§7)은 다음 단계다.

## 4. 근거 — 공식 문서와 공개 사용례 (2026-09-21 확인, 자세한 출처는 근거 기록)

- API: `POST https://api.typesafe.ai/v1/systemone`, `model: "jev-latest"`(= `jev-1.13.0`), `state` + `questions`(noul/choice/score). 오류 401/422/429/529.
  요청당 64k 토큰, `state` 32k. 값 $0.042 / 1M 입력 토큰, 출력 무료. 한도 250,000 tok/s, 1,200 req/min.
- fan-out: "질문을 더해도 응답 시간은 거의 안 변한다", 필요한 질문을 한 요청에 다 넣고 코드가 고르라고 권한다.
- `noul` 에는 confidence 가 없다(choice/score 에만 있다). 그래서 이 관문은 확률 하나로 정한다.
- jev-1.13 의 알려진 약점: 글자 그대로 읽음(부정·범위어), 셈·날짜 비교 못 함, 여러 단계 추론 약함, 관련 없는 긴 state 에서 정확도 하락,
  state 안의 지시문에 흔들림, 영어 외 언어는 덜 정확. → 이 설계는 state 를 claim 하나로 좁히고, 문장 하나에 물음 하나, 셈은 코드가 한다.
  한국어 기억이 대부분이라 보정은 우리 말뭉치로 다시 했다(0.94/0.10).
- 공개 사용례: LangChain 은 에이전트 하네스 미들웨어로 Jev 를 써서 모델 라우팅과 도구 호출 위험 판정을 실행 전에 한다.
  Every 는 글 37편에 질문 21개를 한 번에 물어 777 판정을 0.7초·약 0.25센트에 받았고, 코드 검사 비교에서 결함 7개 중 6개를 잡았다(Fable 5.1 은 7/7, 25배 느림).
  Reddit r/singularity(09-16)에서는 에이전트의 "다음 단계 고르기"에 200~300ms 지연으로 쓴다는 보고와 MCP 커넥터, 텍스트 RPG 확률 판정 예가 나왔다.
  공통점: **생성은 LLM, 판정은 Jev, 결정은 코드**. 이 RFC 도 같은 자리다.
- OpenRouter: 09-18 부터 베타. `POST https://openrouter.ai/api/alpha/decisions`, 모델 `typesafe/jev-1.13`, 본문 모양 같음, 32k, 오류 봉투 `{"error":{...}}`.
  `MASC_TYPESAFEAI_ENDPOINT`·`MASC_TYPESAFEAI_MODEL` 과 OpenRouter 키로 예비 경로가 된다. 오류 해석은 확인 필요.

## 5. 비용과 지연

- 운영 규모(09-20 저녁): 흡수 시간당 28~77건, 원문 3~5개 묶음이 대부분. 원문의 모든 문장을 검사하므로 `into` 하나도 64개 질문마다 요청을 나눈다. 전체 문장을 검사하는 입력 토큰과 일일 비용은 다시 측정한다.
- 지연: 이 세션 실측 0.59초(질문 2개), Every 사례 777판정 0.7초. Librarian 회차(수십 초~분)에 1초를 더한다.
- 문장 자르기·거르기는 Librarian 회차 안 fiber 에서 돈다. 다른 keeper 는 안 기다린다(Board 관문과 같은 자리).

## 6. 검증

- 단위: 문장 자르기(파이썬 채점기와 같은 입력 → 같은 출력을 고정), `absorbed` 거르기(전부 전함/일부 못 전함/Jev 실패 시 열림/키 없음),
  `apply_disposition` 이 걸러진 목록을 받는 것. Jev 는 `?endpoint` 로 로컬 스텁에 붙인다(`test_typesafeai.ml` 방식).
- 하네스: `~/me/.tmp/jev-replay/absorption-20260919/` 의 66쌍 A/B 와 `llm_live.py`. 배포 뒤 같은 자로 "묶인 원문의 전해진 정도"를 다시 잰다.
  기대: 흡수된 원문만 보면 0.9 이상(전하지 못한 것은 흡수되지 않았으므로), 스냅숏에 남는 원문 수는 는다. 그 증가량이 이 관문의 값이다.
- 운영 신호: 로그의 "남긴 원문 수" 분포. 거의 0 이면 관문이 헛돌거나 프롬프트가 이미 충분한 것이고, 대부분이면 묶기 자체가 실패하는 슬롯이다(슬롯별로 본다).

## 7. 안 하는 것 (이번 RFC 범위 밖)

- 못 전한 문장 목록을 Librarian 에게 되돌려 한 번 다시 쓰게 하기. 회차당 LLM 호출이 하나 늘고 exact-output 흐름에 두 번째 메시지가
  필요하다. 관문의 효과를 §6 으로 잰 뒤 정한다.
- 흡수 행·스냅숏에 판정 결과 저장. 증거는 로그와 결정 로그로 충분하고, 저장소의 진실을 늘리지 않는다.
- Board 관문(`keeper_board_attention_exact_flow.ml`)의 켜기. 다른 결정이다. 다만 같은 키를 쓰므로 키가 들어가면 같이 켜진다 — `MASC_TYPESAFEAI_ENABLED` 로 따로 끌 수 있는지 구현에서 확인한다.
- 관문을 CLI 슬롯(`cli_slots`) 답에도 적용할지 — `selection` 은 같은 타입이므로 적용된다. 예외를 두지 않는다.

## 8. 리스크

- 데이터 반출: 묶은 claim 과 원문 문장이 TypeSafe 로 나간다. 지금도 같은 본문이 Librarian 슬롯 제공자(glm·openrouter)로 나간다.
  TypeSafe 는 "고객 요청으로 학습하지 않는다"고 적는다. 회사 Slack 을 담는 keeper(`kidsnote-slack-context-collector`)는 지금도 같은 경로를 탄다.
- 단일 벤더 베타, SLA 없음. 실패 시 열림으로 막는다. OpenRouter 가 예비 경로.
- 판정이 틀리면 두 방향: 전한 것을 "못 전함"으로 보면 원문이 남는다(중복, 손실 없음). 못 전한 것을 "전함"으로 보면 지금과 같다. 어느 쪽도 지금보다 나빠지지 않는다.
- 스냅숏 증가: 남는 원문만큼 스냅숏이 자란다. Librarian 은 다음 회차에 다시 묶으려 할 수 있다. 같은 claim 이 같은 원문을 또 못 전하면 또 남는다 — 무한은 아니고 회차마다 판정 하나다.
