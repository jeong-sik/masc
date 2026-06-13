module Metrics = Llm_provider.Metrics

let http_status_metric = Otel_metric_store.metric_llm_provider_http_status
let fallback_triggered_metric = Otel_metric_store.metric_fallback_triggered

let provider_cache : (string, string) Hashtbl.t = Hashtbl.create 64
let provider_cache_mu = Stdlib.Mutex.create ()

let with_provider_cache_lock f =
  Stdlib.Mutex.lock provider_cache_mu;
  Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock provider_cache_mu) f
;;

let contains_substring haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  if needle_len = 0 then true
  else
    let rec loop i =
      i + needle_len <= haystack_len
      && (String.equal (String.sub haystack i needle_len) needle || loop (i + 1))
    in
    loop 0
;;

let note_provider ~model_id ~provider =
  if (not (String.equal model_id "")) && not (String.equal provider "") then
    with_provider_cache_lock (fun () ->
      Hashtbl.replace provider_cache model_id provider)
;;

let provider_seen_for_model ~model_id =
  with_provider_cache_lock (fun () -> Hashtbl.find_opt provider_cache model_id)
;;

let model_labels ~model_id = [ ("model", model_id) ]
let provider_model_labels ~provider ~model_id = [ ("provider", provider); ("model", model_id) ]

let genai_operation_name = "chat"

let genai_provider_for_model ~model_id =
  if String.equal model_id "" then "unknown"
  else
    match provider_seen_for_model ~model_id with
    | Some provider -> provider
    | None -> "unknown"
;;

let genai_base_labels ~provider ~model_id =
  [ Otel_genai.Attr_key.gen_ai_operation_name, genai_operation_name
  ; Otel_genai.Attr_key.gen_ai_provider_name, provider
  ; Otel_genai.Attr_key.gen_ai_request_model, model_id
  ]
;;

let genai_token_labels ~provider ~model_id ~token_type =
  genai_base_labels ~provider ~model_id
  @ [ Otel_genai.Attr_key.gen_ai_token_type, token_type ]
;;

let inc_counter ?(delta = 1.0) name ~labels =
  Otel_metric_store.inc_counter name ~labels ~delta ()
;;

let set_gauge name ~labels value = Otel_metric_store.set_gauge name ~labels value

let observe_seconds name ~labels seconds =
  Otel_metric_store.observe_histogram name ~labels seconds
;;

let observe_genai_seconds name ~provider ~model_id seconds =
  observe_seconds name ~labels:(genai_base_labels ~provider ~model_id) seconds
;;

let observe_genai_tokens ~provider ~model_id ~token_type tokens =
  Otel_metric_store.observe_histogram
    Otel_genai.Metric_name.client_token_usage
    ~labels:(genai_token_labels ~provider ~model_id ~token_type)
    (float_of_int tokens)
;;

let add_genai_attrs attrs =
  Otel_spans.add_attrs
    ~attrs:
      ((Otel_genai.Attr_key.gen_ai_operation_name, `String genai_operation_name)
       :: attrs)
    ()
;;

let positive_int_attrs attrs =
  attrs
  |> List.filter_map (fun (key, value_opt) ->
    match value_opt with
    | Some value when value > 0 -> Some (key, `Int value)
    | Some _ | None -> None)
;;

let non_empty_string_attr key = function
  | Some value when not (String.equal value "") -> [ key, `String value ]
  | Some _ | None -> []
;;

let bool_attr key = function
  | Some value -> [ key, `Bool value ]
  | None -> []
;;

let emit_usage_details
      ?input_tokens
      ?output_tokens
      ?cache_creation_input_tokens
      ?cache_read_input_tokens
      ?reasoning_output_tokens
      ?request_stream
      ?finish_reason
      ~provider
      ~model_id
      ()
  =
  let detail_attrs =
    positive_int_attrs
      [ Otel_genai.Attr_key.gen_ai_usage_input_tokens, input_tokens
      ; Otel_genai.Attr_key.gen_ai_usage_output_tokens, output_tokens
      ; ( Otel_genai.Attr_key.gen_ai_usage_cache_creation_input_tokens
        , cache_creation_input_tokens )
      ; Otel_genai.Attr_key.gen_ai_usage_cache_read_input_tokens, cache_read_input_tokens
      ; ( Otel_genai.Attr_key.gen_ai_usage_reasoning_output_tokens
        , reasoning_output_tokens )
      ]
  in
  let finish_attrs =
    non_empty_string_attr
      Otel_genai.Attr_key.masc_gen_ai_response_finish_reason
      finish_reason
  in
  let request_stream_attrs =
    bool_attr Otel_genai.Attr_key.gen_ai_request_stream request_stream
  in
  match detail_attrs, finish_attrs, request_stream_attrs with
  | [], [], [] -> ()
  | _ ->
    note_provider ~model_id ~provider;
    let attrs =
      [ Otel_genai.Attr_key.gen_ai_provider_name, `String provider
      ; Otel_genai.Attr_key.gen_ai_request_model, `String model_id
      ; Otel_genai.Attr_key.gen_ai_response_model, `String model_id
      ]
      @ detail_attrs
      @ finish_attrs
      @ request_stream_attrs
    in
    add_genai_attrs attrs;
    Otel_spans.add_event
      ~name:Otel_genai.Event_name.client_inference_operation_details
      ~attrs:
        ((Otel_genai.Attr_key.gen_ai_operation_name, `String genai_operation_name)
         :: attrs)
      ()
