---
rfc: "antigravity-runs-only-on-the-acp-driver"
title: "Antigravity Keepers run on the ACP driver alone, and the Antigravity CLI lane is removed"
status: Draft
created: 2026-11-25
updated: 2026-11-25
author: claude-main
related: ["keeper-context-window-in-tokens"]
---

# RFC: Antigravity Keeper 는 ACP driver 하나로만 돈다

- 관련: #54717, #54718, #54719, task-4068
- 결정(운영자, 2026-11-25): 공식 클라이언트의 창 넘침은 runtime 마다 덧대지 않고 ACP 경로 하나에서 다룬다(「덕지덕지 말고 ACP 안으로」).
- 범위:
  - masc: Antigravity 를 부르는 길을 ACP driver(`Runtime_acp_client.Antigravity`) 하나로 줄인다.
  - masc: Antigravity CLI 레인(`Keeper_antigravity_runtime`, `Runtime_antigravity*`)을 지운다. hard cut 이다. 옛 설정을 읽는 변환기는 만들지 않는다.
  - 운영 설정: `antigravity_61706117.*` 후보를 쓰는 레인 2개와 그 레인을 쓰는 Keeper 6명을 `antigravity_acp.*` 후보로 옮긴다.
  - agent_core, 다른 ACP driver(Kimi Code, Mistral Vibe, Muse Code)는 바꾸지 않는다.

## 1. 사건

2026-11-25 pr-updater 의 문맥이 약 180만 토큰(메시지 1,178개)까지 자랐다.
Gemini API 레인은 #54713 으로 보내기 전에 토큰을 세게 됐다.
같은 날 공식 클라이언트 레인을 같은 규칙으로 살폈더니 Antigravity 에서 두 길이 갈렸다.

