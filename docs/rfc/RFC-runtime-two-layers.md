---
rfc: "runtime-two-layers"
title: "런타임 설정을 두 층으로 — 카탈로그는 무엇인지 말하고, 배포는 무엇을 쓰는지만 말한다"
status: Draft
created: 2026-09-18
updated: 2026-09-18
author: vincent
supersedes: []
superseded_by: null
related: ["0206", "0342", "AC-040", "one-provider-two-wires", "0390"]
implementation_prs: []
---

# RFC: 런타임 설정을 두 층으로

## 문제

레인이 모델 하나를 쓰려면 지금 **일곱 겹**을 지나야 한다.

```
1  레인 슬롯                        지어낸 로컬 id
2  [models.<local>]                 api-name 별칭 + 운용값
3  [models.<local>.capabilities]    능력 (두 번째 권위)
4  [<provider>.<local>]             바인딩 운용값
5  [providers.<id>]                 주소·자격증명·deadline
6  카탈로그 [[providers]]             주소(또) + wire 사실
7  카탈로그 [[models]]                모델 사실
```

없어서는 안 될 것은 넷이다. **무엇인가**(6·7), **어디로 어떤 열쇠로**(5), **어떤 쌍을 쓰는가**(4), **어떤 순서로**(1). 나머지 셋은 쌓인 것이다.

### 실측 (2026-09-18, `config/runtime.toml` 1,469줄)

| | 개수 |
|---|---|
| `[models.<local>]` 블록 | 43 |
| `[models.<local>.capabilities]` 블록 | 27 |
| 바인딩 | 51 |
| provider | 9 |
| 레인 | 4 |
| provider 가 카탈로그에도 선언된 경우 | **6 / 9** |
| 카탈로그 모델 행 | 201 (그중 40개 모델 id 가 2개 이상 provider 로 갈림) |

`glm-5.3` 하나를 예로 들면 로컬 이름이 **4개**(`glm-5-3`, `ollama-cloud-glm-5-3`, `ollama-cloud-glm-5-3-flash`, `openrouter-glm-5-3`)이고 `runtime.toml` 섹션이 **13개**다.

**모델 1개 × provider 1개 = 4곳**을 건드린다. 카탈로그 행, `[models.X]`, `[models.X.capabilities]`, 바인딩.

## 이 층들이 실제로 무엇을 깨뜨렸나

층이 많아서 불편한 것이 아니라, **같은 사실이 여러 곳에 적히고 어느 쪽이 이기는지 배포자가 알 수 없다.**

**주소가 두 곳.** 9개 provider 중 6개가 카탈로그와 `runtime.toml` 양쪽에 주소를 갖는다 — `endpoint` 대 `base_url`. 이건 같은 사실이다.

`protocol` 과 `kind` 는 다르다. 초안에서 같은 사실이라고 적었는데 **틀렸다.** 6개를 하나씩 대조하면 4개만 겹치고 2개는 서로 다른 것을 말한다.

| provider | `protocol` (배포) | `kind` (카탈로그) | |
|---|---|---|---|
| deepseek · kimi_coding · openrouter | `openai-compatible-http` | `openai_compat` | 겹침 |
| ollama | `ollama-http` | `ollama` | 겹침 |
| **glm-coding** | `openai-compatible-http` | **`glm`** | 모양은 OpenAI 호환, 방언은 GLM |
| **ollama_cloud** | `openai-compatible-http` | `ollama` (+`openai_compat`) | `protocol` 이 두 wire 중 하나를 고른다 |

`protocol` 은 **요청 모양**이고 `kind` 는 **벤더 방언**이다. 둘은 서로를 결정하지 않는다. `ollama_cloud` 에서는 `protocol` 이 곧 wire 선택이고, 그건 `RFC-one-provider-two-wires` §4.3 이 구현한 `runtime_adapter.ml:244-248` 이 하는 일이다. 그러므로 이 RFC 는 `protocol` 을 없애지 않는다.

