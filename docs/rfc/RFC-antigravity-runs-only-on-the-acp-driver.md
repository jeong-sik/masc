---
rfc: "antigravity-runs-only-on-the-acp-driver"
title: "Antigravity Keepers run on the ACP driver alone, and the Antigravity CLI lane is removed"
status: Draft
created: 2026-11-25
updated: 2026-11-26
author: claude-main
related: ["keeper-context-window-in-tokens"]
---

# RFC: Antigravity Keeper 는 ACP driver 하나로만 돈다

- 관련: #54717, #54718, #54719, task-4068
- 결정(운영자, 2026-11-25): 공식 클라이언트의 창 넘침은 runtime 마다 덧대지 않고 ACP 경로 하나에서 다룬다(「덕지덕지 말고 ACP 안으로」).
- 결정(운영자, 2026-11-25): 6 절의 제안대로 한다. 단, 크기 판단은 정석(RFC keeper-context-window-in-tokens 의 규칙)을 따른다. 4.2 가 그 설계다.
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

### 3.4 ACP 레인이 지금 크기를 정하는 법

ACP 레인은 이미 보내기 전에 범위를 자른다. 그 크기가 규칙(provider 가 센 토큰이나 운영자가 선언한 값만)을 두 곳에서 어긴다.

- `keeper_acp_runtime.ml:13` `default_acp_max_context_tokens = 262_144`: 운영자가 `max-context` 를 선언하지 않으면 이 값을 쓴다. 모르는 값을 편한 기본값으로 바꾼다.
- `keeper_acp_runtime.ml:51` `capacity_bytes_of_tokens`: 토큰 수에 4 를 곱해 바이트 한도로 쓴다. 한국어 UTF-8 은 대개 3바이트가 1토큰 안팎이라, 400K 토큰 선언이 1.6MB 바이트 한도가 되면 실제로는 400K 토큰을 넘길 수 있다. 추정이다.
- 세션 안에서 다음 세션으로 넘기는 판단(`rollover_threshold = 0.80`)은 `usage_update.used`(provider 가 센 값)와 운영자 한도를 비교한다. 이 부분은 규칙에 맞다.
- 공식 클라이언트 레인은 ledger(`Keeper_model_input_ledger`)를 쓰지 않는다(`keeper_official_client_host.ml:329`). 그래서 Agent Core 레인의 `past_max_context` 가 범위를 옮기는 길을 타지 않는다.

## 4. 제안

### 4.1 Antigravity 는 ACP driver 하나로 부른다

- `antigravity_acp.*` 만 Antigravity 후보로 남긴다.
- CLI 레인 코드와 설정 provider(`antigravity_<account>`)를 지운다. 지우기 전에 `rg` 로 호출처를 모두 찾는다. 다른 기능이 쓰는 모듈(`Runtime_antigravity_oauth_credential`, `Runtime_account_email` 이 읽는 부분, `Keeper_capability_probe`, fusion 패널)은 ACP 쪽으로 옮기거나 남긴다. 그 목록은 4 단계 PR 이 정한다.
- 옛 설정이 `antigravity_<account>` 를 적으면 설정 검사가 거부한다. 변환하지 않는다.

### 4.2 ACP 레인의 크기는 Agent Core 레인과 같은 규칙으로 정한다

ACP 만의 크기 계산을 따로 두지 않는다. Agent Core 레인이 이미 쓰는 세 부품에 ACP 를 잇는다.

| 부품 | 지금 | 바꾼 뒤 |
|---|---|---|
| 한도 | ACP: 선언이 없으면 262,144. Agent Core: 운영자 선언 | 둘 다 운영자 선언 `max-context` 만 쓴다. ACP runtime 에 선언이 없으면 설정 검사가 거부한다. `default_acp_max_context_tokens` 를 지운다. |
| 크기 측정 | ACP: 바이트 ×4 추정 | 보낸 범위와 그 요청에 대해 provider 가 센 `usage.inputTokens` 를 짝지어 ledger 에 남긴다. masc 가 범위를 넘기는 레인이라(`Hands_over_its_own_list`) 범위를 안다. `capacity_bytes_of_tokens` 를 지운다. |
| 범위 이동 | ACP: 바이트 한도로 자른다 | `input_limit_of_runtime` 이 `Acp` 에도 운영자 한도를 돌려준다. 다음 seed 의 시작은 `past_max_context` 가 정한다. Agent Core 와 같은 함수다. |

