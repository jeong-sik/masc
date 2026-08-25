(** Otel_metric_store-backed bridge for AGENT_CORE [Llm_provider.Metrics.t].

    The process-wide sink is installed early during server bootstrap so AGENT_CORE
    provider callbacks update the in-process metric store. The store is then
    exported through the OTel metrics bridge. *)

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

val emit_cache_hit : model_id:string -> unit
val emit_error
  :  model_id:string
  -> message:string
  -> reason:Llm_provider.Metrics.error_reason
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

val make_sink : unit -> Llm_provider.Metrics.t
val install : unit -> unit
