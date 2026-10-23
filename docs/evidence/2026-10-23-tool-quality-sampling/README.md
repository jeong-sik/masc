# Tool-quality effective sampling measurement

The tool-quality endpoint used `n` in its cache identity even when a positive
`window_hours` selected every retained call in the period and the response had
`sample_limit: null`. Two equivalent requests repeated payload preparation.

| Measured scenario | Before | After |
| --- | ---: | ---: |
| Positive 2-hour window, `n=1` then `n=5000`: preparations | 2 | 1 |
| Returned settled calls, each positive-window request | 2 | 2 |
| Recent-N requests: preparations | 2 | 2 |
| Recent-N returned calls (`n=1`, `n=5000`) | 1, 2 | 1, 2 |
| NaN-window requests: preparations | 2 | 2 |
| NaN-window returned calls (`n=1`, `n=5000`) | 1, 2 | 1, 2 |

This is an isolated native HTTP-router/cache measurement with an actual two-row
ledger, not a production latency benchmark. The old handler failed the preparation
count assertion (expected 1, observed 2); the fixed handler passes. No response-time
percentage or TUI/Dashboard speedup is inferred from those counts.

A private sampling variant now carries the selection once into both the cache
identity and the aggregator. Existing parsing, default count, positive-window
priority, NaN fallback, workspace partitioning and cache TTL remain unchanged.
Direct aggregation keeps 0.01-hour and 200-hour windows; route clamping is not
applied to that interface.

## Focused verification

From the candidate checkout, the explicit targets were prepared with:

```sh
opam exec --switch=5.5.1 -- dune build test/test_dashboard_http_core.exe test/test_keeper_tool_call_log.exe
_build/default/test/test_dashboard_http_core.exe test effective_tool_quality_sampling
_build/default/test/test_dashboard_http_core.exe test exact_query_cache_identity
_build/default/test/test_keeper_tool_call_log.exe test redaction 17-29
```

21 focused tests passed (3 + 5 + 13). Baseline and candidate logs are retained
here; `validation.json` binds them and the five tested source files by SHA-256.
The test result durations describe their isolated fixtures, not endpoint latency.
Full regression and CI were not run. No candidate server was installed and no
UI-ready or browser performance improvement has been established.
