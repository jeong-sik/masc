# Vibe Code official-client lane — research (2026-11-07)

근거 출처: docs.mistral.ai 의 markdown 페이지(llms.txt 경유, 2026-11-07 fetch)와
~/me 계정 콘솔(Pro 플랜)이 보여준 할당량 화면. 이 문서는 조사이지 결정이 아니다.
RFC 는 `docs/rfc/RFC-vibe-official-client-lane.md` 로 간다.

## 1. 왜 별개 lane 후보인가 — 계량이 면별로 갈린다

- Pro 플랜 콘솔은 포함 할당량을 두 개의 막대로 보여준다: "포함된 API 사용량"
  US$30/월, "포함된 Vibe Code 사용량" US$300/월(둘 다 매월 1일 00:00 UTC 초기화).
- Admin usage API(`api.mistral.ai/v1/admin/usage`, Enterprise 전용)는 소비를
  항목별로 나누고 `vibe_usage` 가 `completion` 과 별개 항목이다
  (admin/admin-api/usage-metrics.md). 이는 두 사용량 항목을 표면별로 따로 잰다.
  다만 metric 이름과 카테고리 분리는 included monthly allowance 나 limit 분리를
  증명하지 않는다. 서로 다른 metric 은 shared limit 와 공존할 수 있다.
- 공유 한도 근거: 공식 Subscriptions(admin/billing-usage/subscriptions.md)는
  "Each Mistral plan includes monthly usage that is shared across Studio, the
  API, and Vibe Code" 라고 명시한다. api-keys-profiles.md 한 곳만의 예외 문구가
  아니며, 콘솔 두 막대가 이 공식 문장에 우선한다고 단정할 수 없다.
- API 키 경로(`api.mistral.ai/v1` + `MISTRAL_API_KEY`)는 현재 mistral 레인이
  쓰는 API 쪽 경로이지만 $30 pool 만 소비한다고 단정하지 않는다. Vibe 표면에
  별도 $300 한도가 있는지도 미확인이다. 콘솔 관찰은 별도 pool 가설의 단서로만
  남기고, lane 구현 전에 같은 계정에서 API-only 와 Vibe-only 호출의 두 콘솔
  소비 곡선을 비교해 공유 여부를 확인한다.

## 2. Vibe Code 의 인증 — 두 갈래

- **브라우저 계정 로그인**: "Browser-based sign-in is enabled by default
  when your config targets a model with a Mistral provider" — 조건절까지가
  원문이다(api-keys-profiles.md). "The flow provisions and stores credentials
  for you, so no API key is needed". CLI 가 계정 세션 자격 증명을 로컬에 저장해
  쓴다. 저장 위치·수명·갱신 절차는 문서에 없다 —
  미확인 사실로 남긴다(구현 시 `vibe /whoami`·파일 관찰로 실측).
- **API 키(선택)**: 같은 키가 Free/유료 플랜/PAYG 에서 동작. 이 경로는
  La Plateforme API 와 같은 계량을 쓴다.
- 제3자 도구가 구독 pool 에 닿는 공개 엔드포인트는 문서에 없다
  (GLM/Kimi 식 coding endpoint 없음).

## 3. 무인 호출 — programmatic mode 가 문서화돼 있다

masc 의 official-client lane 참조 패턴과 대조했다:

| lane | 진입 | 소유 계약 |
| --- | --- | --- |
| claude_code (lib/runtime/runtime_claude_code.ml) | 공식 CLI 래핑 | stream_event 코덱, MCP 도구 브리지, resume 세션 |
| antigravity (lib/runtime/runtime_antigravity*.ml) | OAuth 자격 증명 패밀리 — 자격 증명·프로토콜·사용량이 저마다 모듈로 갈라진다 | OAuth credential, protocol, setup, usage |
| codex | 공식 CLI 래핑 | 1-shot 인자 조립 |

Vibe CLI 는 **두 모드**로 문서화돼 있다(vibe/code/cli/work-with-cli.md,
2026-11-07 fetch): interactive 와 **programmatic**(scripting/CI 용). programmatic
표면:

- `--prompt`/`-p` 1-shot, `--prompt-file PATH`, stdin 파이프(`-p` 에 본문 없이).
- 실행 agent 는 `default_agent`(기본 `accept-edits`)를 따른다. programmatic 에서는
  승인이 필요한 tool call 에 응답할 사람이 없어 이를 거부한다. 반대로
  `--auto-approve`(별칭 `--yolo`)는 **모든 tool call** 을 승인한다.
- `--enabled-tools`/`--disabled-tools` 와 per-tool `permission = "always"`/
  allowlist 로 도구 범위를 조정한다. project config·skills·agent files 의 trust
  검사는 programmatic 에도 적용되고, 미신뢰 시 이들을 무시하고 경고한다.
  `--trust` 는 invocation 한정 신뢰다(agents.md, safety-approvals-permissions.md).
- `--max-turns N`, `--time-limit SECONDS`(이후 resume 가능), SIGTERM 동등.
- `--output text|json|streaming` — json 은 종료 시 세션 메시지 JSON 배열,
  streaming 은 메시지마다 JSON 객체 한 줄.
- `--output-dir DIR` — `export.json`(Vibe 버전, 유효 config, 토큰 사용량, 비용,
  stop reason, outcome, subagent별 상태·모델·사용량·비용) 과 세션 사본.
