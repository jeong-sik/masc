(* RFC-0166: the previous body of [inference_model_bucket] was a
   substring classifier over upstream LLM provider names. The
   server-side enumeration is removed: histogram label cardinality
   becomes 1 ("upstream") rather than a closed enum of providers.
   Per-provider partitioning, if needed, is now the dashboard's
   responsibility against the raw [provider] / [model] fields in
   the event payload, not a server-coded bucket. *)
let inference_model_bucket ~provider:_ ~model:_ = "upstream"

let inference_provider_bucket ~provider ~model:_ =
  let provider = String.trim provider in
  if provider = "" then "upstream" else provider
;;

let positive_finite value =
  value > 0.0
  &&
  match classify_float value with
  | FP_nan | FP_infinite -> false
  | FP_normal | FP_subnormal | FP_zero -> true
;;

let tok_per_sec_from_ms ~tokens ~ms =
  match tokens, ms with
  | Some tokens, Some ms when tokens > 0 && positive_finite ms ->
    Some (float_of_int tokens /. (ms /. 1000.0))
  | _ -> None
;;

let observe_inference_rate metric ~model_bucket = function
  | Some rate when positive_finite rate ->
    Otel_metric_store.observe_histogram metric ~labels:[ "model_bucket", model_bucket ] rate
  | _ -> ()
;;

let observe_inference_telemetry
      ~provider
      ~model
      ~prompt_tokens
      ~completion_tokens
      ~prompt_ms
      ~decode_ms
      ~decode_tok_s
  =
  let model_bucket = inference_model_bucket ~provider ~model in
  (* Token counts are NOT emitted here.  The authoritative per-request
     token counter is [on_token_usage] -> [Llm_metric_bridge.emit_token_usage]
     with precise {provider, model} labels.  This function retains only
     the latency/rate metrics (prompt_tok/s, decode_tok/s) that are
     unique to the [InferenceTelemetry] event payload. *)
  observe_inference_rate
    Otel_metric_store.metric_oas_inference_prompt_tok_per_sec
    ~model_bucket
    (tok_per_sec_from_ms ~tokens:prompt_tokens ~ms:prompt_ms);
  let decode_tok_s =
    match decode_tok_s with
    | Some rate when positive_finite rate -> Some rate
    | _ -> tok_per_sec_from_ms ~tokens:completion_tokens ~ms:decode_ms
  in
  observe_inference_rate
    Otel_metric_store.metric_oas_inference_decode_tok_per_sec
    ~model_bucket
    decode_tok_s
;;

let observe_inference_cost ~provider ~model_bucket = function
  | Some cost when positive_finite cost ->
    Otel_metric_store.observe_histogram
      Otel_metric_store.metric_oas_inference_cost_usd
      ~labels:[ "provider", provider; "model_bucket", model_bucket ]
      cost
  | _ -> ()
;;