;;

let emit_http_status ~provider ~model_id ~status =
  note_provider ~model_id ~provider;
  inc_counter
    http_status_metric
    ~labels:
      [ ("provider", provider)
      ; ("model", model_id)
      ; ("status", string_of_int status)
      ]
;;

let provider_for_latency provider_opt ~model_id =
  match provider_opt with
  | Some provider when not (String.equal provider "") ->
    note_provider ~model_id ~provider;
    provider, None
  | _ ->
    if String.equal model_id ""
    then "unknown", Some "provider_unknown_no_model_id"
    else (
      match provider_seen_for_model ~model_id with
      | Some provider -> provider, None
      | None -> "unknown", Some "provider_unknown_cache_miss")
;;

let emit_latency_clamp ~provider ~model_id ~reason =
  inc_counter
    Otel_metric_store.metric_llm_provider_request_latency_clamped
    ~labels:[ ("provider", provider); ("model", model_id); ("reason", reason) ]
;;

let emit_request_latency ?provider ~model_id ~latency_ms () =
  let provider, provider_reason = provider_for_latency provider ~model_id in
  Option.iter
    (fun reason -> emit_latency_clamp ~provider ~model_id ~reason)
    provider_reason;
  let seconds =
    if latency_ms <= 0
    then (
      emit_latency_clamp ~provider ~model_id ~reason:"non_positive_latency_ms";
      0.001)
    else float_of_int latency_ms /. 1000.0
  in
  observe_seconds
    Otel_metric_store.metric_llm_provider_request_latency
    ~labels:(provider_model_labels ~provider ~model_id)
    seconds;
  observe_genai_seconds
    Otel_genai.Metric_name.client_operation_duration
    ~provider
    ~model_id
    seconds
;;

let emit_capability_drop ~model_id ~field =
  inc_counter
    Otel_metric_store.metric_llm_provider_capability_drops
    ~labels:[ ("model", model_id); ("field", field) ]
;;

let emit_cache_hit ~model_id =
  inc_counter
    Otel_metric_store.metric_llm_provider_cache_hits
    ~labels:(model_labels ~model_id)
;;

let emit_cache_miss ~model_id =
  inc_counter
    Otel_metric_store.metric_llm_provider_cache_misses
    ~labels:(model_labels ~model_id)
;;

let emit_request_start ~model_id =
  inc_counter
    Otel_metric_store.metric_llm_provider_requests_started
    ~labels:(model_labels ~model_id)
;;

let error_reason error =
  let error = String.lowercase_ascii error in
  if contains_substring error "429" || contains_substring error "rate limit"
  then "rate_limit"
  else if
    contains_substring error "timeout"
    || contains_substring error "timed out"
    || contains_substring error "deadline"
  then "timeout"
  else "unknown"
;;

let emit_error ~model_id ~error =
  let reason = error_reason error in
  let provider = genai_provider_for_model ~model_id in
  inc_counter
    Otel_metric_store.metric_llm_provider_errors
    ~labels:(model_labels ~model_id);
  inc_counter
    Otel_metric_store.metric_llm_provider_errors_by_reason
    ~labels:[ ("model", model_id); ("error_reason", reason) ];
  Otel_spans.record_error
    ~message:error
    ~error_type:reason
    ~attrs:
      [ Otel_genai.Attr_key.gen_ai_operation_name, `String genai_operation_name
      ; Otel_genai.Attr_key.gen_ai_provider_name, `String provider
      ; Otel_genai.Attr_key.gen_ai_request_model, `String model_id
      ]
    ()
;;

let emit_retry ~provider ~model_id ~attempt =
  note_provider ~model_id ~provider;
  inc_counter
    Otel_metric_store.metric_llm_provider_retries
    ~labels:
      [ ("provider", provider)
      ; ("model", model_id)
      ; ("attempt", string_of_int attempt)
      ]
;;

let emit_circuit_state ~provider ~model_id ~provider_key ~state =
  note_provider ~model_id ~provider;
  set_gauge
    Otel_metric_store.metric_llm_provider_circuit_state
    ~labels:
      [ ("provider", provider)
      ; ("model", model_id)
      ; ("provider_key", provider_key)
      ]
    (float_of_int (Metrics.circuit_state_to_int state))
;;

let emit_token_usage ~provider ~model_id ~input_tokens ~output_tokens =
  note_provider ~model_id ~provider;
  let labels = provider_model_labels ~provider ~model_id in
  inc_counter
    Otel_metric_store.metric_llm_provider_input_tokens
    ~labels
    ~delta:(float_of_int input_tokens);
  inc_counter
    Otel_metric_store.metric_llm_provider_output_tokens
    ~labels
    ~delta:(float_of_int output_tokens);
  observe_genai_tokens ~provider ~model_id ~token_type:"input" input_tokens;
  observe_genai_tokens ~provider ~model_id ~token_type:"output" output_tokens;
  emit_usage_details ~provider ~model_id ~input_tokens ~output_tokens ()
;;

let emit_tool_calls ~provider ~model_id ~count =
  note_provider ~model_id ~provider;
  if count > 0 then
    inc_counter
      Otel_metric_store.metric_llm_provider_tool_calls
      ~labels:(provider_model_labels ~provider ~model_id)
      ~delta:(float_of_int count)
;;

let invalid_ms_reason value =
  match classify_float value with
  | FP_nan | FP_infinite -> Some "not_finite"
  | _ when value <= 0.0 -> Some "non_positive"
  | _ -> None
;;

let streaming_attrs ~provider ~model_id extra =
  [ Otel_genai.Attr_key.gen_ai_provider_name, `String provider
  ; Otel_genai.Attr_key.gen_ai_request_model, `String model_id
  ; Otel_genai.Attr_key.gen_ai_request_stream, `Bool true
  ]
  @ extra