- exit code: 0 완료 / 1 시작 실패(플래그·config) / 2 모델 API·런타임 실패 /
  3 한도 도달·중단·거절로 완료 전 정지. 실측(2026-11-07 m10)에서는 도구 거절이
  exit 0 이었다(`docs/evidence/vibe-official-client-lane-20261107/`).
- 무인 재개: `-p` + `--continue` 또는 `--resume SESSION_ID`(부분 ID 지원).

**[정정] 이 문서 초판은 "headless 문서가 없다"고 적었다 — 틀렸다.** 초판 훑기가
llms.txt 색인을 `headless|continuous|github|ci|automation` 키워드로 걸었는데
해당 페이지의 색인 설명은 "day-to-day work"라 그물에 걸리지 않았다. 교훈:
색인 키워드 검색은 제품 영역의 페이지 목록 전수 열거를 대신하지 못한다.
리뷰(adv-vibe-rfc, 2026-11-07)가 잡아줬다.

## 4. 모델·thinking 계약

- config.toml 의 `thinking` 값: `off, low, medium, high, xhigh, max` 또는
  provider 고유 수준(configuration-reference.md). masc 의 Reasoning_effort
  어휘는 8개다(none/minimal/low/medium/high/xhigh/max/ultra,
  reasoning_effort.ml `all`). 겹치되 끄는 값 이름이 `off` 다(none 아님).
  주의: API wire 는 `none` 을 400(code 3051)로 거부한다는 실측이 있지만
  CLI/programmatic 표면이 `off`(또는 `none`)을 어떻게 받는지는 미실측이다.
- CLI 는 provider 무관(임의 OpenAI-compatible + Anthropic 지원)이고
  Mistral 기본 provider 의 모델 목록은 CLI 내장 목록이다("the model's known
  levels"). mistral-large-4 의 chunk-list content/thinking 계약은 우리가
  실측·반영 완료(#49350, #49554) — lane 이 CLI 를 감싸면 content 해석은
  CLI 가 하므로 우리 wire 파서는 개입하지 않는다.

## 5. 실패 양상과 사용량

- 포함분 소진 후: PAYG 가 켜져 있으면 prepaid credits 를 쓰고, 꺼져 있으면
  "usage can stop until the next billing period or until an admin changes the
  settings" 다(admin/billing-usage/subscriptions.md). "can stop" 이므로 항상
  차단된다고 단정하지 않고, 실제 차단 신호를 관찰해 typed 처리를 정한다(실측 전
  미확인).
- 사용량 뷰: Admin usage API 의 `vibe_usage` 항목이 근원이지만 Enterprise
  전용. Pro 계정에서는 콘솔 화면이 유일한 출원이라 operator 뷰에 자동
  반영은 불가능할 수 있다 — lane 자체 usage 관찰(turn 단위)로 대체한다.

## 6. 미확인 목록 (구현 전에 채운다)

2026-11-07 vibe 3.1.0 실측으로 일부를 채웠다.

- 일부만 채운 것:
  - 1: `export.json` 최상위 칸 목록과 출력 원소를 fixture 로 남겼다. 칸 단위
    스키마 문서는 아직 없다.
  - 2: 저장 위치(keychain 항목)만 봤다.
  - 3: env API 키 경로의 402 만 봤다.
  - 4: 모델 별칭 목록만 봤다.
  - 5: `ask` agent 의 거절 모양과 `--disabled-tools` 한 이름만 봤다.
  - 6: `-p "/whoami"` 한 형태만 해 봤고 쓸 수 없었다.
- 못 채운 것: 7. 콘솔 두 막대의 수치는 재지 않았다. 같은 시각의 API 402 와 Vibe
  성공이라는 대비 하나만 있다.

기록은 `docs/evidence/vibe-official-client-lane-20261107/` 에 있다. 해석은 RFC §4.1 에
있다.

1. programmatic 호출의 실측: `--output json`/`streaming` 프레임의 필드 수준
   스키마와 `export.json` 스키마는 문서가 개요만 적는다 — 우리 계정에서
   fixture 로 촬영해 문서화한다(코덱의 계약이 된다).
2. 브라우저 로그인 자격 증명의 저장 위치·수명·갱신·다계정 스택 가능성
   (#49200 C2a 계열과의 관계 — antigravity_oauth_credential 패턴 대비).
3. 한도 소진·세션 만료의 programmatic 표면 오류 양상(exit code 3 과 2의
   구분, 출력 프레임).
4. CLI 내장 모델 목록과 각 모델의 thinking 수준; `off`/`none` 수용 여부
   (API wire 의 none 거부 실측과 다를 수 있다).
5. 도구·trust 경계: MCP 브리지 채택 여부와 함께 `default_agent`,
   `--enabled-tools`, per-tool `permission`/allowlist, 미신뢰 project 경고,
   도구 거부의 출력·stop reason·exit code 를 첫 층에서 실측한다. 전체 도구를
   자동 승인하지 않고 필요한 최소 권한 조합을 정한다.
6. 준비 검사 형태: `vibe /whoami` 는 문서상 세션 내 slash 명령이다 — 무인
   argv 형태가 있는지 첫 층에서 확인한다.
7. 콘솔 두 막대의 의미와 pool 관계(사용량/잔여) — 화면만으로는 표기 방향이
   애매하다. 같은 계정의 baseline 을 기록하고 API-only 와 Vibe-only 호출 전후의
   두 수치를 반복 측정해 한쪽/양쪽 소비 곡선으로 shared/independent 여부를 lane
   구현 전에 확인한다(첫 값은 Vibe US$0/US$300 관찰의 사용량 추정에 그친다).
