(** Retired Otel_metric_store bridge for OAS [Llm_provider.Metrics.t].

    The process-wide sink remains installable so callers keep their
    initialization order, but callbacks are intentionally no-op until the OTel
    replacement owns this boundary. *)

val http_status_metric : string
val fallback_triggered_metric : string

val emit_http_status
  :  provider:string
  -> model_id:string
  -> status:int
  -> unit

val emit_request_latency
  :  ?provider:string
  -> model_id:string
  -> latency_ms:int
  -> unit
  -> unit

val emit_capability_drop : model_id:string -> field:string -> unit
val emit_cache_hit : model_id:string -> unit
val emit_cache_miss : model_id:string -> unit
val emit_request_start : model_id:string -> unit
val emit_error : model_id:string -> error:string -> unit
val emit_retry : provider:string -> model_id:string -> attempt:int -> unit

val emit_circuit_state
  :  provider:string
  -> model_id:string
  -> provider_key:string
  -> state:Llm_provider.Metrics.circuit_state
  -> unit

val emit_token_usage
  :  provider:string
  -> model_id:string
  -> input_tokens:int
  -> output_tokens:int
  -> unit

val emit_tool_calls
  :  provider:string
  -> model_id:string
  -> count:int
  -> unit

val emit_streaming_first_chunk
  :  provider:string
  -> model_id:string
  -> ttfrc_ms:float
  -> unit

val emit_streaming_chunk
  :  provider:string
  -> model_id:string
  -> chunk_index:int
  -> inter_chunk_ms:float
  -> unit

val emit_fallback_triggered : kind:string -> detail:string -> unit
val make_sink : unit -> Llm_provider.Metrics.t
val init : base_path:string -> unit
val install : unit -> unit
