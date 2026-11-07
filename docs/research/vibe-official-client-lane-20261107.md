# Vibe Code official-client lane — research (2026-11-07)

근거 출처: docs.mistral.ai 의 markdown 페이지(llms.txt 경유, 2026-11-07 fetch)와
~/me 계정 콘솔(Pro 플랜)이 보여준 할당량 화면. 이 문서는 조사이지 결정이 아니다.
RFC 는 `docs/rfc/RFC-vibe-official-client-lane.md` 로 간다.

## 1. 왜 별개 lane 인가 — 계량이 면별로 갈린다

- Pro 플랜 콘솔은 포함 할당량을 두 개의 막대로 보여준다: "포함된 API 사용량"
  US$30/월, "포함된 Vibe Code 사용량" US$300/월(둘 다 매월 1일 00:00 UTC 초기화).
- Admin usage API(`api.mistral.ai/v1/admin/usage`, Enterprise 전용)는 소비를
  항목별로 나누고 `vibe_usage` 가 `completion` 과 별개 항목이다
  (admin/admin-api/usage-metrics.md). 즉 두 pool 은 표면별로 따로 잰다.
- 반대 문구 하나: api-keys-profiles.md 의 "Plan and billing notes" 는 "plans
  include monthly usage that is shared across Studio, the API, and Vibe Code"
  라고 쓴다. 콘솔의 두 막대와 admin 항목 분리가 이 문장에 우선한다고 읽는다
  (근거: per-surface meter). 이 긴장은 RFC 에 명시한다.
- API 키 경로(`api.mistral.ai/v1` + `MISTRAL_API_KEY`)는 현재 mistral 레인이
  쓰는 길이고 $30 pool 에서만 논다. $300 pool 은 Vibe 제품 트래픽에 묶여 있다.

## 2. Vibe Code 의 인증 — 두 갈래

- **브라우저 계정 로그인(기본)**: "The flow provisions and stores credentials
  for you, so no API key is needed" (api-keys-profiles.md). CLI 가 계정 세션
  자격 증명을 로컬에 저장해 쓴다. 저장 위치·수명·갱신 절차는 문서에 없다 —
  미확인 사실로 남긴다(구현 시 `vibe /whoami`·파일 관찰로 실측).
- **API 키(선택)**: 같은 키가 Free/유료 플랜/PAYG 에서 동작. 이 경로는
  La Plateforme API 와 같은 계량을 쓴다.
- 제3자 도구가 구독 pool 에 닿는 공개 엔드포인트는 문서에 없다
  (GLM/Kimi 식 coding endpoint 없음).

## 3. lane 종류의 갈림길 — headless 가 없다

masc 의 세 official-client lane 패턴과 대조했다:

| lane | 진입 | 무인 호출 |
| --- | --- | --- |
| claude_code (lib/runtime/runtime_claude_code.ml, 3324줄) | 공식 CLI 래핑 | 1-shot 인자 조립(reasoning/system prompt 인자) |
| antigravity (lib/runtime/runtime_antigravity*.ml 9개 모듈) | OAuth 자격 증명 + 프로토콜 | setup/usage/context 모듈 분리 |
| codex | 공식 CLI 래핑 | 1-shot |

- Vibe CLI 는 문서상 **대화형 우선**이다: `vibe` 로 세션을 열고 slash 명령으로
  조종한다(`/branch`, `/clear`, `/compact`, `/context` …). `--resume <id>` 는
  있다. `--print`/headless/CI 모드에 대한 문서가 전체 문서 훑기에서 없다.
- 이것이 lane 가능성의 갈림길이다: (a) headless 가 실제로 있으면(문서 누락)
  claude_code 패턴 그대로 래핑, (b) 없으면 Vibe lane 은 막히고 대안은
  Vibe Code Web(브라우저+GitHub App 컨트롤 플레인, 공개 REST 없음) 이거나
  Mistral 이 headless 를 내줄 때까지 보류.
- 확인 방법(구현 전 단서): CLI 설치 후 `vibe --help` 전수 촬영. 이 문서
  작성 시점엔 미실측이다.

## 4. 모델·thinking 계약

- config.toml 의 `thinking` 값: `off, low, medium, high, xhigh, max` 또는
  provider 고유 수준(configuration-reference.md). masc 의
  Reasoning_effort 어휘(none/low/medium/high/xhigh/max/ultra)와 거의 겹치되
  끄는 값 이름이 `off` 다(none 아님). 매핑은 RFC 에서 정한다.
- CLI 는 provider 무관(임의 OpenAI-compatible + Anthropic 지원)이고
  Mistral 기본 provider 의 모델 목록은 CLI 내장 목록이다("the model's known
  levels"). mistral-large-4 의 chunk-list content/thinking 계약은 우리가
  실측·반영 완료(#49350, #49554) — lane 이 CLI 를 감싸면 content 해석은
  CLI 가 하므로 우리 wire 파서는 개입하지 않는다.

## 5. 실패 양상과 사용량

- 포함분 소진 시: PAYG off(기본)면 "Vibe Code can stop until the next
  billing period" — 한도 실패가 제품 차단으로 나타난다(api-keys-profiles.md).
  typed 처리는 이 차단 신호를 관찰해 분류해야 한다(실측 전 미확인).
- 사용량 뷰: Admin usage API 의 `vibe_usage` 항목이 근원이지만 Enterprise
  전용. Pro 계정에서는 콘솔 화면이 유일한 출원이라 operator 뷰에 자동
  반영은 불가능할 수 있다 — lane 자체 usage 관찰(turn 단위)로 대체한다.

## 6. 미확인 목록 (구현 전에 채운다)

1. headless/1-shot 호출 가능 여부(`vibe --help` 실측).
2. 브라우저 로그인 자격 증명의 저장 위치·수명·갱신·다계정 스택 가능성
   (#49200 C2a 계열과의 관계 — antigravity_oauth_credential 패턴 대비).
3. 한도 소진·세션 만료의 실제 오류 출력.
4. CLI 내장 모델 목록과 각 모델의 thinking 수준.
5. 콘솔 두 막대의 정확한 의미(사용량/잔여) — 화면만으로는 표기 방향이
   애매하다(첫 값이 사용량임은 Vibe US$0/US$300 으로 추정).
