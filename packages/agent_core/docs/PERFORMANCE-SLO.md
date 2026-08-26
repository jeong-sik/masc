# agent_core Performance SLO

Service Level Objectives for the agent_core streaming-completion path.  RFC
sources are cited at each row; calibration history is at the bottom.

## TTFT — Time To First Token

**Definition.**  Milliseconds from provider HTTP request submission
to the first parsed chunk that carries a non-empty user-visible
delta (text / reasoning / tool-call argument).  Captured in-process
in `Complete.publish_summary` and emitted as
`Streaming_summary.ttft_ms : float option` (RFC-AC-020 §3.2).

Distinct from `Streaming_first_chunk.ttfrc_ms` which fires on the
first chunk regardless of payload — TTFT skips role-only preludes
and finish-only finalizer chunks.

| Provider | P50 target | P95 target | Source |
|---|---|---|---|
| Anthropic (cloud) | ≤ 400 ms | ≤ 1500 ms | RFC-AC-020 §3.3 baseline (calibration pending — see below) |
| Local llama-server (LAN) | ≤ 150 ms | ≤ 500 ms | RFC-AC-020 §3.3 baseline (calibration pending) |
| ZAI GLM (cloud) | ≤ 500 ms | ≤ 1500 ms | RFC-AC-020 §3.3 baseline (calibration pending) |

Targets are **uncalibrated baseline values** at PR-1b.  The
calibration run described in RFC-AC-020 §3.5 has not been executed
because real provider keys / a live local llama-server are not
available to the agent that authored this file.  When operator runs
`scripts/bench/ttft_distribution.sh` for the first time, this table
SHOULD be updated to the measured P50/P95 + a +30 % headroom on
P95 (so transient spikes don't page).

## prefill_ms — first SSE event lead time (when separable)

**Definition.**  Milliseconds from provider HTTP request submission
to the first SSE event of any kind.  `Some` iff the provider
exposes a separable prelude (e.g. Anthropic emits `MessageStart`
before the first `ContentBlockDelta`); `None` otherwise.

| Provider | P95 target | Note |
|---|---|---|
| Anthropic | ≤ 300 ms | gap between MessageStart and first content_block_delta |
| Local llama-server | ≤ 100 ms | prefill_ms is `None` in current backend (no separable prelude) — listed for future telemetry that may expose it |
| GLM / OpenAI-compat / Gemini / Ollama | n/a | first event IS first token → `prefill_ms = None` |

## Measurement protocol

The bench script `scripts/bench/ttft_distribution.sh` measures
**TTFB** (Time To First Byte of body) as a transport-level proxy.
For OpenAI-compat / GLM / Ollama the gap between TTFB and TTFT is
typically < 5 ms, so the script is a useful operational smoke
check.  For Anthropic the gap can be tens to hundreds of
milliseconds, so the SLO targets in this document **must** be
calibrated against the in-process `Streaming_summary.ttft_ms`
field, not against the bench script output alone.

## Calibration log

| Date | Provider | Model | P50 | P95 | max | std | n |
|---|---|---|---|---|---|---|---|
| (not yet run) | | | | | | | |

When you run the bench, append a row here and update the targets
table above if the new baseline is materially different.

## Boundary with masc-mcp

`masc-mcp` adds an *operator-visible* SLO on top of these provider
SLOs: `ttft_to_client_ms ≈ ttft_ms + transport_overhead_ms` where
`transport_overhead_ms` is the masc-mcp-side time from first SSE
chunk arrival to flush-to-client (typically < 5 ms).  That
composition lives in masc-mcp `docs/PERFORMANCE-SLO.md` (TBD) and
is intentionally *not* coupled to this agent_core-side document.

## References

- RFC-AC-020 — TTFT instrumentation in `Streaming_summary` (Active)
- RFC-AC-019 — Stream-lifetime telemetry aggregation (Active)
- `lib/llm_provider/complete.ml` — capture site (`first_token_at_ref`,
  `first_event_at_ref`)
- `lib/llm_provider/streaming.ml` — typed predicates
  (`chunk_has_non_empty_delta`, `sse_event_is_first_token_signal`)
