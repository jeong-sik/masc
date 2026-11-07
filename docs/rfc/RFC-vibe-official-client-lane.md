---
rfc: "vibe-official-client-lane"
title: "Mistral Vibe 구독 pool 을 official-client lane 으로 쓴다"
status: Draft
created: 2026-11-07
updated: 2026-11-08
author: claude
supersedes: []
superseded_by: null
related: ["49352", "49200"]
---

# RFC: Vibe official-client lane (vibe-official-client-lane)

## 0. 요약

Mistral Pro 콘솔의 Vibe Code US$300/API US$30 표기는 별도 pool 가설의 단서이지
확정 근거가 아니다. 공식 Subscriptions 는 included monthly usage 가 Studio·API·
Vibe Code 에서 shared 라고 명시한다. lane 구현 전에 같은 계정의 API-only 와
Vibe-only 호출에 대한 콘솔 소비 곡선을 비교해 pool 관계를 확인한다. 이 RFC 는
그 실측을 Keeper 배정의 조건으로 두고(§2.1 착수 조건), Vibe 제품 표면을 감싸는
official-client lane 후보의 종류·자격 증명·계약·관측·실패 처리를 정한다.

## 1. 배경과 근거

- 계량 관찰과 shared 문서: admin usage API 가 `vibe_usage` 를 `completion` 과
  별도 항목으로 잡고 콘솔도 두 막대를 보여주지만, 이는 카테고리별 계량과 화면
  관찰에 그친다. 공식 Subscriptions(admin/billing-usage/subscriptions.md)는
  included monthly usage 가 Studio·API·Vibe Code 에서 shared 라고 명시하므로,
  metric 이름과 콘솔 막대만으로 included allowance 나 limit 분리를 확정하지 않는다.
- 인증 분리: Vibe CLI 는 브라우저 계정 로그인으로 자격 증명을 provisioning
  하며 API 키 없이 유료 플랜에서 동작한다(문서 근거). setup 경로는 기록하지
  않았지만 Vibe 는 keychain 자격 증명을 `chat` 플랜 키로 읽었다(§4.2, scope 는 Vibe
  소스의 표로 이끌어 낸 값이다). 제3자가 구독 pool 에 닿는 공개
  엔드포인트는 없다.
- 자세한 출처와 미확인 목록:
  `docs/research/vibe-official-client-lane-20261107.md` §1–§6.

## 2. 결정

### 2.1 lane 종류 — claude_code 패턴의 command transport 와 소유 코덱

- lane 종류는 **command transport**(공식 CLI 감싸기)다. 새 HTTP codec 을
  만들지 않는다. 단 "masc 는 프로세스 조종·관측만 한다"는 초판 문장은 옳지
  않았다: 참조 구현 claude_code lane 자체가 stream_event 코덱, MCP 도구
  브리지, resume 세션을 소유한다. 소유 경계는 같은 선에 선다.
- **masc 가 소유하는 계약** — programmatic 표면의 소비 계약(work-with-cli.md
  Programmatic mode):
  - `--output json`(종료 시 메시지 배열) / `--output streaming`(메시지별 한 줄)
    프레임을 읽는 출력 코덱.
  - `--output-dir` 의 `export.json`(토큰 사용량·비용·stop reason·outcome)
    파싱 — usage 관측(§2.4)의 1차 원천. 문서가 적는 subagent별 기록은
    실측에서 보지 못했다.
  - exit code 0-3 의 typed 분류. 3.1.0 실측(§4.1)에서 본 값:
    - 0: `finished`. 도구 거절이 있어도 0 이다.
    - 1: 인자 오류(export.json 없음), `usage_error`(모르는 모델)
    - 2: `infrastructure_failure`(공급자 402 를 `backend_error` 로 담음)
    - 3: `deadline`, `token_limit`, `turn_limit`
    각 값은 한두 번의 실행에서 봤다. exit 3 은 답을 다 받은 실행에도 붙는다
    (m7). exit code 는 큰 갈래이고, 갈래 안의 원인은 `export.json` 의
    `outcome` 으로 가른다.
  - 세션 재개: `-p --continue`·`-p --resume SESSION_ID`(문서화된 표면).
  - 도구 브리지: claude_code lane 이 MCP 브리지를 소유하듯, Vibe 도
    MCP servers 표면이 문서화돼 있다(vibe/code/cli/mcp-servers.md) — masc
    도구를 CLI 의 MCP 설정으로 주입하는 브리지를 채택할지는 첫 층 실측
    항목으로 미룬다(연구 문서 §6).
