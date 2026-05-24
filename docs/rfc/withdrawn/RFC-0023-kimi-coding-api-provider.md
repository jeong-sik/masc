---
title: Provider-C Coding API Provider (3-way Split Completion)
rfc: 0023
status: Withdrawn
created: 2026-05-03
withdrawn_date: 2026-05-21
withdrawn_reason: "Provider-C provider ships via provider_adapter.ml + transport_cli-tool-c.ml without spec ratification. 3-way split design never adopted. No implementation commits in 180+ days. Archived for history."
---

# RFC-0023: Provider-C Coding API Provider (3-way Split Completion)

- **Status**: Draft
- **Author**: vincent (with Agent-LLM-A)
- **Created**: 2026-05-03
- **Related**: provider_adapter.ml, transport_cli-tool-c.ml, config/cascade.toml

## 1. Problem

Provider-C (Provider-B AI) has 3 distinct API surfaces, but masc-mcp only integrates 2:

| Provider | Endpoint | Type | Status |
|---|---|---|---|
| `provider-c` (CLI) | local binary `model-c-coding` | `Cli_agent` | Active in cascade |
| `provider-c-api` | `api.provider-b.ai` | `Direct_api` | Registered, not in cascade |
| `provider-c-coding` | `api.provider-c.com/coding` | `Direct_api` | **Missing** |

The `provider-c-coding` endpoint is a coding-optimized API with different rate limits, pricing, and model routing.

## 2. Design Principles

| # | Principle | Rationale |
|---|-----------|-----------|
| P1 | Separate provider, not endpoint toggle. | Current architecture treats each variant as a separate provider. Third follows same pattern. |
| P2 | Reuse Direct_api transport. | Same Provider-D-compatible HTTP transport as `provider-c-api`. Different endpoint and API key. |
| P3 | Cascade opt-in. | New provider starts outside cascade profiles. Operators add after validation. |

## 3. Implementation

### 3.1 Provider Registry Entry

In `lib/provider_adapter.ml`, add:

```ocaml
{ canonical_name = "provider-c-coding";
  runtime_kind = Direct_api;
  auth_mode = Api_key "PROVIDER-C_CODING_API_KEY";
  cascade_prefix = "kimi_coding";
  endpoint_url = Some "https://api.provider-c.com/coding/v1";
  default_model = "provider-c-coding-auto";
  aliases = ["provider-c-coding"; "kimi_coding"];
}
```

### 3.2 Environment Variable

`PROVIDER-C_CODING_API_KEY` with fallback to `PROVIDER-C_API_KEY_SB`.

### 3.3 No New Transport Module

Reuse existing Provider-D-compatible `Direct_api` transport. Only differences are base URL and API key env var.

## 4. Files to Modify

| File | Change |
|------|--------|
| `lib/provider_adapter.ml` | Add `provider-c-coding` provider entry |
| `lib/provider_adapter.mli` | Expose if needed |
| `config/cascade.toml` | Optional: add to cascade profile after validation |

## 5. Validation

1. Unit: provider registry lookup by alias
2. Integration: HTTP request to `api.provider-c.com/coding` with test key
3. Smoke: add to cascade, run keeper turn, verify routing
