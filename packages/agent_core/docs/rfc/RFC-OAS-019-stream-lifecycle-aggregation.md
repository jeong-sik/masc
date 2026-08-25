# RFC-OAS-019: Stream Lifecycle Aggregation

| | |
|---|---|
| Status | Draft |
| Author | vincent (with Claude analysis) |
| Created | 2026-05-14 |
| Target | `agent_sdk` (oas) |
| Sibling | RFC-OAS-018 (provider-model-catalog-externalization) |

## 0. Summary

`Telemetry_event.Streaming_chunk_n` is currently emitted once per streamed chunk from `lib/llm_provider/complete.ml:1058-1061`. A single completion produces hundreds of these records (observed `chunk_index: 314` on one attempt), each carrying only `provider`, `model`, `chunk_index`, `inter_chunk_ms`. Downstream telemetry sinks that persist `Custom("telemetry_event", json)` payloads receive raw chunk records, drowning every higher-level event.

This RFC replaces per-chunk emission with a single typed `Streaming_summary` variant emitted at stream finalize. Prometheus metric paths (if any) are untouched — the variant change is on the OAS `Event_bus` telemetry surface only. Per-chunk dispatch internal to the SDK (debouncing, liveness, parser progress) is preserved; only the *external* event variant changes.

## 1. Problem (line-pinned, 2026-05-14 main `5e68d21d`)

### 1.1 Per-chunk emission

`lib/llm_provider/complete.ml:1058-1061`:

```ocaml
let inter_chunk_ms = (now -. !last_chunk_t) *. 1000.0 in
(* ... *)
(Telemetry_event.Streaming_chunk_n
   { provider; model; chunk_index = !chunk_counter; inter_chunk_ms });
```

The counter increments per chunk; the emit fires synchronously. A 300-chunk completion publishes 300 separate `Custom("telemetry_event", json)` payloads on `Event_bus`.

### 1.2 Variant definition

`lib/llm_provider/telemetry_event.ml:20-24`:

```ocaml
| Streaming_chunk_n of
    { provider : string
    ; model : string
    ; chunk_index : int
    ; inter_chunk_ms : float
    }
```

Registered in `lib/telemetry_sca_registry.ml:24` as a known signal (registry removed 2026-07-21, test-only surface cut). Serialized via `lib/telemetry_bus.ml:25` (`Event_bus.Custom("telemetry_event", json)`).

### 1.3 Observable cost

- A 300-chunk record-set per completion consumes 300 slots in every matching
  subscriber's explicitly sized bounded queue. Depending on that subscriber's
  chosen overflow behavior, the excess evicts older observations or discards
  newer ones; the bus records either outcome in `dropped_total`.
- Downstream sinks that persist raw payloads inflate by O(chunks). The signal-to-record ratio approaches one informational record per attempt buried in hundreds of indistinguishable chunk records.
- No aggregation aid is provided: each record has only the latest gap, not the lifecycle distribution (TTFT, p50/p95/max inter-chunk, kind breakdown, terminal cause). Operators reading the bus cannot reconstruct what the stream actually did without re-aggregating downstream.

## 2. Goal

1. Replace `Streaming_chunk_n` external emissions with a single `Streaming_summary` event per stream lifecycle, carrying the distribution that operators actually need.
2. Keep SDK-internal per-chunk dispatch (liveness gate, SSE parser hooks) unchanged.
3. Stay within the `agent_sdk` boundary — no assumption about downstream sink identity, schema, or storage path. The SDK publishes; consumers adapt.

## 3. Non-goals

- Touching prometheus or any other in-SDK metric path. If those exist, they remain at chunk granularity for SRE traceability. This RFC scopes the change to `Event_bus` external emission.
- Adding cost-per-stream estimates to the summary (`cost_usd_estimate`) — defer to a billing-focused RFC after `pricing.ml` externalization (RFC-OAS-018).
- Rewriting SDK-internal per-chunk typed-value call sites that read `Streaming_chunk_n` for liveness or progress. Internal call sites stay on the typed value path; only `telemetry_bus.publish` of the chunk variant is removed.

## 4. Design

### 4.1 New variant — `Streaming_summary`

Add to `lib/llm_provider/telemetry_event.ml`:

```ocaml
| Streaming_summary of
    { provider : string
    ; model : string
    ; chunk_count : int
    ; kind_breakdown :
        { thinking : int
        ; answer : int
        ; tool_call_start : int
        ; tool_call_arg_delta : int
        ; tool_call_complete : int
        ; substrate : int
        ; heartbeat : int
        ; done_ : int
        }
    ; ttft_ms : float option        (* None if no first chunk observed *)
    ; total_ms : float
    ; inter_chunk_ms_p50 : float
    ; inter_chunk_ms_p95 : float
    ; inter_chunk_ms_max : float
    ; terminal :
        [ `Done | `Cancelled | `Error of string ]
    }
```

Register the signal in `lib/telemetry_sca_registry.ml` (registry removed 2026-07-21 — a revival of this phase must reintroduce a typed registry first). Yojson derivation mirrors existing variants.

### 4.2 Accumulator in `complete.ml`

The current per-chunk emit site (`lib/llm_provider/complete.ml:1058-1061`) is replaced by accumulator updates inside the stream loop:

- Maintain `kind_breakdown` counters, `chunk_count`, `last_chunk_t`, a running `inter_chunk` reservoir (or rolling histogram for percentiles), `first_chunk_t` (for TTFT), and `terminal` (set on Done / Cancelled / Error).
- No external `Telemetry_event` is published while the stream is open.

At stream lifecycle end (the existing exit path that today completes a completion or releases the SSE switch), publish exactly one `Telemetry_event.Streaming_summary` via `Telemetry_bus.publish`.

### 4.3 Percentile computation

`inter_chunk_ms_p50/p95/max` use a fixed-size reservoir (default 256 samples) with deterministic sampling for reproducibility. For chunk_count ≤ reservoir size the values are exact; above that they are estimates with sampling error bounded by reservoir size. Implementation is local to `complete.ml` — no new dependency.

### 4.4 Terminal classification

| Stream exit | `terminal` |
|---|---|
| Normal completion (`Done` chunk) | `` `Done`` |
| `Eio.Cancel.Cancelled` propagated | `` `Cancelled`` |
| Provider wire error or parse failure | `` `Error msg`` |