**자격증명이 두 곳.** `runtime.toml` 은 `glm-coding` 이 `ZAI_API_KEY` 를 읽는다고 하고, 카탈로그는 `ZAI_CODING_API_KEY` 라고 한다. 지금은 카탈로그가 이긴다. 삭제된 배포 overlay 는 `glm-coding-exact` 라는 가짜 provider 행을 만들어 env 이름만 덮어쓰는 방식으로 이걸 우회하고 있었다.

**능력이 두 곳, 그런데 필드마다 통로가 다르다.** `[models.X.capabilities]` 125키를 추적한 결과:

| 통로 | 건수 |
|---|---|
| `model_capabilities_override` (카탈로그 행이 있으면 3필드만) | 33 |
| `supports_tool_choice_override` — 별도 인자, 카탈로그를 이김 | 25 |
| `input_capabilities_of_runtime` — 미디어, 조건 없이 적용 | 50 |
| 나머지 | 17 |

같은 블록 안의 키들이 서로 다른 경로로 흐르고, 일부는 카탈로그를 이기고 일부는 진다. `runtime_agent.ml` 주석은 `Runtime model specs are the MASC SSOT for concrete media input support` 라고 선언하지만 `provider_config.ml` 은 카탈로그를 권위로 삼는다. **한 파일 안에서 답이 갈린다.**

**한 블록이 두 provider 를 섬긴다.** `deepseek-v4-flash` 는 `ollama_cloud` 와 `deepseek` 양쪽에 바인딩돼 있는데 `[models.deepseek-v4-flash]` 블록은 하나다. `supports_tool_choice` 는 wire 에 따라 다르다 — `backend_ollama.ml` 은 `No tool_choice support` 라고 적어두고 직렬화하지 않으며, OpenAI 백엔드는 52곳에서 쓴다. 값을 하나만 적을 수 있으니 **두 소비자 중 하나에게는 반드시 틀린다.** 카탈로그는 provider 별 행으로 이걸 정확히 표현한다(`ollama_cloud` 39행 전부 `false`).

## 설계

두 파일만 남는다.

### 1층 — `packages/agent_core/models.toml` (백과사전, 우리가 배포)

무엇인지만 적는다. 배포자는 읽고, 필요하면 행을 더한다.

```toml
[[providers]]
id = "glm-coding"
kind = "glm"
base_url = "https://api.z.ai/api/coding/paas/v4"   # 기본 주소
request_path = "/chat/completions"
api_key_env = "ZAI_CODING_API_KEY"                 # 기본 env 이름
capabilities_base = "glm"

[[models]]
id_prefix = "glm-5.3"
provider_name = "glm-coding"
max_context_tokens = 1048576
supports_tools = true
supports_image_input = false
# … 능력 사실 전부. provider 별로 다르면 provider_name 으로 갈라 적는다.
```

능력은 **여기에만** 적는다. provider 마다 다른 사실은 `provider_name` 으로, 한 provider 가 두 wire 를 겸하면 `capabilities_base_by_identity_kind` 로 가른다. 이미 201행 중 40개 모델이 그렇게 갈려 있다.

### 2층 — 배포의 `runtime.toml` (이 배포)

무엇을 쓰는지만 적는다. 무엇인지는 적지 않는다.

```toml
[providers.glm-coding]
endpoint = "https://api.z.ai/api/coding/paas/v4"   # 생략하면 카탈로그 base_url
credentials = { type = "env", key = "ZAI_API_KEY" }
connect-timeout-s = 180.0                          # 필수 (아래 참조)
max-concurrent = 4

["glm-coding.glm-5.3"]                             # 바인딩 키 = provider.실제모델명
max-context = 250000                               # 낮추기만 가능
reasoning-effort = "high"
enable-thinking = false

[runtime]
default = "glm-coding.glm-5.3"

[runtime.lanes.librarian_exact]
slots = ["glm-coding.glm-5.3", "ollama_cloud.deepseek-v4.1-flash"]

[runtime.assignments]
goo-yang-bong = "librarian_exact"
```

**바인딩 키가 곧 이름이다.** 로컬 별칭이 없고, 레인은 실제 provider·모델 이름을 적는다.

### 사라지는 것

