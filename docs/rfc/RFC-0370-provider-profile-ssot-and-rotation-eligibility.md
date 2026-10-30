---
rfc: "0370"
title: "Provider profile SSOT, quota-as-state, rotation eligibility for Internal-carried failures"
status: Draft
created: 2026-08-11
updated: 2026-08-11
author: vincent + claude
supersedes: []
superseded_by: null
related: ["0368", "0129"]
---

# RFC-0370: Provider profile SSOT · quota-as-state · Internal-carried 실패의 rotation 자격

## 1. 문제 — 하루 실측

2026-08-11 라이브 시스템 로그 (`system_log_2026-08-11.jsonl`), keeper cycle 3,119회:

| 항목 | 수 |
|---|---|
| cycle OK | 2,661 |
| cycle FAILED | 284 |
| cycle exception | 174 |

FAILED 284건의 상위 클래스와, 그 클래스의 rotation 자격 (측정:
`test/test_keeper_rotation_eligibility_census.ml` — 실제 후보 loop을 구동해
2번째 후보 도달 여부를 관측):

| error class | rotation | 건수 |
|---|---|---|
| provider:hard_quota | 가능 | 103 |
| provider:network_error | 가능 | 62 |
| serialization:parse_error | 불가 | 29 |
| internal:stream_disconnected | **불가** | 28 |
| internal:app_server_timeout | **불가** | 22 |
| provider:reported_error | 가능 | 14 |
| api:context_overflow | 가능 | 9 |
| internal:remote_command_failed | **불가** | 4 |

세 가지 독립된 결함이 겹쳐 있다:

