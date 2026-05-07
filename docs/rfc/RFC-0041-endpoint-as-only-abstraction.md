# RFC-0041 — Endpoint as the Only Provider Abstraction

> Note: drafted in plan file as RFC-0040 on 2026-05-07. Renumbered to RFC-0041 at PR time because RFC-0040 was taken by RFC-0040-mention-dedup (PR #14147). Content axis unchanged.

- **Status**: Draft (PR-A — module introduction; behavior unchanged)
- **Author**: vincent (with Claude Opus 4.7)
- **Created**: 2026-05-07
- **Supersedes**: RFC-0038 §5 Phase B (typed-wrapper direction, PR #14125 closed); RFC-0039 (capability dispatch, never merged — see `docs/rfc/archive/RFC-0039-superseded-by-RFC-0041.md` for the rejected direction)
- **Files referenced**:
  `lib/provider_adapter.ml:152-167` (cn_* constants, 15 names),
  `lib/provider_adapter.ml:270-627` (direct_adapters registry, 14 entries),
  `lib/provider_adapter.ml:200-229` (URL builder functions),
  `oas/lib/llm_provider/provider_config.ml:25-34` (wire-level oracle for body_schema),
  `oas/lib/llm_provider/backend_*.ml` (per-protocol request shape),
  `oas/lib/llm_provider/transport_*.ml` (CLI subprocess transports),
  `lib/cascade/cascade_config.ml:276-295` (PR-B target),
  `lib/cascade/cascade_health_tracker.ml:132-136` (PR-C target — supersedes PR #14109 axis)

## 1. Position

Three layers of refactoring direction were attempted and rejected:

| Layer | Direction | Rejection signal |
|-------|-----------|------------------|
| 1 (RFC-0038 §5 Phase B) | `Provider_id.t = private string` typed wrapper | `let ollama : t = "ollama"` still hardcodes the literal in source. PR #14125 closed. |
| 2 (RFC-0039) | Capability dispatch (`is_local_provider`, `discovery_method`, `mcp_auto_construct`) | "local vs cloud" is itself a name-class proxy — vllm/sglang/anything-llm don't fit. |
| 3 (this RFC) | `Endpoint = { transport, auth, body_schema, stream_format, capabilities, discovery }` flat record | The only axis that survives wire-level inspection. |

The conclusion: **the Provider abstraction itself is the leak**. Operators perceive providers (Ollama, Claude, GLM); the runtime sees only HTTP requests with specific URLs, headers, body shapes, and stream formats. RFC-0041 retires `Provider_adapter` as a dispatch primitive — its 14 entries become 14 `Endpoint.t` values, and the 11 classification fields collapse into 6 wire-level axes plus operator-facing metadata.

## 2. Why provider classes leak

### 2.1 Wire-level audit (4 surprising findings)

A grep across `oas/lib/llm_provider/` shows the 14 direct_adapters use 6 orthogonal wire-level axes — and provider names cross-cut these axes:

1. **Kimi API uses Anthropic body shape with OpenAI-style auth** — `/v1/messages` endpoint + `content_block_delta` SSE + `Authorization: Bearer` header (not `x-api-key`). `oas/lib/llm_provider/backend_anthropic.ml:72-73` confirms request reuses `kimi_message_to_json`.
2. **Ollama streams ndjson, not SSE** — every other HTTP provider uses `text/event-stream`; Ollama's `/api/chat` returns newline-delimited JSON terminated by a `done:true` line carrying `prompt_eval_count` / `eval_count`. Lost if wrapped as OpenAI compat.
3. **Gemini CLI cannot accept per-call MCP config** — only reads `~/.gemini/settings.json` at launch. Same provider name (`gemini`) as the API variant which DOES accept runtime MCP, but capability differs by transport.
4. **GLM uses `/chat/completions` (no `/v1/`) plus `thinking` field** — OpenAI-compat-shaped enough to delegate to `Backend_openai.build_request` then patch the JSON, but URL path differs from OpenAI by two characters.

These four findings cannot be expressed by a `runtime_kind` enum (Local | Cli_agent | Direct_api). They require axis-level decomposition.

### 2.2 Caller intent classification

Provider_adapter's 11 record fields and their callers (Explore audit, 2026-05-07):

| Field | Callers | Real intent | RFC-0041 mapping |
|-------|---------|-------------|------------------|
| `canonical_name` | 38+ | identity / lookup | `Endpoint.label_prefix` (replaces `cascade_prefix` too) |
| `runtime_kind` | 15+ | dispatch (HTTP vs CLI vs cloud) | split: `Endpoint.transport` (Http \| Cli_subprocess) + `Endpoint.auth` |
| `auth_mode` | 8+ | header injection | `Endpoint.auth` |
| `aliases` | 12+ | normalize input | metadata (boundary parser only) |
| `spawn_key` | 3 | CLI binary | folded into `Cli_subprocess.spawn_key` |
| `cascade_prefix` | 25+ | cascade label | merged with `canonical_name` → `Endpoint.label_prefix` |
| `default_voice` | 3 | UI/TTS | external table (out of scope) |
| `endpoint_url` | 7 | base URL | `Endpoint.transport.base_url` |
| `default_model_id`, `model_policy` | 5+ | model resolution | endpoint-attached policy (separate RFC) |
| `tool_policy.supports_runtime_mcp_http_headers` | 6 | MCP capability | `Endpoint.capabilities.supports_runtime_mcp_http_headers` |
| `telemetry_policy` | 2 | metrics gating | `Endpoint.capabilities.emits_usage_telemetry` |

`is_local_provider`, `find_by_canonical_name`, and `cn_*` constants all die.

## 3. Design

### 3.1 The `Endpoint` type

```ocaml
type transport =
  | Http of { base_url : string; request_path : string }
  | Cli_subprocess of { binary : string; spawn_key : string }

type auth =
  | None_required
  | Bearer of { env_var : string }
  | X_api_key of { env_var : string; version_header : (string * string) option }
  | Url_query_key of { env_var : string }
  | Cli_cached_login
  | Vertex_adc of { project_env_var : string; location_env_var : string }

type body_schema =
  | Anthropic_content_blocks
  | OpenAI_messages
  | OpenAI_messages_with_thinking   (* GLM: OpenAI shape + extra fields *)
  | Ollama_options                  (* messages + options + think + num_predict *)
  | Gemini_contents_parts
  | Cli_args_text
  | Cli_args_json

type stream_format =
  | Sse_openai_delta
  | Sse_anthropic_blocks
  | Sse_gemini_server_content
  | Ndjson_ollama                   (* done:true terminator carries usage *)
  | Cli_stdout_text
  | Cli_stdout_stream_json

type discovery_method =
  | No_discovery
  | Models_endpoint of { path : string }   (* /v1/models — llama-server *)
  | Ps_endpoint of { path : string }       (* /api/ps — ollama *)

type capabilities = {
  supports_runtime_mcp_http_headers : bool;
  supports_per_call_mcp_config : bool;     (* gemini_cli=false; others true *)
  emits_usage_telemetry : bool;
}

type t = {
  label_prefix : string;
  display_name : string;
  transport : transport;
  auth : auth;
  body_schema : body_schema;
  stream_format : stream_format;
  capabilities : capabilities;
  discovery : discovery_method;
}
```

### 3.2 Cascade-of-Cascades (nested)

Operator reality (single example — keeper_turn cascade):

```
keeper_turn
  ├─ big_three            (* claude_api, codex_api, gemini_api *)
  ├─ local_fallback       (* ollama, llama_server *)
  └─ cli_fallback         (* claude_cli, codex_cli *)
```

Industry comparison (§5): no major library (OpenClaw, Hermes, OpenRouter) supports this as first-class. LiteLLM's `order=1/2/3` comes closest but only within a single `model_group`. RFC-0041 introduces:

```ocaml
type cascade =
  | Endpoints of (Endpoint.t * model_id) list
  | Nested of cascade list
  | With_fallback of { primary : cascade; fallback : cascade }
```

Each sub-cascade owns its `Endpoint_health.tracker` so "advance to local_fallback only when all of big_three is unhealthy" is expressible as group-level health propagation — not as a flat seven-endpoint list that loses sub-group signal.

Detailed semantics (depth limits, health propagation rules, scheduling order) belong to PR-F, not PR-A.

### 3.3 The "local vs cloud" disappearance

| Today | After RFC-0041 |
|-------|----------------|
| `is_local_provider name` → cooldown 5s | `Endpoint_health.cooldown endpoint` from measured latency p50 + retry-after |
| `runtime_kind = Local` → API key not required | `endpoint.auth = None_required` (Ollama, llama-server) |
| `runtime_kind = Local` → discovery probe | `endpoint.discovery = Some _` (any endpoint with `/api/ps` or `/v1/models`) |

Adding vllm/sglang/anything-llm requires one Endpoint entry, no new classification labels.

## 4. Migration phases

| Phase | PR | Scope | LOC |
|-------|----|-------|-----|
| **A** | this PR | RFC + `lib/endpoint.{ml,mli}` + 14-entry registry + drift-guard tests. **Behavior change: 0** | ~250 + ~80 + ~80 + ~400 (RFC) |
| B | follow-up | rewrite `cascade_config.ml:276-295` discovery branches to read `Endpoint.discovery` (preserves PR #14116 intent on a different axis) | ~80 |
| C | follow-up | rewrite `cascade_health_tracker.ml:132-136` cooldown to be measured per-endpoint (supersedes PR #14109 axis); state machine = Hystrix circuit breaker | ~120 |
| D | follow-up (split D-1..D-4) | migrate Provider_adapter caller groups (auth_mode → endpoint.auth, runtime_kind → endpoint.transport, telemetry_policy → endpoint.capabilities, UI labels → external table) | ~300 |
| E | follow-up | remove `cn_*`, deprecate `Provider_adapter`. CI gate: zero `Provider_adapter.cn_*` outside the registry. `aliases` moves to boundary parser | ~150 + CI |
| F | requires sign-off | `cascade.toml` schema migration (operator-facing breaking change). Adopt LiteLLM-style `routing_strategy`, FrugalGPT-style `cost_threshold`, Hermes-style `sort/only/ignore/order` keywords | ~80 + script |

PR-A is intentionally inert — Endpoint module exists, no caller invokes it. PR-B is the first caller. This isolates regression risk to one PR per axis change.

### 4.1 PR-A explicit scope

**In scope**:
- Add `lib/endpoint.ml`, `lib/endpoint.mli` with the type definitions in §3.1.
- Populate `Endpoint.direct_endpoints : t list` with 14 entries 1:1 with `Provider_adapter.direct_adapters` (same URL builder calls, same env var names).
- Add `test/test_endpoint.ml` + stanza covering: 1:1 alignment with Provider_adapter, three §2.1 surprises, every CLI transport uses `Cli_cached_login`, label_prefix uniqueness.
- Move `RFC-0039-capability-dispatch-over-name.md` to `docs/rfc/archive/RFC-0039-superseded-by-RFC-0041.md` (learning artifact).

**Out of scope**:
- Any change to `Provider_adapter` callers.
- Any change to `cascade_*` modules.
- `cascade.toml` schema.
- Cooldown / health-tracker policy.

**Verification**:
- `dune build --root .` passes.
- `dune runtest --root .` passes (existing tests + new test_endpoint).
- `git diff origin/main lib/keeper/ lib/cascade/` is empty.

## 5. Prior Art (industry comparison, 2026-05-07)

| Library | Provider abstraction | Cascade representation | Nested | Wire-level axis |
|---------|---------------------|------------------------|--------|-----------------|
| OpenClaw | `{ baseUrl, apiKey, api, headers, timeoutSeconds }` | model allowlist + cascading fallback (single level) | ❌ | single `api` field (`"openai-completions"`, `"anthropic-messages"`) |
| Hermes Agent (Nous) | provider name string (`"Anthropic"`) | YAML `sort/only/ignore/order` priority list | ❌ | delegates to OpenRouter |
| LiteLLM | `model_group` (deployments sharing model_name) | `function_with_fallbacks` → `function_with_retries` → `litellm.completion`, `order=1/2/3` | partial (within model_group) | per-provider request translation |
| OpenRouter | `provider/model-name` unified identifier | `models` array = linear priority cascade | ❌ | hidden normalization |

**Convergence with RFC-0041**: OpenClaw's `api` field maps directly onto `body_schema`. The 6-axis decomposition is finer than OpenClaw's single field — required to express Kimi's "Anthropic body + Bearer auth" hybrid (§2.1).

**Divergence (RFC-0041 differentiator)**: Nested cascade is first-class only in RFC-0041. Industry libraries treat fallback as a flat priority list. The operator pattern in §3.2 is unrepresentable as a flat list without losing sub-group health signal.

**Borrowed vocabulary** (for PR-F):
- LiteLLM 4-strategy routing (`simple-shuffle / least-busy / latency-based / cost-based`).
- Hermes `sort/only/ignore/order` keywords.
- OpenClaw `api` field as operator-facing shorthand.
- OpenRouter specialized error fallback (content_policy, context_window, rate-limit each route differently).

Sources: [OpenClaw Model Providers](https://docs.openclaw.ai/concepts/model-providers), [Hermes Agent Provider Routing](https://hermes-agent.nousresearch.com/docs/user-guide/features/provider-routing), [LiteLLM Router Architecture](https://docs.litellm.ai/docs/router_architecture), [OpenRouter Model Fallbacks](https://openrouter.ai/docs/guides/routing/model-fallbacks).

## 6. Academic Foundations

| Reference | Mapping |
|-----------|---------|
| **FrugalGPT** (Chen et al., Stanford) — cascading: cheapest first, confidence threshold, escalate. 98% cost ↓, 4% accuracy ↑ vs GPT-4 baseline | Justifies RFC-0041's nested cascade as a cost-optimization primitive. PR-F `cost_threshold` keyword. |
| **CASTER** (Liu et al.) — dual-signal router (semantic + structural). 72.4% cost ↓ vs strong-model baseline. on-policy negative feedback | Successor RFC after PR-C: `Endpoint_health.tracker` may evolve from latency-only to multi-signal. |
| **Hystrix circuit breaker** (Netflix) — N consecutive failures → OPEN cooldown → HALF_OPEN probe → CLOSE | PR-C state machine specification. PR #14109's "5/10s vs 3/30s" parameters align with Hystrix order of magnitude — only the dispatch axis was wrong. |
| **LiteLLM rotation** — cooldown timer → expiry → automatic recovery → progressive re-introduction → counter reset | PR-C cooldown lifecycle. |
| **AI Gateway hierarchy** (`Provider Config → Virtual Key → Team → Customer`) | Production-AI-gateway justification for §3.2 nested cascade. |
| **Token-aware vs request-count rate limit** | Future RFC: `keeper_turn_slot` Semaphore is request-count based — known anti-pattern. |
| **Sliding Windows over Fixed Windows** | `Endpoint_health` measurement window policy. |

## 7. Risks and Open Questions

### Risks

- **Provider_adapter 30+ caller migration in PR-D**. Mitigated by sub-PR split (D-1 auth, D-2 transport, D-3 telemetry, D-4 UI labels).
- **`cascade.toml` schema break in PR-F**. Operator-facing; requires explicit sign-off. Two-schema parsing during migration.
- **PR #14109 / #14116 already in main on the wrong axis**. Re-written in PR-B/PR-C, not rolled back. Exposure window minimized by landing PR-A → PR-B → PR-C in close sequence.

### Open Questions

- **OQ1**: nested cascade depth limit — unbounded recursion vs N=2 / N=3? Defer to PR-F.
- **OQ2**: one Endpoint definition vs multiple instances. vllm with two ports (11500, 11501) — `direct_endpoints` is definition-only, instance overrides via cascade.toml `base_url` field. Decide in PR-F.
- **OQ3**: name — `Endpoint` vs `Backend` vs `Wire`. `Endpoint` chosen for HTTP precision; CLI subprocess "endpoint" is a slight stretch but tolerable.
- **OQ4**: should `Endpoint.t` be opaque (`private`) at the .mli boundary? Argument for: prevents accidental `String.equal endpoint.label_prefix "ollama"` regressing back to name dispatch. Argument against: structural pattern matching in tests becomes harder. Defer to PR-D.

## 8. Decision

This RFC retires the typed-wrapper direction (RFC-0038 §5 Phase B) and the capability-dispatch direction (RFC-0039). PR-A ships the Endpoint module as inert infrastructure. PR-B through PR-F require independent sign-off. PR-A approval does NOT auto-imply later phases.