| | 근거 |
|---|---|
| `[models.<local>]` 43블록 | `api-name` 별칭층. 바인딩 키가 대신한다 |
| `[models.<local>.capabilities]` 27블록 | 능력은 카탈로그 한 곳 |
| 지어낸 로컬 이름 | `glm-5.3` 만 4개였다 |
| provider 주소·자격증명 이중 선언 | 카탈로그가 기본, 배포가 덮는다. 한 방향 |

**모델 1개 × provider 1개 = 4곳 → 2곳** (카탈로그 행 + 바인딩). 카탈로그에 이미 있으면 **1곳**.

### 옮겨가는 것

`[models.X.capabilities]` 가 실제로 쓰이던 두 묶음은 카탈로그로 간다.

- **미디어 50건** (`supports-image-input`·`supports-multimodal-inputs`·`supports-audio-input`) — 카탈로그 행에 `provider_name` 으로 적는다. 지금 runtime 이 SSOT 인 이유는 배포마다 다르기 때문이 아니라 카탈로그에 그 행이 없어서였다.
- **`supports-tool-choice` 25건** — wire 별 사실이므로 `capabilities_base_by_identity_kind` 가 답한다. 한 블록이 두 provider 를 섬기던 문제가 여기서 사라진다.

운용값(`temperature`·`max-output-tokens`·`reasoning-effort`·`num-ctx`·`keep-alive`·`max-concurrent`)은 전부 바인딩 한 집으로 합친다. 지금은 `[models.X]` 와 `[provider.model]` 두 집에 나뉘어 있다.

## 설정을 읽을 때 거절한다

지금은 설정이 잘못돼도 **요청할 때마다** 거절된다. librarian 은 그렇게 94번 거절당하며 몇 시간을 죽어 있었다. 배포자가 보는 자리에서 한 번 거절해야 한다.

`runtime.toml` 로드 시 거절하고 이름을 댄다.

