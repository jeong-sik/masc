---
title: Llama Server 연동 런북
description: llama.cpp 기반 로컬 LLM 서버(Qwen 등)를 MASC의 판정자(Judge) 및 보조 런타임으로 연결하는 절차입니다.
---

MASC는 상용 클라우드 API뿐만 아니라 로컬에서 구동되는 오픈소스 모델을 독립 검증자(Verifier), 판정자(Judge), 사서(Librarian)로 활용할 수 있습니다.

## 1. 권장 모델 및 환경

- **권장 모델**: Qwen 2.5 / 3.8 계열 (MLX 또는 GGUF 포맷)
- **엔진**: `llama.cpp` (`llama-server`) 또는 Ollama
- **호스트**: 로컬 머신 (Apple Silicon 권장)

---

## 2. llama-server 실행

다음 명령으로 OpenAI 호환 엔드포인트를 노출하는 로컬 서버를 구동합니다:

```bash
llama-server \
  -m models/qwen-2.5-coder-32b-instruct-q4_k_m.gguf \
  --port 8080 \
  --ctx-size 16384 \
  --n-gpu-layers 99
```

정상 구동 확인:
```bash
curl http://127.0.0.1:8080/v1/models
```

---

## 3. MASC 런타임 설정

`.masc/config/runtime.toml`에 로컬 프로바이더를 등록합니다:

```toml
[providers.local_llama]
kind = "openai-compatible"
base_url = "http://127.0.0.1:8080/v1"
model = "qwen-2.5-coder-32b-instruct"
api_key = "not-needed"

[roles]
verifier = "local_llama"
librarian = "local_llama"
```

외부 클라우드 토큰 소모 없이 내부 검증 및 코드 정리 작업을 로컬 인퍼런스로 수행할 수 있습니다.
