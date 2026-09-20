# TypeSafe Jev 공개 사용례·공식 문서 근거 기록 (2026-09-21)

- 대상 RFC: [RFC-librarian-absorb-gate.md](../rfc/RFC-librarian-absorb-gate.md)
- 앞선 연구: [2026-09-18-typesafe-jev-masc-applicability-r1.md](2026-09-18-typesafe-jev-masc-applicability-r1.md)
- 확인일: 2026-09-21 (KST)

## 공통 헤더

- 날짜(ISO8601): 2026-09-21T01:05:00+09:00
- 작성자: MASC research session (개별 agent identity 는 기록하지 않음)
- 결정 ID: librarian-absorb-gate-r1
- 적용 대상: Librarian 흡수 관문(RFC-librarian-absorb-gate)
- 결정 상태: Draft

## 근거 (Evidence)

### 1. 공식 API 사실

- 항목: 엔드포인트·요청 모양·한도·값·오류
- 출처: https://docs.typesafe.ai/api.md, https://docs.typesafe.ai/models.md, https://docs.typesafe.ai/primitives/noul.md
- 확인일시: 2026-09-21T00:55:00+09:00
- 신뢰도: High (공식 문서 직접 열람)
- 델타: 09-18 기록 대비 새로 확인된 것 — 요청당 64k 토큰·`state` 32k, 한도 250,000 tok/s·1,200 req/min, 출력 토큰 무료, `noul` 답에는 confidence 가 없음.
- 내용:
  - `POST https://api.typesafe.ai/v1/systemone`, `Authorization: Bearer`, 본문 `model`("jev-latest" → `jev-1.13.0`), `state`(string|object|array), `questions`(id → {type, instructions, criteria}).
  - `noul.criteria` 는 `{true, false}` 정의(선택). `choice.criteria` 최대 255개, `score.criteria` 2~10단계.
  - 응답 `answers`(id → 답), `usage.input_tokens/output_tokens`, `model`.
  - 오류 401(키), 422(본문 검증), 429(한도), 529(과부하). 429/529 는 지수 백오프 권고.
  - 값 $42 / 1B 입력 토큰(= $0.042 / 1M), 출력 무료. 영어 최적화, 다른 언어는 "덜 정확".

### 2. 이 세션의 실호출

- 항목: 키 유효성과 지연
- 출처: 이 세션에서 `state` 한 문장·`noul` 두 개로 호출(기억 본문 아님)
- 확인일시: 2026-09-21T00:38:00+09:00
- 신뢰도: High
- 내용: HTTP 200, 0.59초, 응답 모델 `jev-1.13.0`, "화요일" 문장 noul 0.98 / "금요일" 문장 0.01, usage input 330 / output 38.

### 3. jev-1.13 의 알려진 약점

- 출처: https://docs.typesafe.ai/model-jaggedness/jev-1.13.md
- 확인일시: 2026-09-21T00:57:00+09:00
- 신뢰도: High
- 내용: 글자 그대로 읽음(범위어·부정·암묵 조건), 셈·카운트 불가, 숫자 표현 비교 불가, 날짜를 글자로 읽음, 여러 단계 추론 약함, 관련 없는 큰 state 에서 정확도 하락, state 안 지시문에 조종될 수 있음, 지시와 criteria 가 다르면 혼란, 부정 질문끼리 합이 1 이 아닐 수 있음, 생성 불가.
- 설계 반영: state 는 묶은 claim 하나, 질문은 문장 하나씩, 셈·경계·거르기는 코드.

### 4. fan-out 과 confidence

- 출처: https://docs.typesafe.ai/patterns/fan-out.md, https://docs.typesafe.ai/confidence.md
- 확인일시: 2026-09-21T00:58:00+09:00
- 신뢰도: High
- 내용: 질문은 병렬 평가라 "질문을 더해도 응답 시간에 거의 영향이 없다", 필요한 질문을 한 요청에 다 넣고 코드가 고르라고 권함. confidence 는 choice/score 만, noul 은 없음. 문턱은 "한 숫자가 아니라 행동의 결과에 따라 달리" 두라고 적음(예시 코드 0.5 / 0.9).