;;

let emit_streaming_first_chunk ~provider ~model_id ~ttfrc_ms =
  note_provider ~model_id ~provider;
  match invalid_ms_reason ttfrc_ms with
  | Some reason ->
    inc_counter
      Otel_metric_store.metric_llm_provider_streaming_first_chunk_invalid
      ~labels:[ ("provider", provider); ("model", model_id); ("reason", reason) ]
  | None ->
    observe_seconds
      Otel_metric_store.metric_llm_provider_streaming_first_chunk
      ~labels:(provider_model_labels ~provider ~model_id)
      (ttfrc_ms /. 1000.0);
    observe_genai_seconds
      Otel_genai.Metric_name.client_operation_time_to_first_chunk
      ~provider
      ~model_id
      (ttfrc_ms /. 1000.0);
    add_genai_attrs
      [ Otel_genai.Attr_key.gen_ai_provider_name, `String provider
      ; Otel_genai.Attr_key.gen_ai_request_model, `String model_id
      ; Otel_genai.Attr_key.gen_ai_request_stream, `Bool true
      ; Otel_genai.Attr_key.gen_ai_response_time_to_first_chunk
        , `Float (ttfrc_ms /. 1000.0)
      ];
    Otel_spans.add_event
      ~name:"ttfrc.received"
      ~attrs:
        (streaming_attrs
           ~provider
           ~model_id
           [ "masc.gen_ai.streaming.ttfrc_ms", `Float ttfrc_ms ])
      ()
;;

let emit_streaming_chunk ~provider ~model_id ~chunk_index ~inter_chunk_ms =
  note_provider ~model_id ~provider;
  match invalid_ms_reason inter_chunk_ms with
  | Some reason ->
    inc_counter
      Otel_metric_store.metric_llm_provider_streaming_inter_chunk_invalid
      ~labels:[ ("provider", provider); ("model", model_id); ("reason", reason) ]
  | None ->
    observe_seconds
      Otel_metric_store.metric_llm_provider_streaming_inter_chunk
      ~labels:(provider_model_labels ~provider ~model_id)
      (inter_chunk_ms /. 1000.0);
    observe_genai_seconds
      Otel_genai.Metric_name.client_operation_time_per_output_chunk
      ~provider
      ~model_id
      (inter_chunk_ms /. 1000.0);
    Otel_spans.add_event
      ~name:"streaming.chunk"
      ~attrs:
        (streaming_attrs
           ~provider
           ~model_id
           [ "masc.gen_ai.streaming.chunk_index", `Int chunk_index
           ; "masc.gen_ai.streaming.inter_chunk_ms", `Float inter_chunk_ms
           ])
      ()
;;

let emit_fallback_triggered ~kind ~detail =
  inc_counter fallback_triggered_metric ~labels:[ ("kind", kind); ("detail", detail) ]
;;

let make_sink () : Metrics.t =
  { Metrics.
    on_cache_hit = emit_cache_hit
  ; on_cache_miss = emit_cache_miss
  ; on_request_start = emit_request_start
  ; on_request_end =
      (fun ~model_id ~latency_ms ->
        match latency_ms with
        | Some latency_ms -> emit_request_latency ~model_id ~latency_ms ()
        | None -> ())
  ; on_error = emit_error
  ; on_http_status = emit_http_status
  ; on_circuit_state = emit_circuit_state
  ; on_capability_drop = emit_capability_drop
  ; on_retry = emit_retry
  ; on_token_usage = emit_token_usage
  ; on_tool_calls = emit_tool_calls
  ; on_streaming_first_chunk = emit_streaming_first_chunk
  ; on_streaming_chunk = emit_streaming_chunk
  }
;;

let init ~base_path:_ = ()

let install () = Metrics.set_global (make_sink ())