**P1 — Internal-carried provider 실패는 rotation 자격이 없다 (54건/일).**
`Keeper_runtime_attempt.core_error_to_runtime_outcome`은 `Internal _`에
`None`을 돌려주고, `lane_should_retry`는 상태 코드를 보기 전에 단락된다.
이 결함의 범위는 **Codex app-server 경계 하나다** (PR #28192 리뷰 P2
정정): Claude Code(#28136)와 Antigravity 변환기는 이미 provider·transport
실패를 typed `Provider`/`Api` 생성자로 운반하며, 진짜 내부·state-callback
실패만 `Internal`로 남긴다. Codex 변환기만 catch-all로 전 실패를
`Internal <string>`에 눌러 담아, per-runtime transport 실패가 MASC 내부
버그와 같은 판정을 받았다. `Internal`을 terminal로 두는 것 자체는 옳다 —
틀린 것은 provider 실패가 `Internal`에 실려 들어오는 것이다.

**P2 — 노브가 부분 선언 상태다.** `runtime_toml.ml`이 받는 14개 키 기준,
repo 템플릿(`config/runtime.toml`)은 8개 키가 선언 0건이고, 라이브
배포(`$BASE_PATH/.masc/config/runtime.toml`, 1,440줄)는 `turn-timeout-s`를
**29개 official-client 행 중 5개**(effort 상위 티어: -high/-max/-xhigh)에만
선언했다. `keep-alive`/`num-ctx`/`price-*`/`effort`/`agent`/`is-default`는
양쪽 모두 0건. 노브 자체는 라이브에서 유효함이 실측된다 — 선언된 600.0이
`Antigravity turn timed out after 600.000s`로 발화 (2026-08-11T00:27Z).
파서→스키마→어댑터가 전부 배선돼 있고 주력 행만 침묵한다. 결과:

- 미선언 24행 → 세 런타임의 하드코딩 `default_timeout_s = 300.0`이 주력
  행을 지배 (`internal:app_server_timeout` 22건/일의 원인 — sangsu의
  `gpt-5.3-codex-spark`, 실패 31건의 `claude-sonnet-5` 모두 미선언 행).
  #24386(2026-07-14)이 breaking으로 제거한 총량 집행이 #27690(2026-08-09)
  계열에서 더 낮은 계층에 무단 부활한 형태다.
- `keep-alive`/`num-ctx` 0건 → ollama_cloud 39행의 모델 상주·컨텍스트가
  서버 기본값에 방치.
- `price-*` 0건 → 비용 계산 입력 부재.

**P3 — quota를 에러로만 안다 (103건/일).** 구독 quota는 시간 단위로
리셋되는 창(window)인데, keeper는 소진 상태를 벽에 부딪혀서만 알고 20초
간격으로 재시도한다. `Cooldown_hard_quota`는 존재하지만 문서가 명시적으로
권위를 제거했다 ("has no retry, admission, or lifecycle authority").

## 2. 외부 근거 — 두 시스템의 상반된 해법

### Orca (stablyai/orca, 42k★)

- provider 집합을 8개 유료 벤더로 **닫고** (`'claude' | 'codex' | …`),
  전원이 usage API를 제공하므로 quota를 **사전 조회한 상태**로 모델링:
  `RateLimitWindow { usedPercent; windowMinutes; resetsAt }`,
  HTTP Retry-After에서 받은 `retryAtMs`로 재조회 억제.
- 컨텍스트/턴 소유권은 PTY로 벤더 CLI에 위임 — 자기 소유 문제를 좁혔다.
- 로컬 추론 경로 없음 (`lmstudio`/`vllm`/`llama.cpp`/`openai-compatible`
  코드 검색 0건). 즉 이 정교함은 닫힌 집합의 대가다.

### Hermes (NousResearch/hermes-agent, 228k★)

- 열린 provider 집합을 실제로 운영. 핵심은 `ProviderProfile`:
  선언적 dataclass 하나가 SSOT이고, auth 위저드·doctor 헬스체크·모델
  목록·transport quirk가 전부 profile에서 **파생**된다. "transport가
  20+개 boolean flag를 받는 대신 이걸 읽는다."
- provider quirk를 선언 필드로: `supports_vision_tool_messages`,
  `OMIT_TEMPERATURE` sentinel, per-provider hook
  (`prepare_messages`/`build_extra_body`).
- 복구는 `TurnRetryState` — 시도당 one-shot guard의 typed 집합
  (per-provider OAuth 갱신, llama.cpp grammar fallback 등 16종).

### 종합

Orca의 quota-as-state는 usage API가 있는 provider에서만 성립한다.
Hermes의 profile-SSOT는 열린 집합에서 성립한다. masc는 둘을 합칠 수 있는
위치에 있다: **profile에 "usage를 조회할 수 있는가"를 타입으로 갈라
넣으면**, 조회 가능한 구독 provider는 Orca식 사전 상태를, 조회 불가한
ollama_cloud 39행은 지금의 사후 typed 에러를 각자 갖는다. 한 축에
뭉쳐서 생기는 전염 (39행 때문에 quota 상태화를 포기)이 사라진다.

## 3. 설계

### 3.1 P1: typed 운반 — Internal에서 provider 실패를 꺼낸다 (구현 대상)

official-client 런타임의 에러 경계에서, 이미 typed로 알고 있는 실패를
`Internal` 문자열로 눌러 담지 않고 `Agent_core.Error`의 기존 변형으로
운반한다:

| 현재 (Internal 문자열) | 운반 목표 |
|---|---|
| "turn timed out after Ns" | `Api (Timeout { phase })` |
| "stream disconnected before completion" | `Provider (NetworkError { kind })` |
| "Error running remote command" | `Provider (ProviderUnavailable _)` |

이건 새 분류기가 아니다 — 런타임이 실패를 만드는 지점은 이미 그 실패가
무엇인지 안다 (`Eio.Time.Timeout` 캐치, EOF 감지). 아는 것을 아는 타입에
싣는 것뿐이다. string re-parse는 도입하지 않는다 (CLAUDE.md 문자열
분류기 금지; RFC-0042/0154가 닫은 축).

회귀 가드: census 테스트의 baseline이 pin이다. 이 변경 후
`internal:app_server_timeout` 행은 census에서 사라지고 (해당 에러가 더
이상 `Internal`이 아니므로) 대응하는 typed 행이 `rotation 가능`으로
옮겨간다 — baseline 갱신이 컴파일·테스트로 강제된다.

RFC-0368과의 경계: 0368은 실패 **후** official-client 세션의 claim 시점
복구를 다룬다. 본 RFC는 실패 **시점**의 레인 rotation 자격을 다룬다.
같은 실패가 두 정책을 순서대로 만난다 (rotation 시도 → 다음 claim의
auto-heal).

### 3.2 P2: 카탈로그 선언 — 죽은 노브에 값을 준다 (구현 대상)

코드 변경 없음. 선언만 한다:

1. official-client 3종 행에 `turn-timeout-s` 명시. 하드코딩 300.0은
   "카탈로그 미선언 시 fallback"으로 강등되고, 정본은 카탈로그가 된다.
2. ollama_cloud 39행에 `keep-alive` 선언 (모델 상주 정책의 명시화).
3. 선언율 census를 반복 실행 가능한 스크립트로 유지해 회귀를 본다.

`price-*`/`effort`/`agent`/`is-default`는 소비자 실사용 확인 후 별도
선언 (본 RFC 범위 밖 — 소비자가 없으면 선언이 아니라 키 제거가 옳다).

### 3.3 P3: quota-as-state (단계적 — 본 RFC는 설계만)

`Runtime_schema` provider 행에 usage 조회 능력을 타입으로 추가:

```
type usage_visibility =
  | Usage_queryable of { probe : usage_probe }   (* 구독: Claude/Codex/… *)
  | Usage_opaque                                  (* ollama_cloud 등 *)
```

`Usage_queryable`인 provider만 `RateLimitWindow` 동형의 상태
(`used_percent`, `resets_at`)를 보유하고, 셀렉터의 **후보 구성 입력**이
된다 (admission 게이트가 아니라 후보 생성 시점의 사실 — 소진된 창의
runtime은 후보 목록에 이름이 오르지 않고, `resets_at` 경과로 자연
복귀). `Usage_opaque`는 현행 사후 typed 에러 + rotation 경로를 그대로
유지한다.

기존 게이트 원칙과의 정합: 이것은 파생/장식 필드 guard가 아니라
provider가 보고한 1차 사실이며, blast radius는 후보 구성 한 지점이다.

## 4. 검증

- `test_keeper_rotation_eligibility_census.ml`: 17개 에러 클래스 × 실제
  후보 loop 구동, baseline pin. P1 구현 시 baseline diff가 곧 변경 증명.
- 선언율 census: 14키 × config 매트릭스, P2 후 죽은 노브 0 목표
  (단 §3.2의 보류 키 제외).
- 라이브: P1+P2 배포 후 동일 24h 창에서 `cycle FAILED` 중
  rotation-불가 클래스 비중 재측정 (기준선: 85/284건).

## 5. 하지 않는 것

- string 분류기 추가 (금지 축).
- admission 게이트 부활. 후보 구성은 셀렉터의 입력이지 dispatch 거부가
  아니다.
- ollama_cloud에 usage 조회 흉내 (API가 없다 — `Usage_opaque`가 사실).
- 300.0 상수의 즉시 제거. RFC-AC-026 §7 순서 제약: idle 감지가 증명될
  때까지 총량 backstop은 유지, 카탈로그 선언으로 정본만 이동.
