(** Model_inference_metrics — per-model aggregate inference statistics.

    Reads keeper [decisions.jsonl] files plus inference-level
    [costs.jsonl] samples, extracts telemetry entries within a
    configurable time window, and computes per-model aggregates:
    avg/p50/p95 tok/s, avg/p50/p95 latency, total reasoning tokens,
    cost attribution, tool usage, and success/error rates.

    Closes #5775. @since 2.259.0
    Extended with cost/tool/error metrics: @since 2.270.0

    {1 Internal structure}

    Stage 04 of the godfile decomposition build plan
    (docs/audit/2026-05-18-godfile-decomposition-build-plan.html, Lane
    A) split the previous 1958-line implementation into four
    facade-internal sibling modules. The public signature in
    [model_inference_metrics.mli] is unchanged.

    - {!Model_inference_metrics_entry} — types and arithmetic / JSON
      helpers shared across the parser, reader, aggregate, and JSON
      layers.
    - {!Model_inference_metrics_parser} — [parse_telemetry_entry] /
      [parse_cost_entry] and the model-attribution helpers they share.
    - {!Model_inference_metrics_reader} — JSONL file readers,
      decision/cost merge, and coverage helpers.
    - {!Model_inference_metrics_aggregate} — per-model aggregation,
      time bucketing, public [compute*] entry points, and per-provider
      rollups.
    - {!Model_inference_metrics_json} — JSON serialization, keeper
      prompt feedback rendering, and the composed cost-latency
      endpoint payload. *)

include Model_inference_metrics_entry
include Model_inference_metrics_parser
include Model_inference_metrics_reader
include Model_inference_metrics_aggregate
include Model_inference_metrics_json