1. 레인 슬롯이 선언된 바인딩을 가리키지 않음 → 레인·슬롯 이름을 댄다
2. 바인딩이 카탈로그의 provider·모델 쌍을 가리키지 않음 → 쌍을 댄다
3. provider 가 deadline(`connect-timeout-s` 또는 `body-timeout-s`)을 하나도 선언하지 않음 → provider 이름을 댄다. 상한 없는 요청은 실패하지 않고 기다리기만 해서 failover 가 뛰지 않는다(#36979: curator 최대 13.3시간)
4. 바인딩의 `max-context` 가 카탈로그 값보다 큼 → 낮추기만 가능

`decide_capability_gate` 가 이미 이 모양인데 **프로덕션 호출자가 없다**(2026-09-18 확인). 이 RFC 는 그것을 꽂는 일을 포함한다.

## 우리가 안 싣는 모델

배포자가 로컬 모델을 돌리면 카탈로그에 행을 더한다. 소스 체크아웃이면 파일 편집이고, 설치된 바이너리면 `AGENT_CORE_MODEL_CATALOG` 로 통째 교체한다(그 경우 모든 행을 그 파일이 소유한다).

이 RFC 는 **배포 쪽 능력 선언을 없앤다.** 그 대가로 로컬 모델 등록이 카탈로그 편집이 된다. 지금도 `[models.X.capabilities]` 블록이 없으면 부팅이 거절되므로(`Option.map ... spec.capabilities` 가 `None` 을 낸다) 선언 자체는 이미 의무였고, 장소만 바뀐다.

## Hard cut

호환 reader·converter·migration 코드를 만들지 않는다. 옛 모양의 `runtime.toml` 은 로드 시 거절하고, 무엇이 달라졌는지와 새 모양을 출력한다.

`config/runtime.toml` 씨앗과 설치 마법사(`install-runtime-setup.py`, `runtime_setup_spec.ml`)를 새 모양으로 다시 쓴다.

## 하지 않는 것

- 레인 선택 알고리즘, failover 순서 규칙은 건드리지 않는다
- keeper 배정 의미는 그대로다
- 카탈로그의 능력 필드 집합은 이 RFC 에서 늘리지 않는다 — 옮기기만 한다

## 이미 답이 난 것

초안에서 열린 질문으로 적었던 셋 중 둘은 기록이 있다.

**`enable-thinking` 의 집 — 답: 갈라져 있고, 갈린 곳이 맞다.**
PR #36985(머지)가 정리했다. "끌 수 있는가"는 wire 가 아니라 **모델·표면의 성질**이고 — Grok 은 `reasoning cannot be disabled`, Kimi k3·k2.7-code 는 `thinking.type` 이 `"enabled"` 만, GLM-5.3 은 `can only be enabled`(전부 공식 문서, 2026-09-18 확인, 표면별 사실은 #36990) — 그 판정은 `Complete_common.validate_all` 하나가 답한다. 실제 요청이 통과하는 관문이 거기다.

따라서 카탈로그가 `accepted_reasoning_efforts` 와 `thinking_control_format` 으로 "끌 수 있는가"를 말하고, 바인딩은 "이 슬롯에서 끌 것인가"만 말한다. 이 RFC 는 그 분리를 만드는 게 아니라 **이름만 정리한다** — 지금 `[models.X] thinking-support` 라는 한 이름이 두 질문에 걸쳐 있다.

남은 진짜 구멍은 #36989 이다: **"끄기를 받지만 지키지 않는다"를 표현할 capability 값이 없다**(MiniMax M2.x). 이 RFC 는 그 값을 추가하지 않는다.

**두 wire 겸용 provider — 답: 배포가 고르지 않는다.**
`RFC-one-provider-two-wires`(Implemented, 2026-08-27) §4.3 이 이미 구현했다. wire 는 `runtime_adapter.ml:244-248` 이 계산해서 해석에 넘긴다. 배포가 선언할 자리는 필요 없고, 카탈로그가 `capabilities_base_by_identity_kind` 로 wire 별 사실을 갈라 적는다.

그 RFC §8 "Deployment cleanup" 은 배포 overlay 의 `thinking_control_format` 덮어쓰기를 **지우라고 이미 적어두었다**. #37016 이 그 이행이다.

## 이 RFC 의 범위 — 구독 CLI 는 애초에 다른 물건이다

`claude_code`·`codex_subscription`·`antigravity_subscription` 은 카탈로그에 행이
없다. 없는 게 결함이 아니라 **타입이 갈라놓은 것**이다.

```ocaml
(* runtime_execution.mli *)
type t =
  | Agent_core of Llm_provider.Provider_config.t
  | Codex_app_server of codex_app_server
  | Antigravity_cli of antigravity_cli
  | Claude_code of claude_code
```

카탈로그는 `Llm_provider` 의 것이고, `Provider_config.t` 는 `Agent_core` 변형
**안에만** 들어 있다. `runtime.ml:21-23` 이 그 의도를 적어두었다 — official client
runtimes remain distinct and can never be dispatched as a fake LLM provider config.

같은 경계가 세 곳에서 되풀이된다.

| 갈리는 지점 | HTTP 바인딩 | 구독 CLI |
| --- | --- | --- |
| 능력 해석 (`capabilities_for_runtime`, `runtime.ml:897`) | 카탈로그가 답한다 | `None` |
| 미등록 모델 판정 (`missing_runtime_model_capabilities`, `runtime.ml:1071`) | 카탈로그에 없으면 부팅 거부 | 첫 팔에서 제외 |
| 쿼터 소유자 (`quota_scope_of_materialized`, `runtime.ml:263`) | 레지스트리 API 키 기본값까지 해석 | `Claude_code`·`Codex_app_server` 는 `None` |

셋째 줄이 구독 계정 대응이다. 주석이 이유를 적어놨다 — *Official clients own
subscription login. A registry API-key default with the same provider label is a
different account authority.* `claude_code` 라는 라벨에 API 키 기본값이 있어도 이
구독의 쿼터로 세지 않는다. 같은 이름이지만 다른 지갑이다. `antigravity_subscription`
만 `credentials` 를 그대로 쓰는데, 그건 키가 아니라 CLI 가 써둔 OAuth 토큰 파일이다.

**따라서 이 RFC 의 두 층 규칙은 `Agent_core` 바인딩에만 적용된다.** 판단이 아니라
변형 경계다. 구독 CLI 의 `[providers.X]` 는 `protocol` 과 `command` 를 계속 들고
있고, `[models.X]` 의 `api-name` 은 wire 위의 모델 이름이 아니라 CLI 플래그 값이다
(`agy --model gemini-3.7-flash-high`). 옮길 카탈로그가 없는 게 아니라, 옮길 사실이
카탈로그의 종류가 아니다.

## 구현이 밝힌 것 — 카탈로그가 모르는 endpoint

층을 걷어낸 자리에서 **줄일 수 없는 사실 하나**가 드러났다. 설치 마법사는 provider id 를
운영자 답의 해시로 만들기 때문에(`setup_vllm_<sha256>`) **어떤 카탈로그 행과도 영원히
맞지 않는다.** 그 뒤의 모델도 당연히 카탈로그에 없다.

지워진 배포 overlay 는 사실 마법사의 두 번째 출력 파일이었다
(`runtime_setup_batch.ml` 이 설치마다 `runtime.toml` 과 함께 썼다). 거기에 세 덩어리가
있었고, 두 층 설계에서 집이 각각 다르다.

| overlay 조각 | 집 |
|---|---|
| `[[targets]]` | 바인딩에서 파생한다 |
| `[[models]]` | `[models.X]` + `[models.X.capabilities]` — 표의 **존재**가 곧 배포의 보증이다 |
| `[[providers]]` 의 `kind`·`capabilities_base` | `[providers.X] kind` |

그래서 `[providers.X]` 에 `kind` 를 더한다. 카탈로그에 행이 **없을 때만** 읽고, 읽히지
않을 자리(카탈로그가 이미 답함, `protocol` 이 이미 방언을 정함, 공식 클라이언트)에
적으면 조용히 무시하지 않고 거절한다. 하나의 값이 방언·capability preset·기본 request
path 를 모두 정하므로 새 축이 생기지 않는다.

규칙은 모델 쪽과 같은 모양이다 — **카탈로그가 아는 것은 카탈로그가, 모르는 것은 배포가
말한다.**

## 남은 것

**하나. 마법사 provider 는 exact-output 타깃이 될 수 없고, 그게 설정 오류처럼 보고된다.**
구독 CLI 는 걸러냈다(엔드포인트가 없으니 타깃일 수 없다). 남은 건 마법사가 만든 HTTP
provider 다 — 카탈로그에 영원히 없으므로 `kind` 를 적어도 `Binding.resolve_exact` 가
`Provider_missing` 으로 떨어뜨리고, 거절 사유가 "카탈로그에 이 provider 가 없다"로
찍힌다. 사실은 "이 런타임은 exact output 을 하지 않는다"인데 같은 말로 보고된다.
거르려면 타깃을 만드는 자리에서 카탈로그를 봐야 하는데 그 시점엔 아직 해석 전이라,
거절 어휘를 나누는 쪽이 맞아 보인다. 이 RFC 는 그것까지 하지 않는다.

**둘. 기존 설치는 하드컷이다.**
이 계약 이전에 마법사가 쓴 연결에는 capability 표도 `kind` 도 없다. 업그레이드하면
부팅이 막힌다. 저장소 규칙대로 호환 리더나 마이그레이션 코드는 만들지 않되, 거절
문구가 무엇을 선언해야 하는지와 마법사를 다시 돌리면 써준다는 것을 말하도록 고쳤다.
운영자가 읽고 스스로 빠져나올 수 있는지는 실제로 겪어 봐야 안다.

**셋. 이름.**
`Official_client` 는 *누가 만든 앱인가*를 부르는데, 실제로 갈리는 축은 *턴을 무엇이
소유하는가*와 *어떤 계정으로 결제되는가*다. variant 이름과 20여 파일에 걸쳐 있어
리네임 비용이 이득보다 크다. 이 RFC 는 이름을 바꾸지 않는다.
