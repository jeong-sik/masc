---
title: 로컬 AI 모델 연결
description: 로컬 llama.cpp / Ollama 서버를 키 없는 모델 소스로 써서 Keeper·verifier·librarian 을 돌립니다.
---

로컬 모델 서버를 쓰면 Keeper·verifier·librarian 을 외부 클라우드 토큰 없이 돌릴 수
있습니다. OpenAI 호환 HTTP 서버면 다 됩니다 — `llama-server`(llama.cpp), Ollama,
LM Studio, MLX.

## llama-server 실행

```bash
llama-server \
  -m models/qwen-2.5-coder-32b-instruct-q4_k_m.gguf \
  --port 8080 \
  --ctx-size 16384 \
  --n-gpu-layers 99
```

## MASC 에 연결

`<base-path>/.masc/config/runtime.toml` 에 provider 로 추가합니다. 로컬 서버는 API
키가 필요 없으니 `[providers.*.credentials]` 블록도 없습니다.

```toml
[providers.local_llama]
display-name = "Local llama.cpp"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:8080/v1"

[providers.local_llama.healthcheck]
path = "/models"
```

model 을 선언하고 provider 에 바인딩합니다.

```toml
[models.qwen-2.5-coder-32b]
api-name = "qwen-2.5-coder-32b-instruct"

[local_llama.qwen-2.5-coder-32b]
max-request-body-bytes = 1048576
```

그다음 역할을 이 `<provider>.<model>` 쌍에 연결합니다. 모든 턴의 기본으로 두거나,
verifier 같은 한 lane 에만 배정할 수 있습니다.

```toml
# 작업 공간 기본으로
[runtime]
default = "local_llama.qwen-2.5-coder-32b"

# 또는 verifier lane 에만
[runtime.exact_output_lanes.verifier_exact]
slots = ["local_llama.qwen-2.5-coder-32b"]
```

설치 스크립트는 설정할 때 `healthcheck.path` 를 찔러 보므로, 서버가 안 떠 있으면
마법사에 `not running` 으로 보입니다. 나중에 조용히 실패하지 않습니다. 전체 스키마는
[설정 파일](/ko/reference/config/)을 보세요.
