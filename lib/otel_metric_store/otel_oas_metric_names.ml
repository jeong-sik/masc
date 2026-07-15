(** OAS bridge, relay, inference, and context metric-name constants.

    Included by {!Otel_metric_store} so existing callers keep using
    [Otel_metric_store.metric_*] bindings unchanged. *)

let metric_oas_bridge_cancel = Otel_metric_store_core.declare_counter "masc_oas_bridge_cancel_total"
let metric_oas_sse_relay_retries = Otel_metric_store_core.declare_counter "masc_oas_sse_relay_retries_total"
let metric_oas_sse_relay_drops = Otel_metric_store_core.declare_counter "masc_oas_sse_relay_drops_total"
let metric_oas_sse_relay_queue_depth = "masc_oas_sse_relay_queue_depth"
let metric_oas_inference_prompt_tok_per_sec = "masc_oas_inference_prompt_tok_per_sec"
let metric_oas_inference_decode_tok_per_sec = "masc_oas_inference_decode_tok_per_sec"
let metric_oas_inference_cost_usd = "masc_oas_inference_cost_usd"