- **무인 도구 승인·project trust(제안 계약)**:
  - lane 전용 config 는 `default_agent = "ask"` 로 고정한다.
    `--auto-approve`/`--yolo` 와 `default_agent = "auto-approve"` 는 사용하지
    않는다.
  - 실행에 필요한 최소 tool 만 `--enabled-tools` 로 제한하고, 허용할 tool 은
    per-tool `permission = "always"` 또는 bash command allowlist 로 명시한다.
    그 밖의 tool 은 `permission = "ask"`(무인 거부) 또는 `never` 로 둔다.
    `--enabled-tools` 와 per-tool `permission` 은 실측하지 않았다.
    `--disabled-tools file_system.bash` 는 유효 설정에 들어갔다. 그런데도 bash
    호출이 일어났고 m10 과 같은 approval 거절로 끝났다(m11). 이 플래그가
    도구를 모델에서 숨기는지는 이 결과로 가를 수 없다.
  - headless 의 `ask` agent 는 승인이 필요한 tool call 을 거부한다(§4.1 m10).
    거부는 그 effect 의 `state.status=failed`, `error.code=tool_denied` 로만
    드러나고 실행 전체는 exit 0 `finished` 다. 그래서 lane 은 exit code 가
    아니라 effect 상태를 읽어 거부를 안다. `ask` 에서도 `echo hi`(m8)와
    `pwd && ls -la`(m9)는 `approvalType=always`, `approvalSource=config` 로
    승인 없이 돌았다. 그때 사용자 `config.toml` 은 `theme` 한 줄이었고 유효
    설정의 `tools` 는 비어 있었다. 그래서 이 허용은 기본 설정에서 왔다. 기본
    허용 목록의 범위는 재지 않았다.
  - 운영자가 project 의 `.vibe`·skills·AGENTS.md 를 검토한 root 만 사전
    trust 하거나 그 invocation 에 `--trust` 를 부여한다. lane 이 임의 cwd 를
    자동 trust 하지 않고, 미신뢰 project config·skills·agent files 무시 경고를
    숨기지 않는다.
- **착수 조건**: 무인 호출의 존재는 문서로 확정됐다(연구 §3). 구현 Task 는
  **lane 코드 작성 전 선행 실측**부터 시작한다 — `--output json`/`streaming`
  프레임과 `export.json` 을 fixture 로 촬영해 필드 수준 계약을 문서화한다
  (§4.1). 코덱을 세울 수 없으면 이 RFC 를 Deferred 로 되돌린다.
- **배정 조건**: API-only/Vibe-only 소비 곡선으로 pool 관계를 확인하는 실측은
  Keeper 에 Vibe lane 을 배정하기 전에 한다. 코덱·분류·카탈로그 층은 Keeper
  요청을 보내지 않아 용량에 닿지 않는다. 초판은 이 실측을 코드 전 조건으로
  두었다. 운영자가 2026-11-07 에 구현을 진행하라고 정한 뒤 배정 앞으로 옮겼다.
  shared pool 로 확인되면 배정을 멈추고 lane 필요성을 다시 검토한다.
  지금 있는 것은 Vibe-only 호출 한 번의 전후 값 하나다(§4.2). 대조 읽기가 없어서
  곡선이 아니다. API-only 호출은 API 키 예산이 바닥나 만들 수 없었다. API 쪽 예산이
  다시 열린 뒤에 두 쪽을 반복해 잰다.
- **우회의 금지는 문서화되지 않은 TTY 조종에 한한다**(초판은 문서화된
  --resume 까지 금지했다 — 리뷰 S3). 문서화된 programmatic 표면이면 resume
  도 lane 의 정당한 원시다.
- antigravity 패턴(OAuth 자격 증명을 저마다 모듈로 소유하는 패밀리)은 Vibe
  CLI 가 자격 증명을 스스로 provisioning 하므로 채택하지 않는다. masc 는
  로그인 절차를 소유하지 않는다.

