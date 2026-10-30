# RFC-AC-020: TTFT instrumentation in Streaming_summary

| | |
|---|---|
| Status | Draft |
| Author | vincent (with Claude analysis) |
| Created | 2026-05-17 |
| Target | `agent_sdk` (agent_core) |
| Extends | [[RFC-AC-019]] (stream-lifecycle-aggregation) — adds two fields to its `Streaming_summary` |
| Related | [[RFC-AC-018]] (provider-model-catalog-externalization), masc-mcp [[RFC-0098]] (typed JSON-RPC envelope, IMPROVE-01 sibling) |

## 0. Summary

`agent_sdk` has no surface for **Time-to-First-Token (TTFT)** measurement today. The SSE parser (`lib/llm_provider/streaming.ml(i)`) returns `openai_chunk` / `sse_event` values without timing markers, and the completion consumer (`lib/llm_provider/complete.ml`) publishes per-chunk `Streaming_chunk_n` with `inter_chunk_ms` but never records the **first-token-at** wall-clock offset from the request submission.

This RFC adds two timing fields to the `Streaming_summary` variant introduced by [[RFC-AC-019]]:

- **`ttft_ms : float`** — milliseconds from the provider HTTP request submission to the first parsed chunk that contains a non-empty token delta (excluding role-prelude, finish-only, and empty chunks).
- **`prefill_ms : float option`** — milliseconds from request submission to the provider's first SSE event of any kind. `None` for providers that do not expose a distinct prefill marker; `Some` when separable (e.g., Anthropic's `message_start` event arrives before the first `content_block_delta`).

TTFT is the canonical chatbot UX latency metric (IBM "Time to First Token", BentoML LLM inference metrics — both 2025). It has been absent from the SDK and from masc-mcp's PERFORMANCE-SLO. This RFC closes the measurement gap on the SDK side.

This RFC is **IMPROVE-04** of the cross-repo (masc-mcp + agent_core) improvement series; sibling [[RFC-0098]] (masc-mcp) closes the silent-failure / typed-envelope side.

## 1. Problem (line-pinned, 2026-05-17 agent_core main `d88e2fe4`)

### 1.1 No first-token timing in the SDK

`lib/llm_provider/streaming.mli`:

```ocaml
val parse_sse_event : string option -> string -> sse_event option
val parse_openai_sse_chunk : string -> openai_chunk option
val openai_chunk_to_events : openai_stream_state -> openai_chunk -> sse_event list
```

The parser is pure and returns events without wall-clock markers. The consumer in `lib/llm_provider/complete.ml` synthesises `inter_chunk_ms` for per-chunk telemetry but does **not** capture the absolute "first non-empty chunk at" timestamp. Result: no `ttft_ms` field reaches any downstream consumer.

### 1.2 PERFORMANCE-SLO has no TTFT target

masc-mcp's `docs/PERFORMANCE-SLO.md` defines:
- MCP request P95 < 300ms (full-response time)
- SSE event P95 < 500ms (inter-event time)

Neither captures TTFT. A 60-second completion with a 50ms TTFT and a 50-second tail is indistinguishable from a 60-second completion with a 5-second TTFT under the existing SLOs — yet the perceived UX is wildly different.

### 1.3 Composition with RFC-AC-019

[[RFC-AC-019]] §4 introduces `Streaming_summary` with fields including `inter_chunk_ms_p50 / p95 / max` and `kind_breakdown`. It explicitly does **not** include first-token timing — the focus is *firehose reduction*, not new measurement.

The two RFCs are naturally composable. The decision: extend `Streaming_summary` rather than introduce a parallel `Streaming_ttft` event (which would re-create the per-event proliferation AC-019 just eliminated).

## 2. Non-goals

