---
title: 설정 파일
description: .masc/config/*.toml 파일의 스키마와 예시입니다.
---

지속 설정은 `<base-path>/.masc/config/` 에 있습니다. 설치 스크립트가 동작하는
`runtime.toml` 을 통째로 만들어 두므로, 보통은 **처음부터 쓰기보다 만들어진 파일을
고칩니다**.

## 디렉터리 구조

```text
.masc/config/                     # `masc init` 이 쓰는 파일 271개
├── runtime.toml                  # provider 카탈로그, 모델 바인딩, [runtime].default, lane
├── agent-core-models-overlay.toml
├── prompts/                      # 25 — 역할마다 주는 글
├── tools/                        # 146 — 도구 하나당 선언 하나
├── identity/                     # 89
├── themes/                       # 6 — masc 자체 색 스킴
├── mcp/                          # 3
└── keepers/                      # 갓 설치하면 비어 있음. 일부러 그렇습니다
```

명단은 작업 공간마다 다르니 `masc init` 은 `keepers/` 를 만들기만 하고 아무것도 넣지
않습니다. 커넥터 설정(Discord, Slack)도 별도 파일이 아니라 `runtime.toml` 안의
테이블입니다(`[discord]` 등). `repositories.toml` 은 저장소를 등록하면 생깁니다.

`.env.local` 은 없습니다. 설정은 TOML 에, 자격증명은 **서버를 띄운 환경**에
있습니다 — [환경 변수](/ko/reference/env-contract/) 참고.

## 카탈로그에 처음 들어 있는 것

`runtime.toml` 은 provider 다섯을 심습니다. 넷은 서버 환경에 변수가 있어야 하고,
다섯째는 로컬입니다.

| Provider | 주소 | 변수 |
| --- | --- | --- |
| `ollama_cloud` | `ollama.com/v1` | `OLLAMA_CLOUD_API_KEY` |
| `deepseek` | `api.deepseek.com` | `DEEPSEEK_API_KEY` |
| `glm-coding` | `api.z.ai/api/coding/paas/v4` | `ZAI_API_KEY_SB` |
| `kimi_coding` | `api.kimi.com/coding/v1` | `KIMI_API_KEY` |
| `ollama` | `localhost:11434` | 없음 |

`llama_server`·`vllm`·`mlx_server` 는 주석 상태로 들어 있습니다 —
[로컬 AI 모델 연결](/ko/runbooks/llama-server/) 참고.

**시드된 바인딩은 모두 keeper-dispatchable 합니다.** 카탈로그에는 예시를 겸해 provider·모델
쌍 31개가 있고, 31개 모두 `max-request-body-bytes` 가 선언되어 부팅 경고 없이
Keeper 턴을 받을 수 있습니다. `[runtime].default` 는 31개 안에 있습니다.

## runtime.toml

`[runtime].default` 는 더 구체적인 지정이 없을 때 한 턴이 쓰는 모델입니다.
`<provider>.<model>` 쌍이고, 양쪽 다 아래에 정의돼 있어야 합니다.

```toml
[runtime]
default = "deepseek.deepseek-v4-flash"
```

**provider** 는 백엔드에 닿는 방법을 적습니다.

```toml
[providers.deepseek]
display-name = "DeepSeek API"
protocol = "openai-compatible-http"
endpoint = "https://api.deepseek.com"

[providers.deepseek.healthcheck]
path = "/models"

[providers.deepseek.credentials]
type = "env"
key = "DEEPSEEK_API_KEY"
```

**model** 은 한 번 선언하고 provider 에 **바인딩**합니다. 이 바인딩 테이블이 있어야
그 쌍을 실제로 호출할 수 있고, 바인딩마다의 한도도 여기에 붙습니다.

```toml
[models.deepseek-v4-flash]
api-name = "deepseek-v4-flash"

[deepseek.deepseek-v4-flash]
wizard-default = true
max-request-body-bytes = 1048576
```

verifier 같은 역할은 `[roles]` 테이블이 아니라, lane 에 `<provider>.<model>` 슬롯을
나열해 배정합니다.

```toml
[runtime.exact_output_lanes.verifier_exact]
slots = ["deepseek.deepseek-v4-flash"]
```

---

## keepers/<name>.toml

Keeper 프로필입니다. 이 파일은 설치 스크립트가 쓰지 않습니다. `masc keeper-create`
(또는 TUI 의 Keepers 화면)로 만들면 필수 항목인 `sandbox_profile` 과 `network_mode`
가 채워집니다. 프로필 모양은 이렇습니다.

```toml
[keeper]
autoboot_enabled = true
proactive_enabled = false
sandbox_profile = "docker"   # "docker" | "microvm" | "remote_ssh"; host 는 거부됨
network_mode = "none"        # "none" | "inherit" | "policy"; "none" 은 게스트 네트워크 전면 차단
instructions = """
당신은 리뷰 Keeper 입니다. 지금 변경을 살펴보고 파일 경로와 명령으로 구체적인
근거를 보고하세요.
"""

[keeper.tools]
native = "read"              # "none" | "read" | "full" — Keeper 가 호출 가능한 host 도구
```

각 `sandbox_profile` 의 의미는 [명령어 안전 격리](/ko/runbooks/sandbox/)를 보세요.
