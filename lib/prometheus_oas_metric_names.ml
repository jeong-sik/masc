(** OAS bridge, relay, inference, and context metric-name constants.

    Included by {!Prometheus} so existing callers keep using
    [Prometheus.metric_*] bindings unchanged. *)

let metric_oas_bridge_timeout = "masc_oas_bridge_timeout_total"
let metric_oas_bridge_cancel = "masc_oas_bridge_cancel_total"
let metric_oas_sse_relay_retries = "masc_oas_sse_relay_retries_total"
let metric_oas_sse_relay_drops = "masc_oas_sse_relay_drops_total"
let metric_oas_sse_relay_queue_depth = "masc_oas_sse_relay_queue_depth"
let metric_oas_inference_telemetry_tokens = "masc_oas_inference_telemetry_tokens"
let metric_oas_inference_prompt_tok_per_sec = "masc_oas_inference_prompt_tok_per_sec"
let metric_oas_inference_decode_tok_per_sec = "masc_oas_inference_decode_tok_per_sec"
let metric_oas_inference_cost_usd = "masc_oas_inference_cost_usd"
let metric_oas_context_overflow_ratio = "masc_oas_context_overflow_ratio"
let metric_oas_context_compaction_total = "masc_oas_context_compaction_total"
