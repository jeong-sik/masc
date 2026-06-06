(** Otel_metric_store-backed bridge for OAS [Llm_provider.Metrics.t].

    The process-wide sink is installed early during server bootstrap so OAS
    provider callbacks update the in-process metric store. The store is then
    exported through the OTel metrics bridge. *)

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

val emit_usage_details
  :  ?input_tokens:int
  -> ?output_tokens:int
  -> ?cache_creation_input_tokens:int
  -> ?cache_read_input_tokens:int
  -> ?reasoning_output_tokens:int
  -> ?request_stream:bool
  -> ?finish_reason:string
  -> provider:string
  -> model_id:string
  -> unit
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