- CLI 레인(`antigravity_cli`)은 창 넘침 신호를 typed 로 읽어도 버린다.
  - `keeper_antigravity_runtime.ml:57`: `Signal_context_overflow _ | None -> ProviderReportedError`.
  - 넘침이 범위를 줄이지 않는다. `refused_model_input` 도 남지 않는다. 다음 턴이 같은 seed 로 다시 실패한다(#54717).
- ACP 레인은 JSON-RPC `error.data` 를 `Retry.classify_structured_json` 하나로 읽는다(#54461). Muse 의 `kind` 도 #54722 로 같은 곳에서 읽는다.

같은 600만 자 프롬프트를 `agy acp` 1.5.16 에 직접 보낸 실측(#54718 댓글):

| 에이전트 | 결과 | 창 신호 |
|---|---|---|
| `agy acp` 1.5.16 (기본 Gemini 4 Neon) | 거절 없이 `inputTokens: 57335` 로 처리, `stopReason: end_turn` | `usage_update.size = 1048576` |
| `muse acp` 1.4.25 | 자체 압축 실패 뒤 `used 697911` 로 처리, `end_turn` | `usage_update.size = 1007997` |

## 2. 왜 문제인가

- 같은 provider 를 두 길로 부른다. 한 규칙(넘침은 typed 로 받고 범위를 옮긴다)을 고치려면 두 번 고쳐야 한다.
- CLI 레인의 넘침 처리를 따로 고치면 ACP 에 이미 있는 분류를 한 벌 더 만든다. 운영자 결정과 반대다.
- 운영 Keeper 29명 중 6명이 CLI 레인을 쓴다. ACP 레인을 쓰는 Keeper 는 0명이다. 지금 ACP Antigravity 경로는 운영에서 검증되지 않은 채 코드만 남아 있다.

## 3. 지금 일어나는 일

### 3.1 두 길

| | CLI 레인 | ACP 레인 |
|---|---|---|
| 설정 provider | `antigravity_61706117` | `antigravity_acp` |
| 프로세스 | 턴마다 CLI 를 띄운다(`Runtime_antigravity`) | Keeper 마다 `agy acp` 하나를 오래 띄운다(`Runtime_acp_client`) |
| 실패 분류 | `Turn_failed of string` 등 CLI 결과를 `antigravity_cli` 오류로 바꾼다. 넘침은 `ProviderReportedError` | JSON-RPC `error.data` → `Retry.classify_structured_json` |
| 계정 home | 없음(`runtime_setup_login_client.ml:35`) | 없음(같은 파일 `:38`). host CLI 저장소를 쓴다 |
| 공식 클라이언트 범위 계산 | `Keeper_official_client_host` | 같다 |

### 3.2 11-22 에 ACP 를 접은 이유

운영 설정 `runtime.toml` 의 주석(2026-11-22):

> antigravity_acp 는 현행 빌드(5a406aa1)에서 Native_none MCP 권한 거부(title="MCP Tool <name>", kind="execute")와 configOptions[model] 불일치가 실측되어, 검증된 antigravity_61706117(antigravity-cli) 바인딩을 사용한다.

그 뒤 main 에 들어간 ACP 수정 네 개는 모두 `5a406aa1` 의 자손이 아니다(`git merge-base --is-ancestor` 로 확인).

| PR | 다루는 것 |
|---|---|
| #54434 | Vibe/Agy MCP 권한 처리 |
| #54462 | `model_selection` 과 Reasoning_effort 를 ACP 설정·세션 옵션에서 하나로 |
| #54463 | ACP v1 `tool_kind` 를 typed 로, driver 별 MCP 문법 |
| #54534 | `Implicit_mcp_kind` 를 단일 서버 격리에서만 허용 |

두 차단 사유가 풀렸는지는 아직 운영에서 다시 재지 않았다. 5.1 이 그 측정이다.

### 3.3 `agy acp` 가 말없이 잘라 읽는다

1 절 실측에서 `agy acp` 는 보낸 600만 자를 거절하지 않고 57,335 토큰만 읽었다.
- 반복 실패는 생기지 않는다. 대신 Keeper 가 보낸 범위와 에이전트가 읽은 범위가 달라진다.
- masc 는 이 차이를 `usage_update.used` 와 prompt 결과의 `usage.inputTokens` 로만 볼 수 있다.
- CLI 레인에서도 같은지는 재지 않았다.

## 4. 제안

### 4.1 Antigravity 는 ACP driver 하나로 부른다

- `antigravity_acp.*` 만 Antigravity 후보로 남긴다.
- CLI 레인 코드와 설정 provider(`antigravity_<account>`)를 지운다. 지우기 전에 `rg` 로 호출처를 모두 찾는다. 다른 기능이 쓰는 모듈(`Runtime_antigravity_oauth_credential`, `Runtime_account_email` 이 읽는 부분, `Keeper_capability_probe`, fusion 패널)은 ACP 쪽으로 옮기거나 남긴다. 그 목록은 4 단계 PR 이 정한다.
- 옛 설정이 `antigravity_<account>` 를 적으면 설정 검사가 거부한다. 변환하지 않는다.

### 4.2 넘침과 범위는 ACP 의 한 곳에서 다룬다

- typed 넘침: `Retry.classify_structured_json` 이 이미 하는 일이다. 새 분류를 더하지 않는다.
- 말없이 잘라 읽기(3.3): ACP prompt 결과의 `usage.inputTokens` 는 provider 가 센 값이다. 이 값으로 다음 범위를 정할지는 6 절에서 정한다. 거절 문장은 읽지 않는다.
- 범위 이동은 #54733 의 runtime 별 거절 기록을 그대로 쓴다.

## 5. 단계

각 단계는 따로 PR 이다. 앞 단계의 측정이 통과해야 다음으로 간다.

| 단계 | 할 일 | 확인 |
|---|---|---|
| 1 | 3.2 의 두 차단 사유를 현재 운영 빌드로 다시 잰다. Keeper 하나(리뷰어 1명)를 `antigravity_acp` 레인으로 옮긴다. | MCP 도구 호출 10회 이상 성공, 권한 거부 0회. `session/set_config_option` 뒤 `configOptions[model].currentValue` 가 설정한 모델과 같다. |
| 2 | 하루 측정. 같은 Keeper 의 11-24 CLI 레인 기록과 비교한다. | 턴 성공률, 턴당 입력 토큰, 실패 종류(`turn_records`·`agent-core-events`). CLI 대비 성공률이 낮으면 멈추고 원인을 기록한다. |
| 3 | 나머지 5명을 옮긴다. CLI 레인 후보는 설정에서 뺀다. | 3일 동안 CLI 레인 호출 0회. |
| 4 | CLI 레인 코드와 provider 종류를 지운다. | type-check, 관련 테스트(`test_runtime_acp_client` 등) 통과. `rg 'antigravity_cli\|Runtime_antigravity\b'` 결과가 지운 목록과 맞다. |

## 6. 정할 것

- 3.3 의 잘라 읽기를 어떻게 다룰지.
  - (a) 보내기 전에 운영자가 선언한 `max-context` 로 seed 를 자른다. 지금 공식 레인은 `input_limit_of_runtime` 이 `None` 이라 자르지 않는다.
  - (b) 받은 뒤 `usage.inputTokens` 가 보낸 범위보다 작으면 typed 신호로 남기고 다음 범위를 옮긴다.
  - 제안은 (a) 다. 운영자가 선언한 값만 쓰므로 규칙(RFC #37846)에 맞고, 에이전트마다 다른 자르기 정책에 기대지 않는다.
- Antigravity 한도(quota) 표시. CLI 레인은 `Runtime_antigravity_usage` 로 한도 창을 읽는다. ACP 레인에서 같은 값을 얻을 길이 있는지 1 단계에서 확인한다. 없으면 TUI·Dashboard 에 「미보고」로 둔다.
- 계정 여러 개. 두 길 모두 계정 home 이 없어 지금과 같다. 바꾸지 않는다.

## 7. 하지 않는 것

- CLI 레인의 넘침 분류(#54717)를 따로 고치지 않는다. 4 단계에서 코드째 사라진다.
- 다른 ACP driver 의 동작을 바꾸지 않는다.
- 옛 설정 변환기, CLI 레인 호환 계층을 만들지 않는다.

## 8. 시험

- 1·2 단계: 운영 측정이 시험이다. 수치는 PR 본문과 #54717 댓글에 남긴다.
- 4 단계: 지운 모듈을 부르던 테스트는 같이 지운다. ACP Antigravity 의 넘침 분류는 `packages/agent_core/test/test_retry` 와 `test/test_runtime_acp_client` 가 다룬다. 빠진 경우가 있으면 더한다.
