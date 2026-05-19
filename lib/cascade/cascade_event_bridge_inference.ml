let json_string_opt = function
  | Some value when String.trim value <> "" -> `String value
  | _ -> `Null
;;

let payload_string_opt key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`String value) when String.trim value <> "" -> Some value
     | _ -> None)
  | _ -> None
;;

let payload_int_opt key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`Int value) -> Some value
     | Some (`Intlit value) -> int_of_string_opt value
     | _ -> None)
  | _ -> None
;;

let inference_model_bucket ~provider ~model =
  let has needle =
    String_util.contains_substring_ci provider needle
    || String_util.contains_substring_ci model needle
  in
  if has "kimi"
  then "kimi"
  else if has "claude" || has "anthropic"
  then "anthropic"
  else if has "openai" || has "gpt" || has "codex"
  then "openai"
  else if has "gemini" || has "google"
  then "gemini"
  else if has "glm" || has "zai"
  then "glm"
  else if has "qwen"
  then "qwen"
  else if has "llama"
  then "llama"
  else "other"
;;

let inference_provider_bucket ~provider ~model =
  let provider = String.trim provider in
  if provider = ""
  then inference_model_bucket ~provider ~model
  else inference_model_bucket ~provider ~model:""
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
    Prometheus.observe_histogram metric ~labels:[ "model_bucket", model_bucket ] rate
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
    Prometheus.metric_oas_inference_prompt_tok_per_sec
    ~model_bucket
    (tok_per_sec_from_ms ~tokens:prompt_tokens ~ms:prompt_ms);
  let decode_tok_s =
    match decode_tok_s with
    | Some rate when positive_finite rate -> Some rate
    | _ -> tok_per_sec_from_ms ~tokens:completion_tokens ~ms:decode_ms
  in
  observe_inference_rate
    Prometheus.metric_oas_inference_decode_tok_per_sec
    ~model_bucket
    decode_tok_s
;;

let observe_inference_cost ~provider ~model_bucket = function
  | Some cost when positive_finite cost ->
    Prometheus.observe_histogram
      Prometheus.metric_oas_inference_cost_usd
      ~labels:[ "provider", provider; "model_bucket", model_bucket ]
      cost
  | _ -> ()
;;
