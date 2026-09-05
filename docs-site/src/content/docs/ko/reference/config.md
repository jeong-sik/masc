---
title: 설정 파일
description: .masc/config/*.toml 파일의 스키마와 예시입니다.
---

지속 설정은 `<base-path>/.masc/config/` 에 있습니다. 설치 스크립트가 동작하는
`runtime.toml` 을 통째로 만들어 두므로, 보통은 **처음부터 쓰기보다 만들어진 파일을
고칩니다**.

## 디렉터리 구조

```text
.masc/config/
├── runtime.toml    # provider 목록, model 바인딩, [runtime].default, lane
├── .env.local      # provider API 키. quickstart.sh 가 쓰고 start-masc.sh 가
│                   # 읽는 소스 체크아웃 짝입니다. 바이너리 설치에는 둘 다
│                   # 없으니 셸에서 export 하세요.
└── keepers/        # Keeper 별 프로필, 하나에 <name>.toml
    └── reviewer.toml
```

Discord·Slack 같은 커넥터 설정은 별도 파일이 아니라 `runtime.toml` 안의
테이블(`[discord]` 등)로 씁니다. `repositories.toml` 과
`keeper_repo_mappings.toml` 은 해당 기능을 쓰기 시작하면 생깁니다.

---

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
