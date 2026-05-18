(** Runtime schema, admission queue, agent-health, and GC sampler
    metric-name constants.

    Included by {!Prometheus} so existing callers keep using
    [Prometheus.metric_*] bindings unchanged. *)

let metric_mcp_tool_schema_count = "masc_mcp_tool_schema_count"
let metric_mcp_tool_schema_tokens_approx = "masc_mcp_tool_schema_tokens_approx"
let metric_inference_queue_depth = "masc_inference_queue_depth"
let metric_inference_queue_inflight = "masc_inference_queue_inflight"
let metric_inference_queue_acquired = "masc_inference_queue_acquired_total"
let metric_inference_queue_wait = "masc_inference_queue_wait_seconds"
let metric_inference_queue_cancelled = "masc_inference_queue_cancelled_total"
let metric_inference_queue_rejected = "masc_inference_queue_rejected_total"
let metric_inference_queue_max_concurrent = "masc_inference_queue_max_concurrent"
let metric_agent_heartbeat_age_seconds = "masc_agent_heartbeat_age_seconds"
let metric_agent_stale_total = "masc_agent_stale_total"
let metric_gc_minor_words = "masc_gc_minor_words"
let metric_gc_major_words = "masc_gc_major_words"
let metric_gc_heap_words = "masc_gc_heap_words"
let metric_gc_live_words = "masc_gc_live_words"
let metric_gc_compactions = "masc_gc_compactions"
let metric_gc_promoted_words = "masc_gc_promoted_words"
let metric_memory_usage_bytes = "masc_memory_usage_bytes"
