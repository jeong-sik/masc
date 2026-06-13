let http_status_metric = "retired_otel_metric_store_llm_provider_http_status_total"
let fallback_triggered_metric = "retired_otel_metric_store_fallback_triggered_total"

let emit_http_status ~provider:_ ~model_id:_ ~status:_ = ()
let emit_request_latency ?provider:_ ~model_id:_ ~latency_ms:_ () = ()
let emit_capability_drop ~model_id:_ ~field:_ = ()
let emit_cache_hit ~model_id:_ = ()
let emit_cache_miss ~model_id:_ = ()
let emit_request_start ~model_id:_ = ()
let emit_error ~model_id:_ ~error:_ = ()
let emit_retry ~provider:_ ~model_id:_ ~attempt:_ = ()

let emit_circuit_state
      ~provider:_
      ~model_id:_
      ~provider_key:_
      ~state:_
  =
  ()
;;

let emit_token_usage ~provider:_ ~model_id:_ ~input_tokens:_ ~output_tokens:_ =
  ()
;;

let emit_tool_calls ~provider:_ ~model_id:_ ~count:_ = ()

let emit_streaming_first_chunk ~provider:_ ~model_id:_ ~ttfrc_ms:_ = ()

let emit_streaming_chunk
      ~provider:_
      ~model_id:_
      ~chunk_index:_
      ~inter_chunk_ms:_
  =
  ()
;;

let emit_fallback_triggered ~kind:_ ~detail:_ = ()

let make_sink () : Llm_provider.Metrics.t = Llm_provider.Metrics.noop

let init ~base_path:_ = ()

let install () = Llm_provider.Metrics.set_global (make_sink ())
