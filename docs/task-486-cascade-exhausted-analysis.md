# cascade_exhausted Failure Pattern Analysis (task-486)

## Summary

The `cascade_exhausted` error occurs when the `strict_tool_candidates` cascade
finds zero providers capable of supplying the required keeper tools
(e.g. `keeper_board_comment`, `keeper_bash`, etc.). This triggers an auto-pause
loop that prevents keepers from claiming and executing tasks.

## Root Cause Chain (5 stages)

### 1. strict_tool_candidates cascade — all providers reject

12 providers are configured in the `tier-group.strict_tool_candidates` cascade.
None satisfies the `supports_inline_tool_choice || runtime_mcp` condition
checked by `Provider_tool_support.supports_required_tool_use`
(`lib/provider_tool_support.ml:355-423`).

### 2. Provider rejection classification

`Provider_tool_support.classify_rejection` (`lib/provider_tool_support.ml:393-423`)
attributes each rejection to one of:

| Reason | Meaning |
|---|---|
| `runtime_mcp_http_headers_required` | Runtime MCP caps present, but policy demands HTTP headers the provider doesn't support |
| `runtime_mcp_caps_missing` | Provider lacks `supports_runtime_mcp_tools` or `supports_runtime_tool_events` |
| `inline_tool_choice_unsupported` | `require_tool_choice` mode but no `supports_inline_tool_choice` |
| `inline_tools_unsupported` | `require_tool_support` mode but no `supports_inline_tools` |
| `filter_disabled` | Both require flags false (defensive default) |

### 3. No_tool_capable_provider → Cascade_exhausted

When every candidate is rejected, `masc_internal_error` transitions from
`No_tool_capable_provider` to `Cascade_exhausted`
(`lib/cascade/cascade_internal_error.ml:18-70`):

```
type masc_internal_error =
  | Cascade_exhausted of { cascade_name; reason }
  | No_tool_capable_provider of { cascade_name; configured_labels;
      required_tool_names; provider_rejections }
  ...
```

### 4. Auto-pause triggered

`keeper_unified_turn_failure.ml:record_failure_and_maybe_escalate` checks
`is_cascade_exhausted_error` and increments `turn_failures`. When the streak
exceeds `turn_fail_streak_threshold`, the keeper enters auto-pause.

### 5. Resume → repeat (vicious cycle)

`Auto_resume_with_backoff` resumes the keeper, but the underlying provider
rejection is unchanged. The same cascade failure recurs, re-triggering pause.

## Key Code References

| File | Lines | Role |
|---|---|---|
| `cascade_internal_error.ml` | 18-70 | Error ADT definition |
| `cascade_internal_error.ml` | 295-340 | Error summarization |
| `provider_tool_support.ml` | 355-423 | `supports_required_tool_use` + `classify_rejection` |
| `config_doctor.ml` | 558-710 | Diagnostic: `provider_forced_tool_rejection_label`, route issues |
| `keeper_unified_turn_failure.ml` | — | `record_failure_and_maybe_escalate` (auto-pause) |
| `keeper_health_probe.ml` | 73 | Health probe for `strict_tool_candidates` |

## Recommendations

1. **Extract rejection reasons from live logs** — the `config_doctor`
   diagnostic already prints each provider's rejection label. Running it
   against the active catalog will reveal the dominant rejection class.

2. **Fix provider configuration** — either:
   - Switch `runtime_mcp_policy` from HTTP to stdio for affected providers
   - Replace non-compliant providers with header-capable ones
   - Add providers that support `inline_tool_choice`

3. **Reconfigure cascade** — if certain keepers only need passive tools,
   route them through a non-`strict_tool_candidates` cascade tier to avoid
   the mandatory tool-use gate entirely.

4. **Add cascade-level retry budget** — a per-cascade retry budget with
   exponential backoff would reduce the auto-pause oscillation frequency
   while the root cause is being addressed.