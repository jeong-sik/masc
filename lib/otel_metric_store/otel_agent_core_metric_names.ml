(** AGENT_CORE bridge, relay, inference, and context metric-name constants.

    Included by {!Otel_metric_store} so existing callers keep using
    [Otel_metric_store.metric_*] bindings unchanged. *)

let metric_agent_core_bridge_timeout = Otel_metric_store_core.declare_counter "masc_agent_core_bridge_timeout_total"
let metric_agent_core_bridge_cancel = Otel_metric_store_core.declare_counter "masc_agent_core_bridge_cancel_total"
let metric_agent_core_sse_relay_retries = Otel_metric_store_core.declare_counter "masc_agent_core_sse_relay_retries_total"
let metric_agent_core_sse_relay_drops = Otel_metric_store_core.declare_counter "masc_agent_core_sse_relay_drops_total"
let metric_agent_core_sse_relay_queue_depth =
  Otel_metric_store_core.declare_gauge "masc_agent_core_sse_relay_queue_depth"
;;
let metric_agent_core_inference_prompt_tok_per_sec = "masc_agent_core_inference_prompt_tok_per_sec"
let metric_agent_core_inference_decode_tok_per_sec = "masc_agent_core_inference_decode_tok_per_sec"
let metric_agent_core_inference_cost_usd = "masc_agent_core_inference_cost_usd"