- **Replacing AC-019**. This RFC extends AC-019's `Streaming_summary` with two fields. AC-019's per-chunk → summary migration is the load-bearing change; this RFC is a one-shot field addition.
- **Adding per-token timing inside a chunk**. A single SSE chunk may carry multiple tokens (Anthropic) or one (OpenAI); per-token timing requires a deeper instrumentation hook (tokenizer-aware) that is out of scope.
- **Defining provider-specific prefill mechanics**. `prefill_ms` is best-effort and `None` for providers without a marker. The decision rule is colocated with the per-backend SSE parser.
- **HTTP keep-alive pool**. WS-C (IMPROVE-03 in masc-mcp) RFC will introduce a generic Eio.Pool-backed accountant; that work will lower TTFT by a TLS handshake's worth of RTT but is independent of this RFC. This RFC measures; that RFC reduces.
- **Dashboard / UX presentation**. Where TTFT is *displayed* is a separate concern; this RFC ensures the field exists in `Streaming_summary`.
- **Changing the SDK's external SSE wire**. No SSE protocol change to clients; the telemetry change is on `Event_bus.Custom("telemetry_event", ...)` only (same surface as AC-019).

## 3. Design

### 3.1 `Streaming_summary` field extensions

Building on [[RFC-AC-019]] §3 (assumed merged or in-flight), extend the variant payload:

```ocaml
| Streaming_summary of {
    (* RFC-AC-019 fields — kept verbatim *)
    provider : string ;
    model : string ;
    chunk_count : int ;
    inter_chunk_ms_p50 : float ;
    inter_chunk_ms_p95 : float ;
    inter_chunk_ms_max : float ;
    kind_breakdown : (string * int) list ;
    terminal : [`Finished | `Cancelled | `Error of string] ;

    (* RFC-AC-020 additions *)
    ttft_ms : float ;
    prefill_ms : float option ;
  }
```

`ttft_ms` is **mandatory** — every Streaming_summary publishes a value (defaulting to the time of the first parsed chunk when no separable first-token signal exists). `prefill_ms` is **optional** to honour provider asymmetry.

### 3.2 Capture points in `complete.ml`

Two wall-clock samples added inside the existing accumulator loop in `lib/llm_provider/complete.ml`:

```ocaml
let req_submitted_at = Eio.Time.now clock in
(* ... HTTP send + SSE consume ... *)
let first_event_at = ref None in
let first_token_at = ref None in
(* in the chunk-emit branch *)
if Option.is_none !first_event_at then
  first_event_at := Some (Eio.Time.now clock) ;
match chunk_has_non_empty_delta chunk with
| true when Option.is_none !first_token_at ->
    first_token_at := Some (Eio.Time.now clock)
| _ -> () ;
```

At finalize:

```ocaml
let ttft_ms =
  match !first_token_at with
  | Some t -> (t -. req_submitted_at) *. 1000.0
  | None -> 0.0  (* zero-chunk completion — should not happen for a non-empty stream *)
in
let prefill_ms =
  match !first_event_at, !first_token_at with
  | Some fe, Some ft when ft > fe ->
      Some ((fe -. req_submitted_at) *. 1000.0)
  | _ -> None
in
```

`chunk_has_non_empty_delta : openai_chunk -> bool` is a new pure helper in `lib/llm_provider/streaming.ml(i)`:

```ocaml
val chunk_has_non_empty_delta : openai_chunk -> bool
(** [true] when the chunk carries either a non-empty [delta_content]
    or a non-empty [delta_reasoning] or any [delta_tool_calls] —
    that is, the consumer would surface a visible token to the
    application. Used by the TTFT capture point in
    [complete.ml] (RFC-AC-020). *)