### 5. 공개 사용례

- 출처와 확인일시(모두 2026-09-21T00:50~01:00+09:00):
  - LangChain 블로그 "Building a harness with Jev": https://www.langchain.com/blog/building-a-harness-with-jev — 에이전트 미들웨어 두 개(모델 라우팅, 도구 호출 위험 판정으로 실행 전 차단). 세 질문 타입을 한 요청에 병렬. 수치는 마케팅 주장(200× 빠름·400× 저렴) 외 없음.
  - Every "Mini-Vibe Check": https://every.to/also-true-for-humans/mini-vibe-check-typesafe-s-jev-judged-everything-i-ve-written-in-0-7-seconds — 글 37편 × 질문 21개 = 777 판정을 0.7초 미만·약 0.25센트. 코드 검사 비교: 12개 구절에서 Jev 결함 6/7(중앙값 0.35초), Fable 5.1 은 7/7(8.83초, 고효율 모드). 저자는 "조기 경보로는 쓸 만하고 운영 전 정확도 검사가 더 필요"라고 적음.
  - Reddit r/singularity(2026-09-16): https://www.reddit.com/r/singularity/comments/1whop6b/ — 에이전트의 "다음 단계 고르기"에 200~300ms 로 쓴다는 사용자 보고, MCP 커넥터(github.com/itsmostafa/typesafe-mcp), 텍스트 RPG 성공 확률 판정 예. 회의적 반응("학습 없는 분류기", "베타 접근 못 함")도 있음.
  - TypeSafe 블로그: https://typesafe.ai/blog/introducing-system-one-models-and-jev
- 신뢰도: Medium (제3자 글·커뮤니티. 수치는 각 글의 자체 실험이며 재현 불가)
- 델타: "생성은 LLM, 판정은 Jev, 결정은 코드" 배치가 공통. 한 요청에 수십 질문을 묶는 fan-out 이 실제 사용의 기본형.

### 6. OpenRouter 경로

- 출처: WebSearch 결과(OpenRouter X 공지 2026-09-18, https://openrouter.ai/typesafe/jev-1.13 은 비로그인 fetch 404), 제3자 가이드 https://jevaiguide.com/channels/openrouter/ (2026-09-19 확인분)
- 확인일시: 2026-09-21T01:02:00+09:00
- 신뢰도: Medium (OpenRouter 공식 페이지를 직접 못 읽음. 이 Mac 에서 `GET /api/v1/models` 446개에 `jev`/`typesafe` 0건은 확인 — 결정 모델은 그 목록에 안 실림)
- 내용: `POST https://openrouter.ai/api/alpha/decisions`, 모델 `typesafe/jev-1.13`, 본문 모양은 TypeSafe 와 같음(`model`, `state`, `questions`), 응답에 `id`·`provider`·`usage.cost` 추가, 32k, $0.042/1M 입력, 오류 봉투 `{"error":{code,message}}`, 402(크레딧). 베타.
- 설계 반영: `MASC_TYPESAFEAI_ENDPOINT`·`MASC_TYPESAFEAI_MODEL` 로 예비 경로 가능. 오류 해석은 확인 필요(`{"detail"}` vs `{"error"}`).

### 7. 에이전트 스킬

- 출처: https://docs.typesafe.ai/agent-skill.md
- 확인일시: 2026-09-21T00:59:00+09:00
- 신뢰도: High
- 내용: `claude plugin marketplace add typesafe-ai/skills` → `claude plugin install typesafe@typesafe-ai`. 환경변수 이름은 `TYPESAFE_API_KEY`(masc 의 `TYPESAFEAI_API_KEY` 와 다름).

## 제한

- 공개 사용례의 수치는 그 글의 조건에서만 성립한다. 이 RFC 의 근거 수치는 #37079 의 우리 말뭉치 측정이다.
- OpenRouter 는 직접 호출하지 않았다.
