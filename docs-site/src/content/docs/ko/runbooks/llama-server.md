---
title: 로컬 AI 모델 연결
description: 시드에 이미 들어 있는 자체 호스팅 provider 주석을 풀어, 키 없이 Keeper·verifier·librarian 을 돌립니다.
---

로컬 모델 서버를 쓰면 Keeper·verifier·librarian 을 외부 클라우드 토큰 없이 돌릴 수
있습니다.

**새로 적을 것이 아니라 주석을 푸는 일입니다.** `masc init` 이 심어 준
`runtime.toml` 에 자체 호스팅 서버 세 벌이 주석 처리된 채 들어 있습니다.

| 서버 | provider id | 시드 상태 |
|---|---|---|
| llama.cpp `llama-server` | `llama_server` | 주석, 실측 대조표 포함 |
| vLLM | `vllm` | 주석, 공식 문서 기준 |
| MLX | `mlx_server` | 주석 |
| Ollama (로컬) | `ollama` | **이미 활성** — `http://localhost:11434` |

로컬 Ollama 만 쓸 거면 아무것도 안 해도 됩니다. 시드의 다섯 provider 중 키가 필요
없는 하나가 그것입니다.

세 벌이 주석인 이유는 시드가 직접 적어 둡니다 — 갓 설치한 기계에는 그 서버들이
없고, `enabled = false` 로는 안 됩니다. 설치 마법사가 선언된 provider 를 전부 훑는데
바인딩이 전부 꺼진 provider 를 "has no concrete runtime binding" 으로 거부하기
때문입니다.

## llama-server 실행

```bash
llama-server \
  -m models/qwen-2.5-coder-32b-instruct-q4_k_m.gguf \
  --port 8080 \
  --ctx-size 16384 \
  --n-gpu-layers 99
```

## 주석 풀기

`<base-path>/.masc/config/runtime.toml` 에서 이 블록을 찾아 `#` 를 떼고 `endpoint`
를 실제 주소로 맞춥니다. 로컬 서버는 API 키가 없으니 `credentials` 블록도 없습니다.

```toml
[providers.llama_server]
display-name = "llama.cpp llama-server"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:8080/v1"

[providers.llama_server.healthcheck]
path = "/models"
```

`api-name` 은 그 서버가 `/v1/models` 에서 뭐라고 답하는지 그대로 적습니다.

## 모델 선언과 바인딩

두 자리입니다. `[models.*]` 가 모델이 무엇인지 말하고, `[<provider>.<model>]` 이
그 모델을 이 서버에 붙입니다.

```toml
[models.qwen-2-5-coder-32b]
api-name = "qwen-2.5-coder-32b-instruct"
max-context = 16384
tools-support = true

[llama_server.qwen-2-5-coder-32b]
max-request-body-bytes = 1048576
```

`max-request-body-bytes` 를 빼먹으면 **Keeper 턴이 그 런타임에 안 갑니다.** 부팅
로그가 이름을 찍어 주긴 하지만, 조용히 안 도는 것처럼 보이는 흔한 자리입니다. 시드에
들어 있는 31개 바인딩 중 이 키를 선언한 13개만 턴을 받습니다.

## 역할에 연결

```toml
# 작업 공간 기본으로
[runtime]
default = "llama_server.qwen-2-5-coder-32b"

# 또는 verifier lane 에만
[runtime.exact_output_lanes.verifier_exact]
slots = ["llama_server.qwen-2-5-coder-32b"]
```

설치 스크립트는 설정할 때 `healthcheck.path` 를 찔러 보므로, 서버가 안 떠 있으면
마법사에 `not running` 으로 보입니다. 나중에 조용히 실패하지 않습니다. 전체 스키마는
[설정 파일](/ko/reference/config/)을 보세요.