- 세션이 이어지는 동안: 에이전트가 자기 세션 기록을 쌓는다. 다음 세션으로 넘기는 판단은 지금처럼 `usage_update.used` 와 운영자 한도를 비교한다. 한도만 4.2 표의 선언값으로 바뀐다.
- 턴 도중 넘침: 다음 세션으로 넘기는 판단은 턴이 끝날 때만 한다. 한 턴 안에서 세션이 커지는 것은 masc 가 막지 못한다. 턴 안에서 세션을 줄이는 것은 호스트의 압축뿐이다.
  - 측정(2026-11-26, Kimi Code 2.7.2, 운영자 한도 400,000):
    - father 세션은 턴이 끝날 때 625,669 와 447,181 이었다. `.masc/config/keepers/code-reviewer-father.compaction.db` 의 `compaction_epochs.trigger_json`(epoch 5·6)에 남아 있다.
    - uncle 세션에서 가장 큰 요청 입력은 432,196 이었다. Kimi Code 세션의 `wire.jsonl` 에 있는 `step.end` usage 로 셌다.
  - 호스트 넷 중 둘은 프로세스마다 모든 모델의 압축 시점을 받는다(2026-11-26 확인).

    | 호스트 | 받는 길 | 값의 뜻 | 확인한 방법 |
    |---|---|---|---|
    | Muse Code 1.4.25 | `-c context_compaction.provider_context_limit_tokens=<토큰>` | 실효 한도. 압축은 이 한도의 `soft_threshold`(기본 0.75)와 `hard_threshold`(기본 0.9)에서 한다. 두 비율도 `-c` 로 받는다 | `muse exec --provider echo` 에 넣어 봤다(모델 호출 없음). 키를 받고(exit 0), 모르는 키와 hard 이상인 soft 는 거부한다(exit 2) |
    | Antigravity 1.5.18 | 환경 변수 `AGY_CLI_AUTO_COMPACT_OVERRIDE=<토큰, K·M 약식, %>` | 대화를 압축하는 시점. 바이너리 changelog 는 모든 eligible model 에 적용된다고 적는다 | 바이너리 안의 문구로만 확인했다. 실제 압축은 보지 못했다 |
    | Mistral Vibe 3.1.0 | 모든 모델에는 없다 | `VIBE_AUTO_COMPACT_THRESHOLD` 는 자기 값이 없는 모델만 채운다 | vibe 자신의 설정 loader 로 실제 값을 읽었다. 모델 catalog 가 mistral-large-4-0-3 에 자기 값 400,000 을 준다. 변수를 380000 으로 주면 이 모델은 400000 그대로이고, 자기 값이 없는 mistral-medium-3.5 만 380000 이 된다. 모델별 값(`VIBE_MODELS__<모델>__AUTO_COMPACT_THRESHOLD`)은 environment 층이 읽지 못한다며 버린다 |
    | Kimi Code 2.7.2 | 없다 | — | `KIMI_MODEL_MAX_CONTEXT_SIZE` 는 `KIMI_MODEL_NAME` 이 있을 때만 읽고, 그러면 로그인한 OAuth provider 대신 환경 변수 provider 를 쓴다. 설정 폴더를 `KIMI_CODE_HOME` 으로 바꾸면 로그인도 그 폴더에서 다시 해야 한다. 압축 시점은 설정 파일의 창으로 정한다. 창이 1,048,576 이면 약 891K 에서 압축한다 |

  - Codex 는 ACP driver 가 아니지만 `-c model_context_window=<tokens>` 를 받는다(`runtime_codex_app_server.ml` 의 `client_argv`).
  - 운영자가 쓸 수 있는 값은 모델별 `context-rollover-threshold`(#54873)다. 낮추면 한 턴이 커질 자리가 생긴다. 한 턴이 커지는 양을 막지는 못한다.
  - 넘친 세션은 숨지 않는다. 서버 projection 이 `context_tokens_exceed_window` 로 내보낸다. TUI 는 「창 초과」, Dashboard 는 warning(「보고된 입력 토큰이 창 크기를 초과함」)으로 보여 준다.
  - 턴 도중에 `session/cancel` 로 끊지 않는다. 넘침은 durable truth 를 망가뜨리지 않는다. 끊으면 하던 턴의 일을 버린다.
  - 결정(운영자, 2026-11-26): 모델 키 `agent-compaction-threshold`(열린 구간 (0, 1))를 둔다. 세션을 띄울 때 `agent-compaction-threshold × max-context` 를 호스트에 넘긴다(#54915).
    - 턴 끝 롤오버(`context-rollover-threshold`)와 따로 정한다. 예: 롤오버 0.80, 호스트 압축 0.95.
    - 키가 없으면 호스트 기본값 그대로다.
    - driver profile 의 `compaction_point` 가 호스트마다 받는 길을 가진다. Antigravity 는 토큰 수(내림)를 받는다. Muse Code 는 `provider_context_limit_tokens` 에 한도, `soft_threshold` 에 비율, `hard_threshold` 에 1.0 을 받는다. soft 는 hard(설정하지 않으면 0.9)보다 반드시 작아야 해서 hard 를 같이 넘긴다.
    - Kimi Code 와 Mistral Vibe 는 모든 모델에 받는 길이 없다. 이 키를 적으면 그 binding 을 load 에서 이유와 함께 뺀다. 넘겨도 말없이 무시될 수 있기 때문이다.
  - 턴 도중 압축 감지(#54911): ACP client 가 prompt 결과에 `context_compacted` 를 돌려준다.
    - Muse Code 는 journal 의 `context_compaction_installed` 기록으로 판단한다.
    - 다른 호스트는 prompt 도중 `usage_update.used` 가 바로 앞 값보다 작아진 것으로 판단한다. 첫 값은 세션의 마지막 값과 비교한다.
    - 그 전에는 턴 끝 값끼리만 비교해서 턴 안에서 압축한 뒤 다시 커지면 놓쳤다. 로컬 Muse journal 의 압축 83건 중 `mid_turn` 이 25건, `pre_turn` 이 19건이다.
- 에이전트 창과 운영자 한도: 세션을 열 때 에이전트가 알리는 `usage_update.size` 보다 운영자 한도가 크면 typed 설정 오류로 그 후보를 쓰지 않는다. 운영자 한도가 에이전트 창 안에 있으면, 3.3 의 말없이 잘라 읽기는 masc 가 보낸 범위에서는 생기지 않는다.
- ledger 가 없을 때(새 Keeper history, 또는 재기동 뒤 ledger 가 비었을 때): 저장된 마지막 응답 범위(`Keeper_carried_front.read_seed`)에서 시작한다. 그것도 없으면 마지막 완료 턴의 끝(`turn_start`)에서 시작한다. Agent Core 가 ledger 없이 시작하는 자리와 같다(RFC keeper-context-window-in-tokens §13.4).
- typed 넘침: `Retry.classify_structured_json` 이 이미 하는 일이다. 새 분류를 더하지 않는다. 거절 문장은 읽지 않는다.
- 거절된 범위의 이동은 #54733 의 runtime 별 거절 기록을 그대로 쓴다.

이 절은 ACP driver 넷(Antigravity, Kimi Code, Mistral Vibe, Muse Code)에 같이 적용된다. 크기 규칙이 driver 마다 다르면 이 RFC 가 없애려는 갈림이 다시 생긴다.

## 5. 단계

각 단계는 따로 PR 이다. 앞 단계의 측정이 통과해야 다음으로 간다.

| 단계 | 할 일 | 확인 |
|---|---|---|
| 0 | 4.2 를 구현한다. 한도 선언 필수, ledger 기록, `input_limit_of_runtime` 의 `Acp` 갈래, 에이전트 창 검사. | 시험: 선언 없는 ACP runtime 은 설정 검사에서 거부. 첫 prompt 의 `usage.inputTokens` 가 ledger 에 범위와 함께 남음. 한도를 넘는 ledger 면 다음 seed 가 `past_max_context` 대로 옮겨짐. `usage_update.size` < 운영자 한도면 typed 오류. |
| 1 | 3.2 의 두 차단 사유를 현재 운영 빌드로 다시 잰다. Keeper 하나(리뷰어 1명)를 `antigravity_acp` 레인으로 옮긴다. | MCP 도구 호출 10회 이상 성공, 권한 거부 0회. `session/set_config_option` 뒤 `configOptions[model].currentValue` 가 설정한 모델과 같다. |
| 2 | 하루 측정. 같은 Keeper 의 11-24 CLI 레인 기록과 비교한다. | 턴 성공률, 턴당 입력 토큰, 실패 종류(`turn_records`·`agent-core-events`). CLI 대비 성공률이 낮으면 멈추고 원인을 기록한다. |
| 3 | 나머지 5명을 옮긴다. CLI 레인 후보는 설정에서 뺀다. | 3일 동안 CLI 레인 호출 0회. |
| 4 | CLI 레인 코드와 provider 종류를 지운다. | type-check, 관련 테스트(`test_runtime_acp_client` 등) 통과. `rg 'antigravity_cli\|Runtime_antigravity\b'` 결과가 지운 목록과 맞다. |

## 6. 정한 것과 남은 것

정한 것(운영자, 2026-11-25):
- 잘라 읽기는 보내기 전에 막는다. 크기는 4.2 의 규칙으로 정한다. 받은 뒤 문장이나 추정으로 고치지 않는다.
- Antigravity 한도(quota) 표시: CLI 레인은 `Runtime_antigravity_usage` 로 한도 창을 읽는다. ACP 레인에서 같은 값을 얻을 길이 있는지 1 단계에서 확인한다. 없으면 TUI·Dashboard 에 「미보고」로 둔다. 추정해서 채우지 않는다.
- 계정 여러 개: 두 길 모두 계정 home 이 없어 지금과 같다. 바꾸지 않는다.

- 운영 `runtime.toml` 의 ACP runtime 17개는 모두 `max-context` 를 선언했다(2026-11-25 확인: `antigravity_acp` 9개, `kimi_acp` 6개, `vibe_acp` 2개). 기본값을 지워도 막히는 runtime 은 없다.
- 1 단계로 옮기는 Keeper 의 후보는 지금 CLI 레인과 같은 400K 선언을 쓴다(`antigravity-gemini-4-neon-medium-400k` 와 같은 값). `antigravity_acp` 의 기존 선언 1,048,576 은 에이전트 창 크기와 같아서, 비교 기준이 CLI 레인과 달라진다.

## 7. 하지 않는 것

- CLI 레인의 넘침 분류(#54717)를 따로 고치지 않는다. 4 단계에서 코드째 사라진다.
- 다른 ACP driver 의 동작은 4.2 의 크기 규칙 밖에서는 바꾸지 않는다.
- 옛 설정 변환기, CLI 레인 호환 계층을 만들지 않는다.

## 8. 시험

- 1·2 단계: 운영 측정이 시험이다. 수치는 PR 본문과 #54717 댓글에 남긴다.
- 4 단계: 지운 모듈을 부르던 테스트는 같이 지운다. ACP Antigravity 의 넘침 분류는 `packages/agent_core/test/test_retry` 와 `test/test_runtime_acp_client` 가 다룬다. 빠진 경우가 있으면 더한다.