```

For the Anthropic SSE parser, the analogous helper:

```ocaml
val sse_event_is_first_token_signal : sse_event -> bool
(** [true] when the event represents the first user-visible token
    delta (typically [`content_block_delta] with non-empty text), as
    distinct from prelude events ([`message_start], [`ping]) which
    set [prefill_ms] but not [ttft_ms]. *)
```

### 3.3 SLO additions

`docs/PERFORMANCE-SLO.md` (or its successor under [[RFC-AC-019]]) gains:

| Metric | Target | Rationale |
|---|---|---|
| `ttft_ms` (Anthropic) | P50 < 400 ms / P95 < 1500 ms | network-bound on Anthropic API; comparable to public observed values |
| `ttft_ms` (local llama-server) | P50 < 150 ms / P95 < 500 ms | LAN-only; prefill is the dominant cost |
| `prefill_ms` when reported | P95 < 300 ms (cloud), < 100 ms (local) | upper bound on initial scheduling latency |

These are baseline targets — initial calibration is in PR-1 §3.5.

### 3.4 Boundary with masc-mcp transport SLO

masc-mcp's `docs/PERFORMANCE-SLO.md` will gain a *consumer* SLO referencing this field once it lands. Concretely: masc-mcp computes `ttft_to_client_ms = ttft_ms (from provider) + transport_overhead_ms`, where `transport_overhead_ms` is the masc-mcp-side time from first SSE chunk arrival to flush-to-client (typically < 5ms). This composition is documented in masc-mcp's WS-D follow-up; **this agent_core RFC does not couple to masc-mcp**.

### 3.5 Initial calibration (PR-1 deliverable)

PR-1 ships a benchmark script `scripts/bench/ttft_distribution.sh` that runs 100 single-prompt completions against:

1. Anthropic (`claude-opus-4-7`) — production endpoint
2. Local llama-server (`qwen3.5-9b` for fast iteration)
3. ZAI GLM (representative non-Anthropic cloud)

Output: `ttft_ms` distribution (P50 / P95 / max / std) per provider. The SLO targets in §3.3 are calibrated from this run (the table will be updated in PR-1 if the measured baseline diverges materially).

## 4. Migration

### 4.1 Variant-shape contract

`Streaming_summary` is a closed-sum record. Adding two fields is a **breaking** change for any consumer pattern-matching on the record shape (record-disassembly with `{ chunk_count ; _ }` is forward-compatible; `{ chunk_count ; inter_chunk_ms_p50 ; inter_chunk_ms_p95 ; inter_chunk_ms_max ; kind_breakdown ; terminal }` exhaustive disassembly breaks).

Mitigation: this RFC merges **after** [[RFC-AC-019]] PR-1 lands. PR-1 is therefore a strict superset of AC-019's variant, never a pre-merge race.

### 4.2 Phase plan

| Phase | PR scope | Gate |
|---|---|---|
| 0 | This RFC | review + merge |
| 1 | `chunk_has_non_empty_delta` / `sse_event_is_first_token_signal` pure helpers + complete.ml capture points + variant extension + `scripts/bench/ttft_distribution.sh` + SLO table calibration | `dune build @runtest` clean; bench produces baseline; new fields appear in `test/test_streaming_summary.ml` synthetic completion |
| 2 (optional) | `prefill_ms` for backends beyond Anthropic — Gemini, GLM where separable | per-backend audit; `None` remains valid |

Phase 1 is a single PR — TTFT is small, narrow, and bench-validated. Phase 2 is optional and per-backend.

### 4.3 Versioning

- Variant addition: minor bump on `agent_sdk` (e.g., 0.195.0).
- Release-please entry: `feat: add TTFT and prefill_ms to Streaming_summary (RFC-AC-020)`.

## 5. Verification

### 5.1 Functional gates

1. `dune build` clean.
2. `test/test_streaming_summary.ml` (introduced in AC-019 PR-1, extended here):
   - Drive a 50-chunk synthetic completion with simulated 30 ms first-token delay; assert `ttft_ms ≈ 30` (±5 ms).
   - Drive an Anthropic-shaped stream (message_start + 50× content_block_delta); assert `prefill_ms ≈ time-to-message_start`, `ttft_ms ≈ time-to-first-content_block_delta`.
   - Drive an OpenAI-shaped stream (no separable prefill); assert `prefill_ms = None`, `ttft_ms` finite.
   - Cancel before first chunk; assert `Streaming_summary { ttft_ms = 0.0 ; terminal = `Cancelled }`.
3. `dune runtest` green.

### 5.2 Bench gate (PR-1 calibration)

`scripts/bench/ttft_distribution.sh` produces:

```
provider           P50_ms  P95_ms  max_ms  std_ms  n
anthropic          ???     ???     ???     ???     100
local_llama        ???     ???     ???     ???     100
zai_glm            ???     ???     ???     ???     100
```

PR-1 updates §3.3 table to within 2× of these measured values. If measured P95 > 2× the proposed target, the target is revised (not the measurement) and PR notes the reasoning.

## 6. Trade-offs

| For | Against |
|---|---|
| Closes the canonical chatbot-UX latency measurement gap with one minor variant extension. | Variant extension is a breaking change for exhaustive-disassembly consumers (mitigated by stacking after AC-019). |
| Composes cleanly with AC-019 — single `Streaming_summary` carries both firehose-reduced stats and first-token timing. | Two fields are weak coupling; over time, `Streaming_summary` accumulates fields. Acceptable at this stage (5 → 7 fields). |
| `prefill_ms` as `option` honours provider asymmetry without forcing a synthetic value. | Consumers must handle the `None` case; risk of "missing → zero" misinterpretation if a sink flattens it. Tests assert `None` semantics explicitly. |
| Pure-helper boundary (`chunk_has_non_empty_delta`) keeps the SSE parser SDK-independent. | Adds two pure helpers to `streaming.ml(i)` — minor API surface growth. |
| Provider-agnostic SLO table gives masc-mcp / dashboard / any consumer one place to look. | Initial table values are *proposed*; final values await PR-1 bench. Acceptable: the bench is part of PR-1. |

## 7. Open questions

- **Q1**: Should `ttft_ms` be measured from request *send* or request *connect* (TLS handshake start)? **Decision (default)**: from request *send* (post-handshake, post-headers), matching public TTFT definitions. WS-C HTTP keep-alive RFC will separately measure handshake amortisation.
- **Q2**: Should an additional `decode_tps` (decode tokens-per-second) field be included? **Decision**: out of scope for PR-1. Requires tokenizer integration; deferable.
- **Q3**: Per-tier model TTFT targets (small vs large model)? **Decision**: keep §3.3 provider-grouped; per-model breakdown is a follow-up if the bench shows large within-provider variance.
- **Q4**: Should the SDK emit a *separate* `Ttft` event for low-latency-sensitive consumers? **Decision**: **no** — re-introduces the per-event proliferation AC-019 just removed. TTFT consumers read the field from `Streaming_summary`.

## 8. Acceptance

- [ ] PR-1: helpers + capture points + variant extension + bench + SLO calibration.
- [ ] PR-1 merges *after* RFC-AC-019 PR-1 to avoid variant-shape race.
- [ ] PR-2 (optional, per-backend): non-Anthropic `prefill_ms` separation.
- [ ] masc-mcp follow-up RFC (separate, in masc-mcp repo) extends `docs/PERFORMANCE-SLO.md` with `ttft_to_client_ms` consumer SLO referencing this field.

## 9. References (evidence, external)

- [Time to First Token — IBM (2025)](https://www.ibm.com/think/topics/time-to-first-token)
- [LLM inference metrics — BentoML (2025)](https://bentoml.com/llm/inference-optimization/llm-inference-metrics)
- [Anthropic API Streaming (Messages API)](https://docs.anthropic.com/en/api/messages-streaming)
- [OpenAI Chat Completions streaming](https://platform.openai.com/docs/api-reference/chat/streaming)
- [[RFC-AC-019]] — Streaming Lifecycle Aggregation (companion RFC; this RFC extends its `Streaming_summary`).
- masc-mcp [[RFC-0098]] — Typed JSON-RPC error envelope (sibling IMPROVE-01).
