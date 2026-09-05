---
title: 설정 파일 (.masc/config) 레퍼런스
description: MASC의 런타임, 키퍼, 커넥터를 제어하는 TOML 설정 파일들의 스키마와 예시
---

MASC 작업 공간의 모든 영속 설정은 `<base-path>/.masc/config/` 디렉터리에 위치합니다.

## 디렉터리 구조

```text
.masc/config/
├── runtime.toml               # 프로바이더/모델 카탈로그, [runtime].default, Keeper 배정
├── connectors.toml            # Slack, Discord 등 외부 채널 바인딩
├── repositories.toml          # 등록된 코드 저장소 및 체크아웃 메타데이터
├── keeper_repo_mappings.toml  # Keeper별 선호 저장소 매핑
├── .env.local                 # 공급자 API 키 및 로컬 환경변수
└── keepers/                   # 개별 Keeper 프로파일 정의
    └── reviewer.toml
```

---

## 1. runtime.toml 스키마 예시

```toml
[runtime]
default = "anthropic.claude-3-7-sonnet"

[runtime.assignments]
lead = "anthropic.claude-3-7-sonnet"
reviewer = "openai.gpt-4o"

[providers.anthropic]
kind = "anthropic"
api_key_env = "ANTHROPIC_API_KEY"

[providers.local_llama]
kind = "openai-compatible"
base_url = "http://127.0.0.1:8080/v1"
model = "qwen-2.5-coder-32b-instruct"
api_key = "not-needed"
```

---

## 2. keepers/*.toml 스키마 예시

```toml
[keeper]
autoboot_enabled = true
proactive_enabled = true
sandbox_profile = "docker" # "docker" | "microvm" | "remote_ssh" (host 모드는 지원되지 않음)
mention_targets = ["operator"]

[keeper.tools]
native = "read" # "none" | "read" | "full"

instructions = """
You are the review Keeper. Inspect the current change and report concrete
evidence with file paths and commands.
"""
```
