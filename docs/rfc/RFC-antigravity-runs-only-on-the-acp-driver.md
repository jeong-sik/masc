---
rfc: "antigravity-runs-only-on-the-acp-driver"
title: "Antigravity Keepers run on the ACP driver alone, and the Antigravity CLI lane is removed"
status: Draft
created: 2026-11-25
updated: 2026-11-27
author: claude-main
related: ["keeper-context-window-in-tokens"]
---

# RFC: Antigravity Keeper 는 ACP driver 하나로만 돈다

- 관련: #54717, #54718, #54719, task-4068, #41906, #41425
- 결정(운영자, 2026-11-25): 공식 클라이언트의 창 넘침은 runtime 마다 덧대지 않고 ACP 경로 하나에서 다룬다(「덕지덕지 말고 ACP 안으로」).
- 결정(운영자, 2026-11-25): 6 절의 제안대로 한다. 단, 크기 판단은 정석(RFC keeper-context-window-in-tokens 의 규칙)을 따른다. 4.2 가 그 설계다.
- 결정(운영자, 2026-11-27, #41906): `agy` 가 메시지 하나를 말없이 자르는 것을 사실로 적는다(3.3). Antigravity driver 는 그 크기를 넘는 메시지를 보내기 전에 typed 로 거절한다. 거절한 후보는 쓰지 않고 레인이 다음 후보로 간다. 계정 탓이 아니므로 계정을 쉬게 하지 않는다. 4.3 이 그 설계다.
- 결정(운영자, 2026-11-27, #41425): 쿼터 거절 뒤 계정을 쉬게 하는 조건을 이 RFC 의 수락 조건으로 둔다(5 절). 쉬는 단위는 정하지 않고 6 절의 열린 질문으로 둔다.
- 범위:
  - masc: Antigravity driver(CLI·ACP 둘 다)가 메시지 하나의 바이트를 재고, 한도를 넘으면 보내기 전에 거절한다(4.3).
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

`agy acp` 의 57,335 토큰은 창 안에서 읽은 양이 아니다. `agy` 가 메시지를 192,000 바이트에서 자르고 남은 양이다(3.3, 2026-11-27 확인).

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

### 3.3 `agy` 는 메시지 하나를 192,000 바이트에서 말없이 자른다

1 절 실측에서 `agy acp` 는 보낸 600만 자를 거절하지 않고 57,335 토큰만 읽었다. 2026-11-27 에 그 기록을 다시 읽었다. 창이 찬 것이 아니라 메시지 하나가 잘린 것이다. CLI 레인도 같다.

`agy` 는 받은 메시지 하나를 사용자 단계(step) 하나로 감싼다.

- 앞에 `<USER_REQUEST>\n`(15 바이트)를 붙인다.
- 뒤에 `\n</USER_REQUEST>` 와 자기 메타데이터(현재 시각, 모델 선택 알림)를 붙인다. CLI 에서는 403~405 바이트다.
- 이 단계가 192,000 바이트를 넘으면 앞 192,000 바이트만 남긴다. 나머지는 `\n<truncated N bytes>\n\nNOTE: The output was truncated …` 표시로 바뀐다. N 이 일곱 자리면 표시는 161 바이트다.
- 결과는 성공으로 온다. stream-json 에도 ACP 응답에도 잘렸다는 필드가 없다.

잰 값이다. `agy` 가 남긴 단계 기록(`transcript_full.jsonl`)의 첫 사용자 단계를 읽었다.

| 어디 | 기록 | 잘린 단계 | 잘린 자리 |
|---|---|---|---|
| ACP, 2026-11-25 실측 2건(1 절의 600만 자, 16진 채움) | host 저장소 `~/.gemini/antigravity-cli/brain/*` | 2 / 2 | 저장된 단계가 192,161 바이트(192,000 + 표시 161)에서 끝난다 |
| CLI, Keeper 기록(2026-11-19~27 에 고친 것) | `<base-path>/.masc/official-clients/antigravity/*` | 1,492 / 1,557 | 1,464건은 192,000 바이트 바로 뒤. 28건은 1~2 바이트 앞(UTF-8 글자 경계) |
| CLI, 2026-10-08 실측(#41906 본문, agy 1.3.1) | 직접 보낸 328,768 바이트 | 1 / 1 | `<truncated 137188 bytes>`. 단계 329,188 바이트 = 메시지 + 420 |

- 잘리지 않은 CLI 단계 65건 중 가장 큰 것은 190,695 바이트다.
- 2026-11-27 하루 Antigravity CLI 턴 14번 중 13번이 192KB 를 넘었다. Keeper `msx-retro-mania` 이고, 가장 큰 것은 1.9MB 다. 그 레인 `glm-coding.glm-5.3-flash` 는 Antigravity CLI 대체 후보를 20개 둔다.
- 잘림은 창 단위가 아니라 메시지 단위다. 운영자 한도가 400K 토큰이어도 메시지 하나가 192KB 를 넘으면 잘린다.
- 잘린 메시지를 받은 모델은 표시만 보고 뒤를 찾으러 자기 기록 파일을 나눠 읽는다(#41906 의 도구 반복).
- masc 는 응답만으로 이 잘림을 알 수 없다. `usage.inputTokens` 는 잘린 뒤의 양이다.

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
  - 호스트 넷 중 masc 가 띄우는 프로세스에 모든 모델의 압축 시점을 넘길 수 있는 것은 Muse Code 하나다(2026-11-26 실측).

    | 호스트 | 받는 길 | 값의 뜻 | 확인한 방법 |
    |---|---|---|---|
    | Muse Code 1.4.25 | `-c context_compaction.provider_context_limit_tokens=<토큰>` | 실효 한도. 압축은 이 한도의 `soft_threshold`(기본 0.75)와 `hard_threshold`(기본 0.9)에서 한다. 두 비율도 `-c` 로 받는다 | masc 가 만드는 인자로 `muse acp`(muse-spark-1.3)를 띄워 한도 60,000, soft 0.95, hard 1.0 을 줬다. 압축 후보에 `soft=0.9500;hard=1.0000`, 57,000·60,000 토큰이 찍혔다. 한 턴에서 파일을 읽어 커지자 57,101 에서 비동기 압축을 시작했고, 약 65,000 에서 턴 도중 막고 압축해 약 32,000 으로 줄였다. 요청 세 건은 60,330 까지 갔다. 호스트 추정이 provider 가 센 값보다 조금 작다. 기본값은 거부 메시지에서 읽었다. hard 없이 soft 0.95 만 주면 exit 3 이다 |
    | Antigravity 1.5.18 | ACP 에는 없다. 환경 변수 `AGY_CLI_AUTO_COMPACT_OVERRIDE` 는 대화형 클라이언트만 읽는다 | 대화형 클라이언트에서는 압축 시점. 없으면 「server default」 | 30000 을 주면 대화형 `/context` 에 `Auto-compact at 30.0k tokens (overridden by AGY_CLI_AUTO_COMPACT_OVERRIDE=30000)` 가 나온다. 같은 변수로 띄운 `agy acp` 세션은 두 프롬프트 동안 `usage_update.used` 가 14,709 에서 51,026 까지 한 번도 줄지 않았다. 바이너리에서 이 변수를 읽는 함수는 대화형 화면 쪽 `store.AutoCompactOverride` 에만 있다 |
    | Mistral Vibe 3.1.0 | 모든 모델에는 없다 | `VIBE_AUTO_COMPACT_THRESHOLD` 는 자기 값이 없는 모델만 채운다 | vibe 자신의 설정 loader 로 실제 값을 읽었다. 모델 catalog 가 mistral-large-4-0-3 에 자기 값 400,000 을 준다. 변수를 380000 으로 주면 이 모델은 400000 그대로이고, 자기 값이 없는 mistral-medium-3.5 만 380000 이 된다. 모델별 값(`VIBE_MODELS__<모델>__AUTO_COMPACT_THRESHOLD`)은 environment 층이 읽지 못한다며 버린다. 값은 50,000 부터 창 − 24,000 까지만 받는다. 범위 밖이면 그 모델로 바꾸는 `session/set_config_option` 을 거절한다(medium-3.5 에 20000: `outside 50000..238144 for a 262144-token context window`). `usage_update.size` 로는 모델 창이 아니라 이 압축 값을 알린다(large-4 400,000, medium-3.5 에 50000 을 주면 50,000) |
    | Kimi Code 2.7.2 | 프로세스마다는 없다. 운영자의 kimi 설정 파일 `[models."<alias>".overrides]` 의 `max_input_size` | 압축 한도. 압축은 `0.85 × (max_input_size, 없으면 max_context_size)` 에서 하고 `창 − 50,000` 을 넘지 않는다. 창이 1,048,576 이면 891,289 다 | 설치된 2.7.2 바이너리에서 읽었다: 압축 한도 `maxInputSize ?? maxContextSize`, `DEFAULT_COMPACTION_CONFIG` 의 triggerRatio·blockRatio 0.85 와 reservedContextSize 50,000. managed 모델을 새로 받을 때도 `overrides` 를 남긴다(`mergeRefreshedModelAlias`). 별칭 단위라 그 kimi home 의 모든 프로세스에 걸린다. 플래그와 환경 변수는 없다. `KIMI_MODEL_MAX_CONTEXT_SIZE` 는 `KIMI_MODEL_NAME` 의 환경 변수 provider 일 때만 읽는다. 실제 압축은 보지 못했다 |

  - Codex 는 ACP driver 가 아니지만 `-c model_context_window=<tokens>` 를 받는다(`runtime_codex_app_server.ml` 의 `client_argv`).
  - 운영자가 쓸 수 있는 값은 모델별 `context-rollover-threshold`(#54873)다. 낮추면 한 턴이 커질 자리가 생긴다. 한 턴이 커지는 양을 막지는 못한다.
  - 넘친 세션은 숨지 않는다. 서버 projection 이 `context_tokens_exceed_window` 로 내보낸다. TUI 는 「창 초과」, Dashboard 는 warning(「보고된 입력 토큰이 창 크기를 초과함」)으로 보여 준다.
  - 턴 도중에 `session/cancel` 로 끊지 않는다. 넘침은 durable truth 를 망가뜨리지 않는다. 끊으면 하던 턴의 일을 버린다.
  - 결정(운영자, 2026-11-26): 모델 키 `agent-compaction-threshold`(열린 구간 (0, 1))를 둔다. 세션을 띄울 때 `agent-compaction-threshold × max-context` 를 호스트에 넘긴다(#54915).
    - 턴 끝 롤오버(`context-rollover-threshold`)와 따로 정한다. 예: 롤오버 0.80, 호스트 압축 0.95.
    - 키가 없으면 호스트 기본값 그대로다.
    - driver profile 의 `compaction_point` 가 호스트마다 받는 길을 가진다. Muse Code 는 `provider_context_limit_tokens` 에 한도, `soft_threshold` 에 비율, `hard_threshold` 에 1.0 을 받는다. soft 는 hard(설정하지 않으면 0.9)보다 반드시 작아야 해서 hard 를 같이 넘긴다.
    - Antigravity, Kimi Code, Mistral Vibe 는 masc 가 프로세스마다 모든 모델에 넘길 길이 없다. 이 키를 적으면 그 binding 을 load 에서 이유와 함께 뺀다. 넘겨도 말없이 무시될 수 있기 때문이다.
    - Muse Code 는 압축할 때 사용자 메시지를 줄이지 않는다. 사용자 메시지만으로 hard 지점에 닿으면 후보를 버리고(`unfit_install_floor`) 한도를 넘긴 채 요청을 보낸다. 이 경우는 턴 끝 롤오버가 맡는다.
    - 압축한 뒤에도 그 턴의 작업이 한도에 다 안 들어가면 Muse Code 는 같은 턴에서 압축을 되풀이한다. 위 실측은 시스템 프롬프트 약 22,500 과 파일 약 45,000 이 한도 60,000 을 넘어, 한 턴에 압축 13번, 모델 호출 55번이 났다.
    - Kimi Code 의 압축 시점은 운영자가 kimi 설정 파일의 `max_input_size` 로 정할 수 있다. 그 kimi home 을 쓰는 모든 프로세스에 걸린다. 레인마다 따로 두려면 레인별 `KIMI_CODE_HOME` 과 재로그인이 들고, 운영자는 그대로 두기로 했다(2026-11-26).
  - 턴 도중 압축 감지(#54911): ACP client 가 prompt 결과에 `context_compaction` 을 돌려준다. 값은 `Not_compacted`, `Compacted`, `Compaction_unknown` 셋이다.
    - Muse Code 는 journal 의 `context_compaction_installed` 기록으로 판단한다.
    - 다른 호스트는 prompt 도중 `usage_update.used` 가 바로 앞 값보다 작아진 것으로 판단한다. 첫 값은 세션의 마지막 값과 비교한다. 0 은 비교에서 뺀다.
    - Kimi Code 2.7.3 은 `usage_update` 를 prompt 마다 한 번, 응답 직후에만 보낸다. 압축한 뒤 같은 턴에서 직전 턴 끝 값보다 커지면 값 비교로는 놓친다.
      - 2026-11-27 01:51 KST 에 실제로 놓쳤다. uncle 세션이 압축했는데 02:07 정산이 held_context 34건을 그대로 뒀다.
      - 그래서 kimi 는 세션 기록도 읽는다. 위치는 `<KIMI_CODE_HOME, 없으면 ~/.kimi-code>/sessions/<작업 폴더>/<세션 id>/agents/main/wire.jsonl` 이다.
      - prompt 를 보내기 전 파일 길이를 재 두고, 끝난 뒤 그 뒤에 쓰인 `full_compaction.begin` 과 `context.apply_compaction` 기록을 센다.
      - 시작한 기록과 끝난 기록을 둘 다 센다. kimi 설정의 `compaction_trigger_ratio` 가 0.85 보다 작으면 kimi 는 압축을 기다리지 않고 턴을 끝낸다. 그러면 끝난 기록이 응답 뒤에 써져 다음 prompt 에서 읽힌다. 늦게 적용된 압축이 다음 prompt 의 입력까지 요약하는지는 확인하지 못했으므로, 두 prompt 모두 압축으로 본다. 시작했다가 실패한 압축도 센다. 그 비용은 World State 를 한 번 더 보내는 것뿐이다.
      - 같은 세션의 다음 prompt 는 직전에 센 곳에서 이어 센다. 실패하거나 취소된 prompt 동안 생긴 압축도 다음 prompt 에서 센다.
      - 첫 줄 `metadata` 의 `protocol_version` 이 확인한 1.5 가 아니면 읽지 않는다.
    - 기록을 못 읽으면 `Compaction_unknown` 이다. 세션이 요약만 들고 있을 수 있으니 정산은 압축으로 보고 World State 를 다시 보낸다. 경고 로그에 이유가 남는다. Muse journal 을 못 읽을 때도 같다.
    - 호스트가 턴을 멈춘 경우(`Terminal_tool_boundary`)도 정산은 같은 규칙을 따른다. 멈추기 전에 prompt 가 압축 판정과 함께 돌아왔으면 그 결과로 판단한다. 돌아오지 않았거나 오류로 돌아왔으면 압축을 셀 수 없으므로 압축으로 보고 World State 를 다시 보낸다.
    - Gate pause 로 세션을 남길 때는 멈춘 prompt 의 사용량 값을 그 세션의 마지막 값으로 둔다. 다음 prompt 는 첫 값을 그 값과 비교한다. 멈춘 prompt 가 값을 싣지 않았으면 비교할 값이 없으므로, 다음 prompt 에서 줄어든 값을 보지 못해도 압축으로 보고 World State 를 다시 보낸다. 2026-11-25~27 kimi Keeper 턴 287번 중 취소로 끝난 턴은 21번이다.
    - Mistral Vibe 실측(2026-11-26, medium-3.5, 압축 값 50,000): 한 턴에 파일 여덟 개를 읽어 `used` 가 8,829 에서 70,944 가 됐다. 그 턴 안에서는 압축하지 않았다. 다음 prompt 를 시작할 때 「Compacting context」 tool_call 을 보내고 `used` 를 0, 그다음 8,939 로 알렸다. 0 을 뺀 값이 70,944 에서 8,939 로 줄어 감지된다.
    - 그 전에는 턴 끝 값끼리만 비교해서 턴 안에서 압축한 뒤 다시 커지면 놓쳤다. 로컬 Muse journal 의 압축 83건 중 `mid_turn` 이 25건, `pre_turn` 이 19건이다.
- 에이전트 창과 운영자 한도: 세션을 열 때 에이전트가 알리는 `usage_update.size` 보다 운영자 한도가 크면 typed 설정 오류로 그 후보를 쓰지 않는다. 운영자 한도가 에이전트 창 안에 있어도 Antigravity 는 메시지 하나가 192,000 바이트를 넘으면 자른다(3.3). 이 잘림은 4.3 이 보내기 전에 막는다.
- ledger 가 없을 때(새 Keeper history, 또는 재기동 뒤 ledger 가 비었을 때): 저장된 마지막 응답 범위(`Keeper_carried_front.read_seed`)에서 시작한다. 그것도 없으면 마지막 완료 턴의 끝(`turn_start`)에서 시작한다. Agent Core 가 ledger 없이 시작하는 자리와 같다(RFC keeper-context-window-in-tokens §13.4).
- typed 넘침: `Retry.classify_structured_json` 이 이미 하는 일이다. 새 분류를 더하지 않는다. 거절 문장은 읽지 않는다.
- 거절된 범위의 이동은 #54733 의 runtime 별 거절 기록을 그대로 쓴다.

이 절은 ACP driver 넷(Antigravity, Kimi Code, Mistral Vibe, Muse Code)에 같이 적용된다. 크기 규칙이 driver 마다 다르면 이 RFC 가 없애려는 갈림이 다시 생긴다.

### 4.3 Antigravity 는 너무 큰 메시지를 보내기 전에 거절한다

4.2 의 규칙은 창(토큰)을 다룬다. 3.3 의 잘림은 창이 아니라 `agy` 가 메시지 하나를 받는 자리에서 생긴다. 그래서 이 절은 창 규칙과 따로 간다. 이 사실은 ACP driver profile 에 적는다. 호스트마다 다른 사실(시스템 프롬프트 길, 압축 지점)을 이미 그곳에 적는다.

| 부품 | 내용 |
|---|---|
| 한도 | `Runtime_acp_client.antigravity_message_max_bytes` = 191,579. `agy` 가 남기는 192,000 바이트에서 감싸는 부분 420(앞 15, 뒤 405: 잰 값 중 가장 큰 것)과 1 을 뺐다. 이 크기 이하면 단계가 191,999 바이트를 넘지 않아 아무것도 잘리지 않는다. |
| 재는 것 | MASC 가 보내는 메시지 하나의 바이트 수. CLI 는 stdin 에 쓰는 프롬프트 전체다. ACP 는 `session/prompt` 한 번에 실린 text 블록의 합이다. |
| 거절하는 곳 | CLI: `Runtime_antigravity.validate_turn`. 프로세스를 띄우기 전이다. ACP: `Runtime_acp_client.validate_prompt_blocks`. `session/prompt` 를 보내기 전이다. 둘 다 `Message_over_client_limit { message_bytes; max_bytes }` 로 거절한다. |
| 적용 범위 | ACP driver profile 의 새 칸 `message_limit`. Antigravity 는 `Keeps_messages_through { max_bytes }` 다. Kimi Code, Mistral Vibe, Muse Code 는 `Message_limit_not_measured` 다. 재지 않은 호스트는 거절하지 않는다. CLI driver 는 ACP profile 의 Antigravity 값을 같이 읽는다. |

왜 토큰이 아니라 바이트인가:
- `agy` 는 모델과 tokenizer 가 보기 전에 바이트로 자른다.
- 같은 192,000 바이트가 몇 토큰인지는 내용마다 다르다. 1 절의 영어 채움에서는 57,335 토큰이었다. 토큰 한도로는 잘림이 생길지 알 수 없다.
- 그래서 RFC keeper-context-window-in-tokens §1 의 2(「바이트 상한을 두지 않는다」)와 2026-10-06 결정(Antigravity 는 바이트로 자르거나 거절하지 않는다)을 이 driver 에서만 대신한다. 두 결정 모두 창을 다룬다. 여기 한도는 provider 의 hard limit 이라 constitution `budget_gate` 의 예외에 든다.
- 범위를 바이트로 잘라 보내지는 않는다. 넘으면 거절하고 다른 후보로 간다.

거절한 뒤 일어나는 일:
- Keeper 턴: `Agent_core.Error.Api (InvalidRequest { reason = Attempt_rejected })` 로 올린다. Claude Code 의 턴 전 검사 실패(#47787)와 같은 모양이다.
  - `Candidate_fault.Binding Admission` 이라 레인이 다음 후보로 간다(`attempt_rejected_should_try_next`).
  - 실패 경로는 `rotate Admission` 이고, 보낸 기록은 `Rejected_before_dispatch` 다.
  - 크기 거절(`is_size_refusal`)이 아니다. 같은 후보에 범위를 줄여 다시 보내지 않는다. `refused_model_input` 도 남지 않아 다음 턴의 범위가 옮겨지지 않는다.
  - CLI Keeper 턴은 세션 claim 전에 거절한다. ACP Keeper 턴은 세션을 `active`·`turn starting` 으로 적기 전에 거절하고, claim 은 `Pre_dispatch_failed` 로 놓는다.
- exact 레인(Librarian 등): 그 슬롯의 실패로 남고 다음 슬롯으로 간다. `refused_for_binding_rest` 는 `false` 다.
- Fusion 패널: 그 패널의 실패로 남는다.
- 계정: 쉬게 하지 않는다. quota window, backpressure, candidate standing 에 아무것도 남기지 않는다. 계정이 아니라 메시지 크기 탓이다.
- 레인의 모든 후보가 거절하면 다른 실패처럼 턴이 끝난다. 그 Keeper 의 메시지를 줄이는 일은 이 RFC 범위 밖이다(#41408).

확인하지 못한 것:
- ACP 시스템 프롬프트 길(`_meta.antigravity.systemPrompt.append`)에도 같은 한도가 있는지 재지 않았다. 지금은 세지 않는다.
- 이미지 블록이 이 한도에 드는지 재지 않았다. 지금은 text 블록만 센다.
- ACP 에서 `agy` 가 메시지 뒤에 붙이는 것은 CLI 보다 길 수 있다. host 저장소의 대화형 단계에는 skill·plan 블록이 붙어 1,130~21,202 바이트인 것이 있었다. 그러면 메시지는 다 들어가도 뒤의 메타데이터가 잘리고 표시가 붙는다.
- 단계가 정확히 192,000 바이트일 때 잘리는지는 재지 않았다. 한도는 그 1 바이트 앞에서 멈춘다.
- `agy` 버전이 바뀌면 한도가 바뀔 수 있다. 1.3.1(2026-10-08)과 1.5.x(2026-11-25~27)에서는 같았다.

## 5. 단계

각 단계는 따로 PR 이다. 앞 단계의 측정이 통과해야 다음으로 간다.

| 단계 | 할 일 | 확인 |
|---|---|---|
| 0 | 4.2 를 구현한다. 한도 선언 필수, ledger 기록, `input_limit_of_runtime` 의 `Acp` 갈래, 에이전트 창 검사. | 시험: 선언 없는 ACP runtime 은 설정 검사에서 거부. 첫 prompt 의 `usage.inputTokens` 가 ledger 에 범위와 함께 남음. 한도를 넘는 ledger 면 다음 seed 가 `past_max_context` 대로 옮겨짐. `usage_update.size` < 운영자 한도면 typed 오류. |
| 1 | 3.2 의 두 차단 사유를 현재 운영 빌드로 다시 잰다. Keeper 하나(리뷰어 1명)를 `antigravity_acp` 레인으로 옮긴다. | MCP 도구 호출 10회 이상 성공, 권한 거부 0회. `session/set_config_option` 뒤 `configOptions[model].currentValue` 가 설정한 모델과 같다. 쿼터 거절 수락 조건 Q1. |
| 2 | 하루 측정. 같은 Keeper 의 11-24 CLI 레인 기록과 비교한다. | 턴 성공률, 턴당 입력 토큰, 실패 종류(`turn_records`·`agent-core-events`). CLI 대비 성공률이 낮으면 멈추고 원인을 기록한다. 쿼터 거절 수락 조건 Q3. |
| 3 | 나머지 5명을 옮긴다. CLI 레인 후보는 설정에서 뺀다. | 3일 동안 CLI 레인 호출 0회. |
| 4 | CLI 레인 코드와 provider 종류를 지운다. | type-check, 관련 테스트(`test_runtime_acp_client` 등) 통과. `rg 'antigravity_cli\|Runtime_antigravity\b'` 결과가 지운 목록과 맞다. 쿼터 거절 수락 조건 Q2 를 지킨다. |

4.3 은 이 단계들과 따로 간다. 1 단계 전에 들어가도 된다.

쿼터 거절 뒤 쉬기 — 수락 조건(운영자, 2026-11-27, #41425):
- Q1. 1 단계에서 `agy acp` 의 쿼터 거절 한 건을 받아 JSON-RPC `code` 와 `data` 를 그대로 기록한다. 지금 ACP 레인은 `error.data` 의 구조 필드로만 쿼터를 가른다(`Retry.classify_structured_json`). 문장뿐이면 쉬지 않는다. `agy acp` 의 거절 모양은 아직 아무도 재지 않았다.
- Q2. Q1 의 `data` 에 구조가 없으면 `Runtime_antigravity_usage` 리더를 4 단계에서 지우지 않는다. 대신 ACP Antigravity 를 `Runtime_provider_usage_read.how_of_runtime` 에 잇는다. 순서는 거절 → `/usage` 읽기 → `rest_on_account_refusal_read` 다. `/usage` 는 턴 없이 버킷별 구조화된 답을 준다(#41425 본문).
- Q3. 2 단계 확인에 더한다: 한 scope 가 리셋 전까지 받는 쿼터 거절은 1번을 넘지 않는다.

## 6. 정한 것과 남은 것

정한 것(운영자, 2026-11-25):
- 잘라 읽기는 보내기 전에 막는다. 크기는 4.2 의 규칙으로 정한다. 받은 뒤 문장이나 추정으로 고치지 않는다.
- Antigravity 한도(quota) 표시: CLI 레인은 `Runtime_antigravity_usage` 로 한도 창을 읽는다. ACP 레인에서 같은 값을 얻을 길이 있는지 1 단계에서 확인한다. 없으면 TUI·Dashboard 에 「미보고」로 둔다. 추정해서 채우지 않는다.
- 계정 여러 개: 두 길 모두 계정 home 이 없어 지금과 같다. 바꾸지 않는다.

- 운영 `runtime.toml` 의 ACP runtime 17개는 모두 `max-context` 를 선언했다(2026-11-25 확인: `antigravity_acp` 9개, `kimi_acp` 6개, `vibe_acp` 2개). 기본값을 지워도 막히는 runtime 은 없다.
- 1 단계로 옮기는 Keeper 의 후보는 지금 CLI 레인과 같은 400K 선언을 쓴다(`antigravity-gemini-4-neon-medium-400k` 와 같은 값). `antigravity_acp` 의 기존 선언 1,048,576 은 에이전트 창 크기와 같아서, 비교 기준이 CLI 레인과 달라진다.

정한 것(운영자, 2026-11-27):
- 「잘라 읽기는 보내기 전에 막는다」에는 창 넘침뿐 아니라 3.3 의 메시지 잘림도 든다. 4.3 의 typed 사전 거절이 그 방법이다(#41906). RFC keeper-context-window-in-tokens 의 「바이트 상한을 두지 않는다」를 Antigravity driver 에서만 일부 뒤집는다. 운영자가 그 충돌을 알고 골랐다.
- CLI 대체 후보를 레인에서 빼는 일은 운영자가 직접 한다. 이 RFC 의 구현은 `<base-path>/.masc` 의 레인·설정을 고치지 않는다.
- 쿼터 거절 뒤 쉬기는 5 절의 Q1~Q3 를 수락 조건으로 둔다(#41425).

남은 것(열린 질문):
- 쿼터 거절 뒤 무엇을 쉬게 하나: 계정 전체인가, 모델 그룹인가. 운영자가 더 생각해 보고 정한다. 판단에 쓸 측정값이다.
  - 2026-11-20~27 에 쿼터 거절이 난 시간대는 32개다. 29개는 한 모델 그룹만 거절됐고, 3개(11-20 13~15Z)만 두 그룹이 같이 거절됐다.
  - 거절 줄 수는 Claude 그룹 541, Gemini 그룹 752 다.
  - 계정 단위로 쉬면 대부분의 시간에 아직 남은 그룹까지 막힌다.
  - 그룹 단위로 쉬려면 runtime TOML 에 그 모델이 쓰는 `/usage` 버킷 id 칸이 새로 있어야 한다. `/usage` 는 그룹 소속을 설명 문장으로만 주기 때문이다.

## 7. 하지 않는 것

- CLI 레인의 넘침 분류(#54717)를 따로 고치지 않는다. 4 단계에서 코드째 사라진다.
- 다른 ACP driver 의 동작은 4.2 의 크기 규칙 밖에서는 바꾸지 않는다. 4.3 의 메시지 한도는 Antigravity 에만 건다.
- 옛 설정 변환기, CLI 레인 호환 계층을 만들지 않는다.
- 큰 메시지를 바이트로 잘라 보내지 않는다. 거절하고 다음 후보로 간다.
- 쿼터 거절 뒤 쉬는 단위(계정·모델 그룹)를 이 RFC 에서 정하지 않는다.

## 8. 시험

- 4.3: CLI driver 와 ACP driver 각각에 대해, 한도를 1 바이트 넘는 메시지는 보내기 전에 거절되고 레인이 다음 후보로 간다. 한도와 같은 크기의 메시지는 지나간다. 거절 뒤 계정 쉬기 기록(quota window)이 없다. 재지 않은 호스트(Kimi Code 등)는 같은 크기를 거절하지 않는다.
- 1·2 단계: 운영 측정이 시험이다. 수치는 PR 본문과 #54717 댓글에 남긴다.
- 4 단계: 지운 모듈을 부르던 테스트는 같이 지운다. ACP Antigravity 의 넘침 분류는 `packages/agent_core/test/test_retry` 와 `test/test_runtime_acp_client` 가 다룬다. 빠진 경우가 있으면 더한다.
