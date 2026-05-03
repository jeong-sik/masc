# RFC-0024: Ollama Cascade Integration + KV Cache Optimization

- **Status**: Draft
- **Author**: vincent (with Claude)
- **Created**: 2026-05-03
- **Related**: backend_ollama.ml (agent_sdk), provider_adapter.ml, config/cascade.toml

## 1. Problem

agent_sdk에 이미 `backend_ollama.ml`이 완전 구현되어 있으나 (`/api/chat`, `think` 제어, `keep_alive=-1` 기본, 스트리밍), masc-mcp의 `provider_adapter.ml`과 `cascade.toml`에 Ollama provider가 등록되어 있지 않아 로컬 모델을 cascade에서 사용할 수 없음.

## 2. Current State

agent_sdk `backend_ollama.ml` 지원:
- `/api/chat` 엔드포인트 (native API)
- `think` 파라미터 (boolean, 기본 false)
- `keep_alive`: 해석 순서 config → `OAS_OLLAMA_KEEP_ALIVE` env → 기본 `-1` (영구 상주)
- `num_predict` → `max_tokens` 매핑
- `options` 객체 내 샘플링 파라미터
- `tool_use_recovery.ml`에서 Ollama 오류 복구 지원
- provider.ml에 `Ollama` variant 이미 정의

masc-mcp 누락:
- `provider_adapter.ml`에 Ollama adapter entry 없음
- `cascade.toml`에 Ollama model 없음
- 로컬 런타임 프로브는 `tool_local_runtime_probe.ml`에 존재하나 cascade 라우팅과 연결 안 됨

## 3. Design Principles

| # | Principle | Rationale |
|---|-----------|-----------|
| P1 | **Register, don't build.** | Transport는 agent_sdk에 이미 있음. masc-mcp는 등록만. |
| P2 | **Optional cascade inclusion.** | Ollama는 로컬 전용. 기본 cascade에서 제외, operator가 명시적으로 추가. |
| P3 | **keep_alive=-1 고정.** | 자동화 환경에서 모델 언로드 방지. 이미 agent_sdk 기본값. |

## 4. Implementation

### 4.1 Provider Adapter Entry

In `lib/provider_adapter.ml`, add Ollama adapter:

```ocaml
{ canonical_name = "ollama";
  runtime_kind = Direct_api;  (* HTTP API, not CLI *)
  auth_mode = No_auth;  (* Ollama is local, no auth *)
  cascade_prefix = "ollama";
  endpoint_url = Some "http://127.0.0.1:11434";
  default_model_id = "llama3.2";
  aliases = ["ollama"; "local"];
}
```

### 4.2 Cascade Profile (optional, operator opt-in)

```toml
[local_small]
comment = "Local Ollama models for cost-free routing. Operator opt-in."
models = [
  "ollama:llama3.2:3b",
  "ollama:phi-3-mini",
]
temperature = 0.3
max_tokens = 4096
keeper_assignable = true
```

### 4.3 KV Cache Optimization (Server-side)

Not a code change. Ollama 서버 설정:

```bash
# ~/.config/ollama/config.json 또는 환경변수
OLLAMA_FLASH_ATTENTION=1    # Flash Attention 활성화
OLLAMA_KEEP_ALIVE=-1        # 모델 영구 상주 (이미 agent_sdk 기본값)
```

모델 풀 시 Q8_0 quantization 권장:
```bash
ollama pull llama3.2:3b-q8_0
```

## 5. Files to Modify

| File | Change |
|------|--------|
| `lib/provider_adapter.ml` | Ollama adapter entry 추가 |
| `lib/provider_adapter.mli` | 필요시 expose |
| `config/cascade.toml` | `[local_small]` 프로파일 추가 (주석처리, opt-in) |

## 6. Scope Exclusions

- agent_sdk transport 변경 없음 (이미 완전 구현)
- flash_attention 설정은 서버 환경변수 (코드 아님)
- 자동 모델 티어 분류는 P12에서 다룸
