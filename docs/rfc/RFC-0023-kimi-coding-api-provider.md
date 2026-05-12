# RFC-0023: Kimi Coding API Provider (3-way Split Completion)

- **Status**: Draft
- **Author**: vincent (with Claude)
- **Created**: 2026-05-03
- **Related**: runtime_catalog.ml, transport_kimi_cli.ml, config/cascade.toml

## 1. Problem

Kimi (Moonshot AI) has 3 distinct API surfaces, but masc-mcp only integrates 2:

| Provider | Endpoint | Type | Status |
|---|---|---|---|
| `kimi` (CLI) | local binary `kimi-for-coding` | `Cli_agent` | Active in cascade |
| `kimi-api` | `api.moonshot.ai` | `Direct_api` | Registered, not in cascade |
| `kimi-coding` | `api.kimi.com/coding` | `Direct_api` | **Missing** |

The `kimi-coding` endpoint is a coding-optimized API with different rate limits, pricing, and model routing.

## 2. Design Principles

| # | Principle | Rationale |
|---|-----------|-----------|
| P1 | Separate provider, not endpoint toggle. | Current architecture treats each variant as a separate provider. Third follows same pattern. |
| P2 | Reuse Direct_api transport. | Same OpenAI-compatible HTTP transport as `kimi-api`. Different endpoint and API key. |
| P3 | Cascade opt-in. | New provider starts outside cascade profiles. Operators add after validation. |

## 3. Implementation

### 3.1 Provider Registry Entry

In `lib/runtime_catalog.ml`, add:

```ocaml
{ canonical_name = "kimi-coding";
  runtime_kind = Direct_api;
  auth_mode = Api_key "KIMI_CODING_API_KEY";
  cascade_prefix = "kimi_coding";
  endpoint_url = Some "https://api.kimi.com/coding/v1";
  default_model = "kimi-coding-auto";
  aliases = ["kimi-coding"; "kimi_coding"];
}
```

### 3.2 Environment Variable

`KIMI_CODING_API_KEY` with fallback to `KIMI_API_KEY_SB`.

### 3.3 No New Transport Module

Reuse existing OpenAI-compatible `Direct_api` transport. Only differences are base URL and API key env var.

## 4. Files to Modify

| File | Change |
|------|--------|
| `lib/runtime_catalog.ml` | Add `kimi-coding` provider entry |
| `lib/runtime_catalog.mli` | Expose if needed |
| `config/cascade.toml` | Optional: add to cascade profile after validation |

## 5. Validation

1. Unit: provider registry lookup by alias
2. Integration: HTTP request to `api.kimi.com/coding` with test key
3. Smoke: add to cascade, run keeper turn, verify routing
