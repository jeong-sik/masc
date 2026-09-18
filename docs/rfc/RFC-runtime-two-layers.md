---
rfc: "runtime-two-layers"
title: "런타임 설정을 두 층으로 — 카탈로그는 무엇인지 말하고, 배포는 무엇을 쓰는지만 말한다"
status: Draft
created: 2026-09-18
updated: 2026-09-18
author: vincent
supersedes: []
superseded_by: null
related: ["0206", "0342", "AC-040"]
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

**주소가 두 곳.** 9개 provider 중 6개가 카탈로그와 `runtime.toml` 양쪽에 선언돼 있다. 철자만 다르다 — `endpoint`/`protocol` 대 `base_url`/`kind`.

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

## 열린 질문

1. **`enable-thinking` 의 집**: 지금은 `[models.X] thinking-support` 에서 슬롯의 `enable_thinking` 이 파생된다. 바인딩 키로 올리면 되지만, "모델이 생각을 지원하는가"(카탈로그)와 "이 슬롯에서 켤 것인가"(배포)가 한 이름을 쓰고 있어 분리해야 한다.
2. **`[providers.X]` 의 `protocol`**: 카탈로그 `kind` 와 같은 사실이다. 배포가 적을 이유가 없어 보이는데, CLI provider(`claude_code`, `codex`)는 카탈로그에 행이 없다. 그쪽을 어떻게 다룰지 정해야 한다.
3. **`identity_kinds` 선택**: 한 provider 가 두 wire 를 겸할 때 배포가 어느 쪽을 쓰는지 말할 자리가 필요하다. 지금은 `request_path` 로 암묵적으로 갈린다.

## 근거

- 층 계수와 섹션 계수: `config/runtime.toml` @ `45b4db68a9`
- 능력 통로 분해: `runtime_adapter.ml:411/440/478`, `provider_config.ml:213`, `runtime_agent.ml:743`
- wire 별 `tool_choice`: `backend_ollama.ml:27` (`No [tool_choice] support`) 대 `backend_openai.ml` 52곳
- 상한 없는 대기: #36979 (timeout 미설정 provider 7/10, curator 최대 13.3h, failover 미발동)
- 요청마다 거절: #37004 (librarian_exact 94회 `missing_deadline`)
- 배포 overlay 제거: #37016