### 2.2 자격 증명 — CLI 소유, masc 는 준비 상태만 관측

- 브라우저 로그인 자격 증명의 저장·수명·갱신은 Vibe CLI 소유다. masc 는
  로그인 됨/플랜 준비 상태만 읽어 lane 상태로 노출한다. `vibe -p "/whoami"`
  는 slash 명령으로 처리되지 않고 모델 프롬프트가 된다(§4.1 m9: 3턴, 입력
  64,027 토큰). 그래서 준비 검사에 쓰지 않는다. 토큰 파일을 직접 읽거나
  재발급하지 않는다.
- 준비 검사는 `vibe-acp` 의 확장 메서드로 한다(§4.2). `_auth/status` 는 자격 증명
  출처 종류를, `_account/read` 는 `status`·`plan.kind`·`apiKey.scope` 를 준다.
  프롬프트를 보내지 않아 모델을 부르지 않는다. 이 메서드는 공개 문서에 없는
  3.1.0 소스의 표면이다. 그래서 lane 이 고정한 Vibe 버전에서만 믿는다.
  - 준비됨: `authenticated=true`, `authState=os_keyring`, `status=ready`,
    `apiKey.scope=vibe` 가 모두 맞고, budget 을 읽었다면 100% 미만일 때다. PAYG 가
    켜져 있으면 100% 를 넘긴 호출은 청구되고, 꺼져 있으면 멈춘다(Vibe 소스
    `AccountBudgetView`). lane 은 둘 다 받지 않는다.
  - Vibe 가 billing 을 못 읽으면 budget 은 `null` 이다(시간 초과, 권한, 공급자). 그때
    준비 검사는 "budget 모름"을 따로 돌려준다. 남은 몫이 있다고 적지 않는다.
  - `authenticated` 는 저장된 값이 있다는 뜻일 뿐이다. Vibe 는 이 값을 서버에 묻지
    않는다(`can_use_active_provider`). 만료되거나 취소된 키는 `_account/read` 의
    `status=unauthorized` 로 드러난다(`/whoami` 의 401·403).
  - `_account/read` 는 Vibe 의 활성 공급자를 따른다. 공급자가 Mistral 이 아니면
    `status=unavailable` 이다. 그래서 준비 검사는 lane 호출과 같은 config 로 돈다.
  - 준비 검사는 읽기만 하지 않는다. `_account/read` 가 성공하면 `~/.vibe` 의 whoami
    캐시를 다시 쓰고, tenant URL 을 `config.toml` 에 고칠 수 있다. `session/new` 는
    세션 lease 를 잡는다.
  - 그 밖의 값은 갈래마다 typed 로 남긴다. 모르는 값은 `Unrecognized_*` 로 그대로
    남긴다.
- setup 은 자격 증명을 macOS keychain(`svce=ai.mistral.vibe`,
  `acct=MISTRAL_API_KEY`)에 둔다. env 의 `MISTRAL_API_KEY` 가 keychain 보다
  먼저다(§4.1 m4). masc 서버 환경에는 mistral HTTP 레인용 같은 이름의 변수가
  있으므로, lane 은 Vibe 자식 프로세스 환경에서 이 변수를 뺀다. 빼지 않으면
  Vibe 는 env 키를 쓴다(m4 는 그 키로 402 를 받았다).
- `vibe -p` 는 Rust 바이너리(`vibe/_bin/vibe-rs`)를 실행한다. 그 자격 증명 순서는
  m4(env 가 keychain 보다 먼저)만 쟀다. 준비 검사의 `vibe-acp` 는 Python 이다. 그
  `assess_auth_state` 는 프로세스 env → `~/.vibe/.env` → OS keyring 순서이고, OIDC 를
  켜면(`VIBE_CLI_OIDC_ENABLED`) OIDC 토큰이 그보다 먼저다(`utils/api_keys.py`). lane
  의 자식 env 에는 `VIBE_*` 이름이 없다. `vibe -p` 가 `~/.vibe/.env` 를 어떻게 읽는지,
  두 프로그램이 같은 keychain 항목을 읽는지는 재지 않았다(§5).
