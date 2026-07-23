(** OAS bridge, relay, inference, and context metric-name constants.

    Included by {!Otel_metric_store} so existing callers keep using
    [Otel_metric_store.metric_*] bindings unchanged. *)

(** Labelled [caller]. Counts genuine inner [Eio.Time.Timeout] observations;
    MASC does not fabricate a bridge budget label. *)
val metric_oas_bridge_timeout : string

(** Labelled [caller, bucket]. [bucket] is a shared wall-clock class when a
    domain-local clock exists, or [wall_unavailable] otherwise. *)
val metric_oas_bridge_cancel : string

val metric_oas_sse_relay_retries : string
val metric_oas_sse_relay_drops : string

(** Histogram populated from OAS [InferenceTelemetry] events that are
    intentionally not relayed over SSE. Labels: [model_bucket], [phase], and
    [token_bucket]. Cardinality bound: 8 model buckets * 2 phases * 5 token
    buckets = 80 labelled series. *)
val metric_oas_sse_relay_queue_depth : string

(** Histogram populated from OAS [InferenceTelemetry] events that are
    intentionally not relayed over SSE. Labels: [model_bucket], [phase], and
    [token_bucket]. Cardinality bound: 8 model buckets * 2 phases * 5 token
    buckets = 80 labelled series. *)

(** Histogram populated from OAS [InferenceTelemetry.prompt_ms] and
    [prompt_tokens]. Labels: [model_bucket] only. *)
val metric_oas_inference_prompt_tok_per_sec : string

(** Histogram populated from OAS [InferenceTelemetry.decode_tok_s] or
    [decode_ms] plus [completion_tokens]. Labels: [model_bucket] only. *)
val metric_oas_inference_decode_tok_per_sec : string

(** Histogram populated from [AgentCompleted] [usage.cost_usd].
    Labels: [provider] and [model_bucket]. *)
val metric_oas_inference_cost_usd : string
