---
title: 설정 파일
description: .masc/config/*.toml 파일의 스키마와 예시입니다.
---

지속 설정은 `<base-path>/.masc/config/` 에 있습니다. 설치 스크립트가 동작하는
`runtime.toml` 을 통째로 만들어 두므로, 보통은 **처음부터 쓰기보다 만들어진 파일을
고칩니다**.

## 디렉터리 구조

```text
.masc/config/                     # `masc init` / `masc setup` 이 시드하는 설정 디렉터리
├── runtime.toml                  # provider 카탈로그, 모델 바인딩, [runtime].default, lane, maintenance, wiki_contents, sandbox, tui
├── candle.toml                   # 선택적 Candle 반감기(half_life), [payout], [shop.pricing] 정책
├── sandbox-image-builds.toml     # 런타임 스토어별 승격(promote)된 샌드박스 이미지 태그
├── prompts/                      # 역할별 프롬프트 템플릿 (keeper.md, librarian, verifier 등)
├── tools/                        # 도구 선언 파일
├── identity/                     # Keeper 신원 및 초상화 에셋
├── themes/                       # TUI 색상 테마
├── mcp/                          # MCP 클라이언트 설정 템플릿
└── keepers/                      # Keeper별 프로필 (<name>.toml)
```

커넥터 설정(Discord, Slack)도 별도 파일이 아니라 `runtime.toml` 안의
테이블입니다(`[discord]` 등). `repositories.toml` 은 저장소를 등록하면 생깁니다.

바이너리 설치에는 `.env.local` 이 없습니다. 설정은 TOML 에, 자격증명은 **서버를 띄운 환경**에
있습니다 — [환경 변수](/ko/reference/env-contract/) 참고.

## 카탈로그에 처음 들어 있는 것

`config/runtime.toml` 은 **9개의 활성 provider** 를 시드합니다 — 환경 변수 키가 필요한 HTTP API provider 5개, 로컬 HTTP provider 1개(`ollama`), 그리고 CLI 구독 provider 3개입니다.

| Provider | 프로토콜 / 주소 또는 명령 | 자격증명 (`credentials`) |
| --- | --- | --- |
| `ollama_cloud` | `https://ollama.com/v1` (`openai-compatible-http`) | `env`: `OLLAMA_CLOUD_API_KEY` |
| `deepseek` | `https://api.deepseek.com` (`openai-compatible-http`) | `env`: `DEEPSEEK_API_KEY` |
| `glm-coding` | `https://api.z.ai/api/coding/paas/v4` (`openai-compatible-http`) | `env`: `ZAI_API_KEY` |
| `kimi_coding` | `https://api.kimi.com/coding/v1` (`openai-compatible-http`) | `env`: `KIMI_API_KEY` |
| `openrouter` | `https://openrouter.ai/api/v1` (`openai-compatible-http`) | `env`: `OPENROUTER_API_KEY` |
| `ollama` | `http://localhost:11434` (`ollama-http`) | 없음 (로컬) |
| `claude_code` | `claude` (`claude-code` CLI) | CLI 로그인 |
| `codex_subscription` | `codex` (`codex-app-server` CLI) | CLI 로그인 |
| `antigravity_subscription` | `agy` (`antigravity-cli`) | `file`: `~/.gemini/antigravity-cli/antigravity-oauth-token` |

`llama_server`·`vllm`·`mlx_server` 는 주석 상태로 들어 있습니다 —
[로컬 AI 모델 연결](/ko/runbooks/llama-server/) 참고.

**시드된 바인딩은 모두 Keeper 턴을 받을 수 있습니다.** 요청이 너무 큰지는
공급자가 판정합니다. MASC는 구성한 요청을 그대로 보내고, 거절되면 오래된 대화부터
비우고 다시 보냅니다.

## runtime.toml

`[runtime].default` 는 더 구체적인 지정이 없을 때 한 턴이 쓰는 모델입니다.
`<provider>.<model>` 쌍이고, 양쪽 다 아래에 정의돼 있어야 합니다.

```toml
[runtime]
default = "ollama_cloud.ollama-cloud-glm-5-3-flash"
```

**provider** 는 백엔드에 닿는 방법을 적습니다. 인증이 필요한 외부 HTTP provider 는 반드시 `[providers.<id>.credentials]`(`type = "env"` 및 `key = "<ENV_VAR>"`, 또는 `type = "file"` 및 `path = "..."`)를 선언해야 하며, 누락되면 부팅·검증 시 `credential_undeclared` 로 거절됩니다.

```toml
[providers.deepseek]
display-name = "DeepSeek API"
protocol = "openai-compatible-http"
endpoint = "https://api.deepseek.com"
# 이 provider 를 Exact 출력 레인 슬롯으로 쓰려면 요청 전체 상한이 있어야 합니다.
# connect-timeout-s 는 응답 헤더가 오면 끝나서 그 대신이 되지 않습니다.
exact-body-timeout-s = 1200.0

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
```

verifier 같은 역할은 `[roles]` 테이블이 아니라, lane 에 `<provider>.<model>` 슬롯을
나열해 배정합니다.

```toml
[runtime.exact_output_lanes.verifier_exact]
slots = ["glm-coding.glm-5-3", "ollama_cloud.ollama-cloud-deepseek-v4-1-flash"]
max_output_tokens = 8192
```

슬롯의 HTTP provider 에는 `exact-body-timeout-s` 가 있어야 합니다. 이 키가 없는 슬롯을
새로 더하는 저장은 거절되고, 부팅 때는 그런 슬롯을 레인에서 빼고 런타임 시작 보고에
레인·슬롯·provider 이름을 남깁니다.

### 추가 `runtime.toml` 테이블

```toml
[wiki_contents]
# 매 Keeper 턴 시작 시 <base-path>/.masc/wiki 목차를 컨텍스트에 포함합니다.
enabled = true

[maintenance]
# .masc/ 아래 날짜별 JSONL 저장소 보존 일수 (MASC_JSONL_RETENTION_DAYS 환경변수가 우선).
jsonl_retention_days = 30

[sandbox]
# microVM Keeper 게스트에 전달할 네임서버(IPv4 또는 IPv6 주소 하나, 선택).
microvm_dns = "1.1.1.1"

[tui]
# Board MIDI 첨부파일을 fluidsynth 로 재생할 때 사용할 SoundFont (.sf2 / .sf3) 경로.
midi_soundfont = "/absolute/path/to/soundfont.sf2"
```

---

## keepers/<name>.toml

Keeper 프로필입니다. `masc keeper-create` (또는 TUI 의 Keepers 화면)로 만들면 필수 항목인 `sandbox_profile`, `sandbox_image`, `network_mode` 가 채워집니다. 프로필 모양은 이렇습니다.

```toml
[keeper]
activation_mode = "autonomous"  # "manual" | "reactive" | "scheduled" | "autonomous"
sandbox_profile = "docker"      # "docker" | "microvm" | "remote_ssh" ("local"이나 호스트 프로필은 없음)
sandbox_image = "base"          # "base" | "ocaml"
network_mode = "none"           # "none" | "inherit" | "policy"; "none" 은 게스트 네트워크 전면 차단
instructions = """
당신은 리뷰 Keeper 입니다. 지금 변경을 살펴보고 파일 경로와 명령으로 구체적인
근거를 보고하세요.
"""

[keeper.tools]
native = "read"              # "none" | "read" | "full" — Keeper 가 호출 가능한 host 도구
```

각 `sandbox_profile` 과 `sandbox_image` 의 의미는 [명령어 안전 격리](/ko/runbooks/sandbox/)를 보세요.

---

## candle.toml (`[shop.pricing]`)

`<base-path>/.masc/config/candle.toml` 은 Candle 보상 화폐(`half_life` 및 `[payout]`)와 초상화 장신구 상점 가격 정책을 설정합니다. `[shop.pricing]` 의 `mode = "fixed"` 는 `[shop.prices_milli]` 기준 가격을 그대로 적용하며, `mode = "supply_scaled"` 는 활동 Keeper 수 × `target_per_keeper_milli` 대비 유통 통화량 비율(`min_permille`~`max_permille` 범위 고정 및 `rounding` 적용)로 구매 시점의 실효 가격을 산출합니다.
