# OAS — OCaml Agent SDK

OCaml 5.x + Eio 기반 에이전트 SDK. 버전 SSOT: `lib/sdk_version.ml` (실제 값은 그 파일 참조 — 본 줄의 숫자는 빠르게 stale 됨).

## Architecture

```
lib/        →  agent_sdk       (Layer 1: Agent Runtime)
test/       →  alcotest 기반 단위/통합 테스트
examples/   →  사용 예제
```

### Layer 1: Agent Runtime (`lib/`)

단일 에이전트 실행 엔진. `(include_subdirs unqualified)` — 서브디렉토리 자동 포함.

| 디렉토리 | 역할 |
|----------|------|
| `lib/agent/` | Agent 라이프사이클, 턴 실행, 도구 호출, handoff |
| `lib/pipeline/` | 6-stage 턴 파이프라인 |
| `lib/protocol/` | A2A, Agent Card, Agent Registry, MCP |
| `lib/*.ml` | 단일-provider API, Context, Hooks, Guardrails, Runtime 등 |

주요 모듈: `Agent`, `Types`, `Error`, `Provider`, `Context`, `Runtime`, `Hooks`, `Tool`

## Build

```bash
scripts/dune-local.sh build <target>  # 로컬 focused 빌드, lock + 낮은 병렬도
make test                           # 로컬 throttled 테스트
```

Full `dune build @all` / `dune runtest`는 CI 또는 명시적인 수동 검증에서만 실행한다.

## Conventions

- OCaml 5.x, Eio 구조적 동시성
- `.mli` API 계약 우선
- `ppx_deriving_yojson`, `ppx_deriving.show` 사용
- `bisect_ppx` 커버리지 — CI ratchet floor (현 floor 는 `.github/workflows/ci.yml` `THRESHOLD` 값, 측정값보다 낮게 설정됨)
- 테스트: alcotest + qcheck (property-based)
- 파일 300줄 이상 → 분할 검토 (`agent.ml` → `agent/` 서브디렉토리)

## Provider Support

| Provider | Backend module | Endpoint |
|----------|---------------|----------|
| Anthropic (Claude) | `backend_anthropic.ml` | Messages API |
| OpenAI-compatible (OpenAI, OpenRouter, llama-server) | `backend_openai.ml` | Chat Completions |
| Gemini | `backend_gemini.ml` | Gemini API (separate backend, not an OpenAI alias) |
| GLM | `backend_glm.ml` | GLM API |
| Ollama | `backend_ollama.ml` | OpenAI-compatible local endpoint |

Agent 실행의 provider SSOT는
`Agent.options.provider_config : Llm_provider.Provider_config.t option`이다.
`Provider_config.t`가 provider identity, wire kind, endpoint, credential,
request path, capability override를 함께 운반한다. 값이 없으면 OAS가 local
또는 Anthropic을 기본값으로 선택하지 않고 설정 오류로 종료한다.

외부 provider catalog를 쓰는 경우 `Provider_runtime_binding.find` 또는
`find_catalog`의 exact binding을
`Provider_runtime_binding.to_provider_config`로 변환한다. embedding
application은 binding의 auth source에서 credential을 명시적으로 붙인다.
찾지 못한 provider/model/credential은 다른 provider로 추정하지 않고
실패시킨다.

## LLM Discovery (`lib/llm_provider/discovery.ml`)

Probes local llama-server instances via OpenAI-compatible API:
- `GET /health` — reachability
- `GET /v1/models` — loaded models
- `GET /props` — total_slots, ctx_size
- `GET /slots` — per-slot busy/idle status

```ocaml
let urls =
  match Llm_provider.Discovery.parse_llm_endpoints_env () with
  | [] -> [ Llm_provider.Discovery.resolve_default_endpoint () ]
  | urls -> urls
in
let endpoints =
  List.map
    (Llm_provider.Discovery.endpoint
       ~protocol:Llm_provider.Discovery.Openai_compatible
       ~capabilities:Llm_provider.Capabilities.default_capabilities)
    urls
in
let statuses = Llm_provider.Discovery.discover ~sw ~net ~endpoints
```

`LLM_ENDPOINTS` (comma-separated) selects the endpoints. It carries no default:
`parse_llm_endpoints_env` returns `[]` when it is unset or blank, and an empty
endpoint list makes `discover` probe nothing. The default lives in
`resolve_default_endpoint`, which reads `OAS_LOCAL_LLM_URL` and otherwise
returns `Constants.Endpoints.default_url` (`http://127.0.0.1:8085`) — so seed it
explicitly as above rather than relying on `LLM_ENDPOINTS` to supply one.

## Provider Routing

OAS provides one-shot single-provider completion via `Complete.complete` and
`Complete.complete_stream`. Later attempts, cross-provider failover, health
filtering, and circuit breaking are the responsibility of downstream consumers
— OAS no longer ships built-in retry or multi-provider cascade execution.

지원 wire kind는 `Anthropic`, `Kimi`, `OpenAI_compat`, `Ollama`, `Gemini`,
`Glm`, `DashScope`다. Provider label과 alias는 catalog 데이터이며, URL이나
model 문자열에서 역추론하지 않는다.

## Key Types

- `Types.agent_config` — 에이전트 설정 (model, system_prompt, provider output options 등)
- `Agent.options.provider_config` — 실행에 필요한 exact provider carrier
- `Types.api_response` — LLM 응답 (content blocks, usage, stop_reason)
- `Error.sdk_error` — 타입 안전한 에러 (Agent, Config, Orchestration 등)

## Dependencies

`mcp_protocol`, `mcp_protocol_eio` — 별도 fork (`jeong-sik/mcp-protocol-sdk`).
`bisect_ppx` — OCaml 5.4 compat fork (`patricoferris/bisect_ppx`).