Caller never sees a partial summary: if `complete` raises, the summary is published with `` `Error`` before re-raising (`Fun.protect` style, exit-safe within Eio rules).

### 4.5 Removal of `Streaming_chunk_n` *external emission*

`Telemetry_bus.publish` of `Streaming_chunk_n` is removed from `complete.ml`. The variant **may** be retained in `telemetry_event.ml` for one release window if SDK-internal callers exist, with a deprecation note; preference is direct removal to avoid string-classifier surfaces (CLAUDE.md §Workaround Rejection Bar §2). The decision hinges on §6.1 audit.

## 5. Migration

### 5.1 SDK-internal audit (must complete before Phase 1 merge)

- `rg 'Streaming_chunk_n' lib/ test/ bin/` — enumerate every read site.
- If any internal site relies on the per-chunk variant for control flow (liveness, dispatcher), move that logic onto the accumulator path inside `complete.ml`. External `Streaming_chunk_n` publish is *not* a substitute for internal callbacks.
- Test sites: keep `Streaming_chunk_n` as a permitted value in test fixtures only until the variant itself is removed (Phase 2).

### 5.2 External consumer guidance (SDK independence preserved)

The SDK does not enumerate or name downstream sinks. Release notes describe the variant change in `agent_sdk` terms only:

> Starting `agent_sdk` 0.194.0, `Telemetry_event.Streaming_chunk_n` is no longer published on `Event_bus`. A new `Streaming_summary` variant is published once per stream lifecycle. Consumers persisting `Event_bus.Custom("telemetry_event", json)` should update parsers to recognize `Streaming_summary` and may remove `Streaming_chunk_n` from their accepted set.

Downstream repos that vendor or depend on `agent_sdk` are responsible for their own consumer-side changes; this RFC does not coordinate them.

### 5.3 Versioning

- Variant removal is breaking on the `Event_bus.Custom("telemetry_event", json)` consumer schema. Bump minor version (`0.194.0`).
- Release-please (RFC-OAS-010) entry: `feat!: replace per-chunk Streaming_chunk_n with Streaming_summary (RFC-OAS-019)`.

## 6. Verification

### 6.1 Audit gates (pre-merge)

1. `rg 'Streaming_chunk_n' lib/ test/ bin/` enumerates *every* site. PR description lists each site with a one-line classification (read | publish | test fixture).
2. No site outside `complete.ml` calls `Telemetry_bus.publish` with `Streaming_chunk_n`. (Should be true today; verify.)
3. For every read site, either the read is moved onto the new accumulator or the site is documented as test-only and scheduled for removal in Phase 2.

### 6.2 Functional gates

1. `dune build` clean.
2. New `test/test_streaming_summary.ml`:
   - Drive a 100-chunk synthetic completion; assert exactly one `Streaming_summary` is published.
   - `sum(kind_breakdown.*) = chunk_count`.
   - `inter_chunk_ms_max >= inter_chunk_ms_p95 >= inter_chunk_ms_p50 >= 0`.
   - Cancel mid-stream; assert `terminal = `Cancelled` and exactly one publish (no leak).
   - Provider error mid-stream; assert `terminal = `Error _` and exactly one publish before re-raise.
3. `dune runtest` green.

### 6.3 Bus-volume regression

Existing tests that count `Event_bus` events from a completion: expected volume drops by O(chunks). Update assertions.

## 7. Rollout

| Phase | PR scope | Gate |
|---|---|---|
| 0 | This RFC | review + merge |
| 1 | `Streaming_summary` variant + accumulator + per-chunk publish removal + tests | §6.1, §6.2, §6.3 |
| 2 (optional, +1 release) | Remove `Streaming_chunk_n` variant entirely from `telemetry_event.ml` after consumer migration window (`telemetry_sca_registry.ml` already removed 2026-07-21) | grep 0 hits across SDK and known consumers |

Phase 2 is optional: keeping the variant declared but never published is a *string-classifier-permits-extension* shape (CLAUDE.md §Workaround Rejection Bar §2). Preference is direct removal in Phase 1 if §6.1 audit confirms zero internal reads.

## 8. Risks & alternatives

### 8.1 Risk — exit path branches publishing twice

`complete.ml` has multiple exit paths (normal Done, switch cancel, exception). Mitigation: a single `published` ref + `Fun.protect`-style finalizer in the outer Eio switch; published-once invariant covered by §6.2 #3, #4.

### 8.2 Risk — reservoir percentile bias on very long streams

For `chunk_count >> 256`, p95 sampling error grows. Mitigation: deterministic reservoir keeps results reproducible across replays; if exact percentiles are later required, swap reservoir for HDR histogram in a follow-up RFC without changing the variant shape.

### 8.3 Alternative — keep `Streaming_chunk_n` and add `Streaming_summary` alongside

Rejected. Adding the summary without removing the chunk emission leaves the noise in place — sinks still receive 300 chunk records plus 1 summary. The point of this RFC is sink-volume reduction; coexistence defeats it. (Failing CLAUDE.md §Workaround Rejection Bar §1, telemetry-as-fix.)

### 8.4 Alternative — sample 1-of-N chunks instead of removing

Rejected. Sampling preserves a degraded version of the same noise pattern and forces downstream consumers to reason about sampling rate in addition to lifecycle. The lifecycle summary is the structural target.

## 9. Open items

- Whether `Streaming_summary` should also carry the first-token text fragment for human triage (could be PII / large). Default: no, defer to a logging-focused follow-up.
- Whether `terminal` deserves a richer error classification (timeout, parse_failed, http_5xx) — defer; `string` payload is forward-compatible for refinement. **Scope note:** this open item concerns only the *telemetry* `Streaming_summary.terminal` field. The *caller-facing error return* of a streamed completion is now typed independently: a provider-reported mid-stream error (`SSEError`) is carried as a typed `Types.stream_error` and converges onto the same `Http_client.HttpError {code; body}` → `Retry.classify_error` path as a non-streaming error (`Complete.http_error_of_stream_error` + `Retry.status_of_provider_error_type`), so a streamed rate-limit / auth / server error reaches the consumer as a typed `sdk_error` rather than `NetworkError {Unknown}`. Typing the telemetry `terminal` string remains deferred and is the separate follow-up; do not assume the return path is still string-classified.
- Reservoir size 256 is a guess; revisit after first deployment metrics.