- 다계정: Vibe CLI 의 profile 기능(config.toml `[[providers]]`, api-keys
  페이지의 profile)이 있는지 실측 뒤 #49200 C2a 계열(계정 스택)에 합류
  여부를 정한다. 이 RFC 는 단일 계정만 약속한다.
- env 의 API 키(`MISTRAL_API_KEY`)는 이 lane 의 자격 증명이 아니다 — 그
  경로는 기존 mistral HTTP 레인의 API 사용량 경로다. setup 이 keychain 에 둔
  자격 증명도 이름이 `MISTRAL_API_KEY` 라서 이름으로는 둘을 가를 수 없다. Vibe 의
  whoami 캐시는 둘을 `plan_type` 으로 갈랐다(keychain 자격 증명 `chat`, env 키
  `api`, §4.2).
  $30 전용 pool 이라고 단정하지 않고 pool 관계는 배정 전에 실측한다(§2.1).

### 2.3 모델·thinking 계약

- lane 이 노출하는 모델은 CLI 가 알려 주는 목록을 실측해 카탈로그에 옮긴다.
  m3 의 `usage_error` 문구가 나열한 별칭은 glm-5-3, mistral-large-4-0-3,
  mistral-medium-3.5, zai-glm-5-3-flash 다. 이 목록이 CLI 에 내장된 것인지
  계정에서 오는 것인지, 각 별칭이 실제로 답하는지는 재지 않았다. 유효 설정의
  `routed_default_model` 은 `mistral-large-4-0-3` 이었다.
  mistral-large-4 의 chunk-list content/thinking 계약은 이미 HTTP 레인에서
  실측·구현됐다(#49350, #49554). lane 은 CLI 가 content 를 이미 해석해
  내주므로 우리 wire 파서를 재사용하지 않는다.
- thinking 수준 매핑: Vibe `off/low/medium/high/xhigh/max` → masc
  Reasoning_effort(8값) 의 대응값. 이름만 다른 `off`↔`none` 은 lane 경계에서
  어휘표 한 줄로 바꾼다(문자열 비교 분기가 아니다). 단 CLI 표면이 `off`/
  `none` 을 실제로 받는지는 미실측이다(API wire 는 `none` 을 거부한다는
  실측이 있다) — 첫 층 실측 항목에 넣는다.

### 2.4 사용량 관측

- usage 의 1차 원천은 `--output-dir` 의 `export.json`(토큰 사용량·비용)이다.
  세션이 시작되기 전에 끝난 실행은 `usage`·`cost_usd` 가 `null` 이고(m3·m5),
  인자 오류는 export.json 을 쓰지 않는다(m2). Admin usage API 의
  `vibe_usage` 는 Enterprise 전용이라 Pro 운영에서 못 쓴다. 콘솔의 두 막대는
  사람이 읽는 원장으로 남기고, lane 이 예측 비용 모델을 발명하지 않는다.
- Vibe 몫 계량기는 `_account/read` 의 `budget.usagePercentage` 다. Vibe 소스는 이
  값을 `/v1/billing/budget` 의 `vibe_budget` 에서 읽는다. 계정(조직) 전체 값이고,
  읽으려면 `see_org_inference_usage` 권한이 있어야 한다. m12 는 `cost_usd 0.0` 이었는데
  호출 뒤에 이 값이 올랐다(§4.2, 한 번, 대조 읽기 없음).
- 그래서 lane 은 호출 단위 사용량을 `export.json` 의 토큰으로 적는다. 계량기는 남은
  몫을 보는 계정 단위 값으로만 쓴다. 여러 Keeper 가 겹치면 어느 호출이 값을 올렸는지
  가를 수 없어서, 호출에 나눠 붙이지 않는다.
- 이 keychain 자격 증명에서 `cost_usd` 는 매번 0.0 이었다(§4.1). m6 의
  `--max-price 0.000001` 은 걸리지 않았다. 비용이 0 이어서인지, 상한을 턴
  사이에만 보는지는 한 번의 실행으로 가를 수 없다.
- `--max-tokens`·`--time-limit`·`--max-turns` 는 exit 3 으로 끝났다. 다만
  상한을 넘긴 뒤에 멈춘다. m7 은 상한 200 에 출력 845 토큰으로 답을 다 낸 뒤
  `token_limit` 였고, m5 는 상한 1초에 3.05초를 돌았다. 그래서 이 셋은 요청
  크기를 미리 묶지 못하고, 넘긴 실행을 끝낼 뿐이다.

### 2.5 실패 양상의 typed 처리

- 포함분 소진 후 PAYG 가 켜져 있으면 prepaid credits 를 쓰고, 꺼져 있으면
  "usage can stop until the next billing period or until an admin changes the
  settings" 다(admin/billing-usage/subscriptions.md). 따라서 제품 차단을 확정
  사실로 두지 않고, 실제 거절 출력을 실측해 typed 실패(Quota_exhausted 상당의
  기존 분류에 붙인다)로 매핑한다. 실측 전에는 미분류로 두고 추측 분류를
  만들지 않는다. 플랜 쪽 소진은 아직 못 봤다. env 키로 간 API 경로의 402 는
  exit 2 `infrastructure_failure` 였다(§4.1 m4).
- 로그아웃은 준비 검사의 `authenticated=false`(`signed_out`)다. `signed_out` 은
  env·`~/.vibe/.env`·keyring 어디에도 값이 없을 때만 나온다(`auth_state.py`).
- 만료되거나 취소된 키는 keyring 에 남아 `os_keyring` 으로 읽힌다. 그 키는
  `_account/read` 의 `status=unauthorized` 로 드러난다(`/whoami` 401·403). 실제
  `unauthorized` 응답은 만들지 않았다. 자동 재로그인은 시도하지 않는다.

## 3. 변경되는 것

- 새 runtime lane 모듈(참조: runtime_claude_code.ml 구조)과 카탈로그/런타임
  표면, keeper 배정 가능 항목 추가. runtime.toml 스키마는 provider 표 한 줄
  추가 외에 바뀌지 않는다.
- 기존 mistral HTTP 레인은 그대로 둔다. 두 레인의 pool 이 다르다고 전제해
  용량을 합산하지 않고, API-only/Vibe-only 소비 곡선 실측 결과로 배정 정책을
  정한다.

## 4. 순서

1. 구현 Task(MASC 별도 등록)의 첫 층: **lane 코드 작성 전 선행 실측** —
   programmatic fixture(`--output json`,
   `streaming`, `export.json`, exit code 0-3, `off`/`none` 수용), 최소 tool
   권한·trust·거부 양상, 무인 준비 검사(§4.2)와 키 만료 구분. 코덱을 세울 수
   없으면 이 RFC 를 Deferred 로 되돌린다.
2. 실측 후 lane 을 유지하기로 결정하면: 출력 코덱(json/streaming/export.json)
   → exit code typed 분류와 준비 검사 → 카탈로그·배정 표면 → API-only/
   Vibe-only 소비 곡선 실측(배정 조건) → keeper 1곳 시범 배정.
   층 이름: L0 = 1의 실측, L1 = 출력 코덱, L2 = 실행과 결과 분류, L2b = 준비 검사,
   L3 = 카탈로그·배정 표면.
3. 각 층은 스택 PR 이고, 계약 시험은 코덱 파싱·분류·인자 조립만 둔다
   (TUI 문구·화면 시험 금지 규칙 그대로).
4. 연기 항목의 소유: 다계정 스택은 첫 층 실측 뒤 #49200 계열로 MASC task
   를 따로 등록해 소유자를 정한다(이 RFC 는 단일 계정만 약속). 콘솔 막대
   의미와 pool 관계 확인은 2 의 배정 조건이다.

### 4.1 1단계 실측 결과 (2026-11-07, vibe 3.1.0)

기록과 fixture: `docs/evidence/vibe-official-client-lane-20261107/`.

- pool: 묶음 안에서 m4(env 키)는 402 `billing_api_budget_exhausted` 로 exit 2
  였다. 같은 시간대의 keychain 자격 증명 실행(m0·m1·m6 등)은 exit 0,
  `cost_usd 0.0` 이었다. 이 대비에서 Vibe 호출은 막히지 않았다.
  - setup 이 브라우저 로그인이었는지 키 입력이었는지는 기록하지 않았다. 두 키의
    종류는 §4.2 가 키 scope 로 적는다.
  - 공식 문서의 "shared" 와 어떻게 맞는지, 콘솔 두 막대의 소비 곡선은 재지
    않았다.
- 출력: `--output json` 은 메시지 배열이다. `streaming` 은 그 원소와 같은
  모양의 객체를 한 줄에 하나씩 낸다. 1토큰 답 한 번에서 세 줄 모두
  `completed` 였고, 생성 중인 부분 줄은 보지 못했다. 원소 type 은
  message·reasoning·effect 를 봤다. `export.json` 은 `schema_version=1` 이다.
- exit code 와 `outcome`: 위 §2.1 의 분류대로다.
- 도구: `ask` 에서 승인이 필요한 호출은 `tool_denied` 로 거절됐다. `echo hi` 와
  `pwd && ls -la` 는 기본 설정의 허용으로 승인 없이 돌았다.
  `--disabled-tools file_system.bash` 를 줘도 bash 호출이 일어났고 같은 방식으로
  거절됐다.
- 준비 검사: `-p "/whoami"` 는 쓸 수 없다. §4.2 의 `vibe-acp` 확장 메서드를 쓴다.
- 판단: 코덱을 세울 fixture 가 있으므로 §4 의 2 로 간다. pool 관계 실측은
  §2.1 배정 조건대로 Keeper 배정 전에 한다. 두 레인의 용량은 합산하지 않는다.
- 남은 실측
  - 배정 전: API-only/Vibe-only 소비 곡선(§2.1 배정 조건)
  - 그 밖: 플랜 소진·세션 만료의 실패 모양, thinking `off`/`none` 수용,
    `--resume`, `--enabled-tools`·per-tool permission, `--disabled-tools` 의
    효과, 기본 허용 목록, 각 모델 별칭의 실제 응답, 토큰을 쓴 뒤 시간 상한이
    걸릴 때의 usage, MCP 브리지, `vibe-acp` 로 세션을 돌리는 경로,
    `vibe-app-server`(3.1.0 에 함께 설치된다), `unauthorized` 응답

### 4.2 L0 뒤 실측: 준비 검사와 Vibe 몫 계량기 (2026-11-07)

기록: 같은 묶음 README 의 「L0 뒤 실측」 절, `acp/`, `fixtures/m12/`,
`repro/acp-probe.py`. 이 절은 계정 값(플랜 이름, budget 수치, 키 끝자리)을 더하지
않았다.

- 준비 검사: `MISTRAL_API_KEY` 를 뺀 환경으로 `vibe-acp` 를 띄운다. 그리고
  `initialize` → `_auth/status` → `session/new` → `_account/read` 를 보낸다.
  다섯 번 돌렸고(처음, m12 앞, m12 뒤, 스크립트를 고친 뒤 두 번) 모두
  `_account/read` 의 답을 받았다. 잰 시간은 5.0초, 7.4초, 5.8초다. 결과는
  `authState=os_keyring`, `status=ready`, `plan.kind=chat`, `apiKey.scope=vibe` 다.
- 자격 증명 순서(`vibe-acp`, `vibe/setup/auth/auth_state.py`): 프로세스 env →
  `~/.vibe/.env` → OS keyring. `vibe -p` 의 Rust 바이너리에는 이 소스가 해당하지
  않는다(§2.2).
- 키 종류: Vibe 의 whoami 캐시에서 keychain 자격 증명은 `plan_type=chat`, env 키는
  `plan_type=api` 였다. Vibe 소스 주석은 plan_type 이 키 scope 에서 온다고 적는다
  (`chat`↔`vibe`, `api`↔`workspace`). 서버 쪽은 확인하지 않았다. `_account/read` 의
  `apiKey.scope` 는 Vibe 가 `plan.kind` 에서 표로 바꾼 값이라 따로 본 근거가 아니다.
- Vibe 몫 계량기: m12(입력 7,938·출력 342 토큰, `cost_usd 0.0`) 앞뒤로
  `budget.usagePercentage` 를 읽었다. 호출 뒤에 값이 올랐다.
- 판단: 준비 검사(L2b)는 이 경로로 한다. Vibe 호출이 Vibe 몫 계량기를 올린 것을
  한 번 봤다. API 쪽 계량기와의 관계는 아직 모른다.

### 4.3 L3 카탈로그 층 (2026-11-08)

- runtime.toml 에 `protocol = "vibe-cli"` 를 쓴다. `command` 는 `vibe` 실행
  파일이고, binding 의 `api-name` 이 Vibe 의 `--model` 이 된다. 편집기에는
  나오지 않는다.
- Vibe 는 운영자의 `~/.vibe/config.toml` 과 keychain 로그인을 그대로 쓴다.
  provider 는 credentials 와 `account-home` 을 적지 않는다. lane 전용
  `VIBE_HOME` 은 그 아래에서도 keyring 이 읽히는지 잰 뒤에 정한다.
- 부르는 곳은 Fusion 패널과 `masc-lane-cli-probe` 둘이다.
  - Keeper 턴은 dispatch 전에 거절한다. Keeper 턴 경로는 시범 배정 층이
    붙인다.
  - exact-output 목록에는 설 수 없다. headless 호출에 output schema 를 넘길
    자리가 없다.
- 호출에는 MASC 시간 한도가 없다(운영자 결정, 11-08). 끝내는 방법은 부르는
  fiber 를 취소하는 것뿐이다.
  - 모델에 `turn-timeout-s`(`0` 포함)나 `reasoning-effort` 를 적은 binding 은
    materialize 되지 않는다.
  - Fusion 그룹이 `timeout_s` 를 적으면 그 패널리스트는 프로세스를 띄우기
    전에 거절한다. 이미지와 output schema 도 같다.
- 패널리스트는 빈 임시 디렉터리를 `--workdir` 로 받고 `--trust` 는 받지
  않는다. 답은 `finished` 로 끝난 실행의 마지막 assistant 메시지다.
- 준비 검사는 `masc-lane-cli-probe --vibe-acp PATH` 가 시도 전에 한 번 한다.
  budget 을 모르면 그렇다고 찍고 진행한다(운영자 결정, 11-08). 다른 이유로
  준비가 안 됐으면 exit 3 으로 멈춘다.
- 실패 분류(`Exact_lane_failure`):
  - limit 계열 outcome(`turn_limit`·`token_limit`·`price_limit`·`length`)은
    `Output_limit` 이다.
  - `refusal` 과 읽을 수 없는 출력은 `Output_unusable` 이다.
  - `usage_error`·`config_error`·모르는 outcome·실행 파일 없음은
    `Configuration_refused` 다.
  - 시그널·시간 초과·`infrastructure_failure`·`aborted` 는 `Transient` 다.
  - 구독 몫 소진은 아직 typed 로 나누지 않는다(§2.5).
- 남은 것: 소비 곡선 실측과 keeper 시범 배정, 몫 소진 출력 실측.

## 5. 리스크

- `--output json`/`streaming` 프레임과 `export.json` 의 필드는 문서가 개요만
  적는다. §4.1 의 fixture 가 코덱의 계약이다. 보지 못한 원소 type 이나 enum
  값은 코덱이 `Unrecognized_*` 로 그 값 그대로 남기고, 아는 값으로 추측하지
  않는다.
- 공식 Subscriptions 의 shared usage 와 콘솔 두 막대의 관계는 미확인이다.
  Vibe 호출이 Vibe 몫 계량기를 올리는 것은 봤지만(§4.2) API 쪽과의 관계는 재지
  않았다. §4.1 의 대비는 API 예산이 바닥났을 때 keychain 자격 증명의 Vibe 호출이
  돌았다는 것만 보인다.
- CLI 자동 업그레이드(`--check-upgrade`)로 인자·출력이 바뀔 수 있다 —
  lane 은 버전을 고정해 시작하고 변경 시 실측을 다시 돌린다.
- 준비 검사가 기대는 `vibe-acp` 확장 메서드(`_auth/status`, `_account/read`)는 공개
  문서에 없다. Vibe 버전을 바꾸면 이 응답 모양부터 다시 잰다.
- 준비 검사(`vibe-acp`, Python)와 실행(`vibe -p`, Rust `vibe-rs`)은 다른 프로그램이다.
  준비 검사가 ready 여도 실행이 다른 키를 쓸 수 있다. lane 은 실행 결과를
  `export.json` 의 outcome 으로 따로 본다.
