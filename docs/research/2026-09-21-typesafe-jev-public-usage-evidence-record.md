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
- 설계 반영: `[typesafeai] endpoint`·`model` 로 예비 경로 가능. 오류 해석은 확인 필요(`{"detail"}` vs `{"error"}`).

### 7. 에이전트 스킬

- 출처: https://docs.typesafe.ai/agent-skill.md
- 확인일시: 2026-09-21T00:59:00+09:00
- 신뢰도: High
- 내용: `claude plugin marketplace add typesafe-ai/skills` → `claude plugin install typesafe@typesafe-ai`. 환경변수 이름은 `TYPESAFE_API_KEY`(masc 의 `TYPESAFEAI_API_KEY` 와 다름).

### 8. 질문 모양 비교 (이 세션 실측)

- 항목: 원문 문장을 `instructions` 에 두는 모양 vs `state.statements[id]` 에 두고 지시문이 id 로 가리키는 모양의 양 끝
- 출처: `~/me/.tmp/jev-replay/absorption-20260919/jev_shape_ends.py`(로컬, #37079 의 12묶음 258문장; 요청당 문장 수 64/8/4/1)
- 확인일시: 2026-09-21T02:15:00+09:00
- 신뢰도: High (같은 자료·같은 자르기로 직접 측정)
- 내용: state 모양 바닥(원문 그대로) 0.30 / 0.38 / 0.53 / 0.71(요청당 64 / 8 / 4 / 1문장), 천장(무관한 claim) 0.02~0.03, 1문장은 245초. 지시문 모양은 바닥 0.94·천장 0.10(#37079).
- 델타: 지시문 고정 + state 데이터 분리는 이 판정에 못 쓴다. 주입 위험은 한계로 기록(RFC §8).

### 9. 마크업을 지우지 않는 자르기 (이 세션 실측)

- 항목: 채점기(#37079)가 지우던 백틱·`**` 를 그대로 둔 문장으로 같은 질문의 양 끝을 다시 잼
- 출처: `~/me/.tmp/jev-replay/absorption-20260919/jev_coverage.py ends` 를 두 자르기로 실행(로컬, 같은 12묶음 47원문 × 3상태)
- 확인일시: 2026-09-21T17:55:00+09:00
- 신뢰도: High
- 내용: 지운 자르기 바닥 0.94 / 자기 자신 0.95 / 천장 0.09(중앙값 0.08), 안 지운 자르기 0.94 / 0.95 / 0.09(중앙값 0.07). p10·p90 도 같음.
- 델타: 관문은 아무것도 지우지 않는다(코드 기억의 백틱·`**` 는 문법일 수 있다, Codex 리뷰). 보정값은 그대로 쓴다.

### 10. 경계 0.5 흔들기 (이 세션 재집계)

- 항목: `conveyed_boundary` 를 0.2~0.8 로 옮겼을 때 판정이 얼마나 움직이는가
- 출처: `~/me/.tmp/jev-replay/absorption-20260919/boundary_sweep.py` — #37079 의 채점 결과(`ab/coverage.jsonl` 의 Jev 문장 값, `ab/llm_missing.jsonl` 의 목록 자 판정)를 다시 센 것. 새 호출 없음. 통제군: 0.5 에서 88% 재현(production-1).
- 확인일시: 2026-09-21T18:20:00+09:00
- 신뢰도: High (같은 자료, 결정론적 재집계)
- 내용(production-1, 원문 84·문장 314):

  | 경계 | 문장 일치 | 원문 판정 일치 | 흡수되는 원문 | 0.5 대비 판정 바뀜 |
  |---|---|---|---|---|
  | 0.2 | 88% | 85% | 54% | 13/84 |
  | 0.3 | 89% | 87% | 51% | 11/84 |
  | 0.4 | 90% | 89% | 44% | 5/84 |
  | 0.5 | 88% | 88% | 38% | 0/84 |
  | 0.6 | 85% | 83% | 33% | 4/84 |
  | 0.7 | 82% | 76% | 19% | 16/84 |
  | 0.8 | 78% | 70% | 8% | 25/84 |

  목록 자 자체의 통과율 38%. Jev 문장 값 분포 p10 0.03·중앙 0.12·p75 0.61·p90 0.92, (0.3, 0.7) 안 16%. production-2(같은 원문을 목록 자로 두 번째 채점)는 같은 모양(0.5 에서 91%/89%).
- 델타: "어디에 그어도 같다"는 아니다. 일치는 0.3~0.5 에서 평평하지만 흡수 비율은 경계에 따라 단조로 움직인다. 0.5 를 두는 근거는 "가운데 + 일치 평지 위 + 독립 채점기와 같은 통과율"이고, 값을 옮기는 건 흡수/보존의 맞바꿈이라 RFC §7 2단계의 결정으로 둔다.

## 제한

- 공개 사용례의 수치는 그 글의 조건에서만 성립한다. 이 RFC 의 근거 수치는 #37079 의 우리 말뭉치 측정이다.
- OpenRouter 는 직접 호출하지 않았다.
