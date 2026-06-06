module Bridge = Masc.Llm_metric_bridge
module Metrics = Masc.Otel_metric_store

let metric name ~labels =
  Metrics.metric_value_or_zero name ~labels ()

let check_metric_delta label name ~labels ~before ~delta =
  Alcotest.(check (float 0.0001))
    label
    (before +. delta)
    (metric name ~labels)

let same_labels expected actual =
  List.sort compare expected = List.sort compare actual
;;

let find_otel_sample name ~labels =
  Metrics.otel_samples_for_test ()
  |> List.find_opt (fun (sample : Otel_metrics.sample) ->
    String.equal sample.name name && same_labels labels sample.labels)
;;

let test_metric_names_stable () =
  Alcotest.(check string)
    "cache hits metric"
    "masc_llm_provider_cache_hits_total"
    Metrics.metric_llm_provider_cache_hits;
  Alcotest.(check string)
    "cache misses metric"
    "masc_llm_provider_cache_misses_total"
    Metrics.metric_llm_provider_cache_misses;
  Alcotest.(check string)
    "requests started metric"
    "masc_llm_provider_requests_started_total"
    Metrics.metric_llm_provider_requests_started;
  Alcotest.(check string)
    "errors metric"
    "masc_llm_provider_errors_total"
    Metrics.metric_llm_provider_errors;
  Alcotest.(check string)
    "errors by reason metric"
    "masc_llm_provider_errors_by_reason_total"
    Metrics.metric_llm_provider_errors_by_reason;
  Alcotest.(check string)
    "retries metric"
    "masc_llm_provider_retries_total"
    Metrics.metric_llm_provider_retries;
  Alcotest.(check string)
    "input tokens metric"
    "masc_llm_provider_input_tokens_total"
    Metrics.metric_llm_provider_input_tokens;
  Alcotest.(check string)
    "output tokens metric"
    "masc_llm_provider_output_tokens_total"
    Metrics.metric_llm_provider_output_tokens;
  Alcotest.(check string)
    "tool calls metric"
    "masc_llm_provider_tool_calls_total"
    Metrics.metric_llm_provider_tool_calls;
  Alcotest.(check string)
    "circuit state metric"
    "masc_llm_provider_circuit_state"
    Metrics.metric_llm_provider_circuit_state;
  Alcotest.(check string)
    "request latency clamped metric"
    "masc_llm_provider_request_latency_clamped_total"
    Metrics.metric_llm_provider_request_latency_clamped;
  Alcotest.(check string)
    "streaming first chunk metric"
    "masc_llm_provider_streaming_first_chunk_seconds"
    Metrics.metric_llm_provider_streaming_first_chunk;
  Alcotest.(check string)
    "streaming inter chunk metric"
    "masc_llm_provider_streaming_inter_chunk_seconds"
    Metrics.metric_llm_provider_streaming_inter_chunk

let test_metric_store_exports_otel_samples () =
  let model_id = Printf.sprintf "bridge-otel-sample-%d" (Unix.getpid ()) in
  let labels = [ ("model", model_id) ] in
  let before = metric Metrics.metric_llm_provider_cache_hits ~labels in
  Bridge.emit_cache_hit ~model_id;
  match find_otel_sample Metrics.metric_llm_provider_cache_hits ~labels with
  | None -> Alcotest.fail "missing cache hit metric in OTel sample snapshot"
  | Some sample ->
    Alcotest.(check (float 0.0001))
      "sample value reflects metric store"
      (before +. 1.0)
      sample.value;
    (match sample.kind with
     | Otel_metrics.Counter -> ()
     | _ -> Alcotest.fail "cache hit metric must export as OTel counter")

let test_metric_store_registers_otel_source_once () =
  Alcotest.(check bool)
    "source starts unregistered in this test process"
    false
    (Metrics.otel_source_registered_for_test ());
  Metrics.register_otel_source_once ();
  Alcotest.(check bool)
    "source is marked registered"
    true
    (Metrics.otel_source_registered_for_test ());
  Metrics.register_otel_source_once ();
  Alcotest.(check bool)
    "second registration stays registered"
    true
    (Metrics.otel_source_registered_for_test ())

let test_sink_records_oas_callbacks () =
  let sink : Llm_provider.Metrics.t = Bridge.make_sink () in
  let model_id = Printf.sprintf "bridge-test-model-%d" (Unix.getpid ()) in
  let provider = "bridge-test-provider" in
  let model_labels = [ ("model", model_id) ] in
  let provider_model_labels = [ ("provider", provider); ("model", model_id) ] in
  let retry_labels =
    [ ("provider", provider); ("model", model_id); ("attempt", "2") ]
  in
  let provider_key = "bridge-test-provider-key" in
  let circuit_labels =
    [ ("provider", provider); ("model", model_id); ("provider_key", provider_key) ]
  in
  let before_hit = metric Metrics.metric_llm_provider_cache_hits ~labels:model_labels in
  let before_miss = metric Metrics.metric_llm_provider_cache_misses ~labels:model_labels in
  let before_start =
    metric Metrics.metric_llm_provider_requests_started ~labels:model_labels
  in
  let before_error = metric Metrics.metric_llm_provider_errors ~labels:model_labels in
  let error_reason_labels =
    [ ("model", model_id); ("error_reason", "unknown") ]
  in
  let before_error_reason =
    metric Metrics.metric_llm_provider_errors_by_reason ~labels:error_reason_labels
  in
  let before_retry = metric Metrics.metric_llm_provider_retries ~labels:retry_labels in
  let before_input =
    metric Metrics.metric_llm_provider_input_tokens ~labels:provider_model_labels
  in
  let before_output =
    metric Metrics.metric_llm_provider_output_tokens ~labels:provider_model_labels
  in
  let before_tool_calls =
    metric Metrics.metric_llm_provider_tool_calls ~labels:provider_model_labels
  in
  let before_circuit_state =
    metric Metrics.metric_llm_provider_circuit_state ~labels:circuit_labels
  in
  let before_stream_first =
    metric
      (Metrics.metric_llm_provider_streaming_first_chunk ^ "_count")
      ~labels:provider_model_labels
  in
  let before_stream_inter =
    metric
      (Metrics.metric_llm_provider_streaming_inter_chunk ^ "_count")
      ~labels:provider_model_labels
  in
  sink.on_cache_hit ~model_id;
  sink.on_cache_miss ~model_id;
  sink.on_request_start ~model_id;
  sink.on_error ~model_id ~error:"ignored-freeform-error";
  sink.on_retry ~provider ~model_id ~attempt:2;
  sink.on_circuit_state ~provider ~model_id ~provider_key
    ~state:Llm_provider.Metrics.Circuit_open;
  sink.on_token_usage
    ~provider ~model_id ~input_tokens:17 ~output_tokens:23;
  sink.on_tool_calls ~provider ~model_id ~count:3;
  sink.on_streaming_first_chunk ~provider ~model_id ~ttfrc_ms:25.0;
  sink.on_streaming_chunk ~provider ~model_id ~chunk_index:1 ~inter_chunk_ms:7.5;
  check_metric_delta "cache hit +1"
    Metrics.metric_llm_provider_cache_hits
    ~labels:model_labels ~before:before_hit ~delta:1.0;
  check_metric_delta "cache miss +1"
    Metrics.metric_llm_provider_cache_misses
    ~labels:model_labels ~before:before_miss ~delta:1.0;
  check_metric_delta "request start +1"
    Metrics.metric_llm_provider_requests_started
    ~labels:model_labels ~before:before_start ~delta:1.0;
  check_metric_delta "error +1"
    Metrics.metric_llm_provider_errors
    ~labels:model_labels ~before:before_error ~delta:1.0;
  check_metric_delta "error reason +1"
    Metrics.metric_llm_provider_errors_by_reason
    ~labels:error_reason_labels ~before:before_error_reason ~delta:1.0;
  check_metric_delta "retry +1"
    Metrics.metric_llm_provider_retries
    ~labels:retry_labels ~before:before_retry ~delta:1.0;
  check_metric_delta "input tokens +17"
    Metrics.metric_llm_provider_input_tokens
    ~labels:provider_model_labels ~before:before_input ~delta:17.0;
  check_metric_delta "output tokens +23"
    Metrics.metric_llm_provider_output_tokens
    ~labels:provider_model_labels ~before:before_output ~delta:23.0;
  check_metric_delta "tool calls +3"
    Metrics.metric_llm_provider_tool_calls
    ~labels:provider_model_labels ~before:before_tool_calls ~delta:3.0;
  check_metric_delta "circuit state open"
    Metrics.metric_llm_provider_circuit_state
    ~labels:circuit_labels ~before:before_circuit_state ~delta:1.0;
  check_metric_delta "streaming first chunk count +1"
    (Metrics.metric_llm_provider_streaming_first_chunk ^ "_count")
    ~labels:provider_model_labels ~before:before_stream_first ~delta:1.0;
  check_metric_delta "streaming inter chunk count +1"
    (Metrics.metric_llm_provider_streaming_inter_chunk ^ "_count")
    ~labels:provider_model_labels ~before:before_stream_inter ~delta:1.0

let test_streaming_metrics_ignore_invalid_ms () =
  let model_id =
    Printf.sprintf "bridge-streaming-invalid-%d" (Unix.getpid ())
  in
  let provider = "bridge-streaming-provider" in
  let labels = [ ("provider", provider); ("model", model_id) ] in
  let first_before =
    metric (Metrics.metric_llm_provider_streaming_first_chunk ^ "_count") ~labels
  in
  let inter_before =
    metric (Metrics.metric_llm_provider_streaming_inter_chunk ^ "_count") ~labels
  in
  Bridge.emit_streaming_first_chunk ~provider ~model_id ~ttfrc_ms:0.0;
  Bridge.emit_streaming_chunk
    ~provider ~model_id ~chunk_index:1 ~inter_chunk_ms:(0.0 /. 0.0);
  check_metric_delta "invalid first chunk ignored"
    (Metrics.metric_llm_provider_streaming_first_chunk ^ "_count")
    ~labels ~before:first_before ~delta:0.0;
  check_metric_delta "invalid inter chunk ignored"
    (Metrics.metric_llm_provider_streaming_inter_chunk ^ "_count")
    ~labels ~before:inter_before ~delta:0.0

let test_streaming_invalid_ms_increments_typed_counter () =
  let model_id =
    Printf.sprintf "bridge-streaming-typed-%d" (Unix.getpid ())
  in
  let provider = "bridge-streaming-typed-provider" in
  let first_non_positive =
    [ ("provider", provider); ("model", model_id); ("reason", "non_positive") ]
  in
  let inter_not_finite =
    [ ("provider", provider); ("model", model_id); ("reason", "not_finite") ]
  in
  let before_first =
    metric Metrics.metric_llm_provider_streaming_first_chunk_invalid
      ~labels:first_non_positive
  in
  let before_inter =
    metric Metrics.metric_llm_provider_streaming_inter_chunk_invalid
      ~labels:inter_not_finite
  in
  Bridge.emit_streaming_first_chunk ~provider ~model_id ~ttfrc_ms:0.0;
  Bridge.emit_streaming_chunk
    ~provider ~model_id ~chunk_index:1 ~inter_chunk_ms:(0.0 /. 0.0);
  check_metric_delta "streaming first chunk non_positive +1"
    Metrics.metric_llm_provider_streaming_first_chunk_invalid
    ~labels:first_non_positive ~before:before_first ~delta:1.0;
  check_metric_delta "streaming inter chunk not_finite +1"
    Metrics.metric_llm_provider_streaming_inter_chunk_invalid
    ~labels:inter_not_finite ~before:before_inter ~delta:1.0

let test_streaming_invalid_ms_distinguishes_not_finite_from_non_positive () =
  let model_id =
    Printf.sprintf "bridge-streaming-distinct-%d" (Unix.getpid ())
  in
  let provider = "bridge-streaming-distinct-provider" in
  let first_not_finite =
    [ ("provider", provider); ("model", model_id); ("reason", "not_finite") ]
  in
  let first_non_positive =
    [ ("provider", provider); ("model", model_id); ("reason", "non_positive") ]
  in
  let before_nf =
    metric Metrics.metric_llm_provider_streaming_first_chunk_invalid
      ~labels:first_not_finite
  in
  let before_np =
    metric Metrics.metric_llm_provider_streaming_first_chunk_invalid
      ~labels:first_non_positive
  in
  Bridge.emit_streaming_first_chunk
    ~provider ~model_id ~ttfrc_ms:Float.infinity;
  Bridge.emit_streaming_first_chunk
    ~provider ~model_id ~ttfrc_ms:(-1.0);
  check_metric_delta "infinity routes to not_finite reason"
    Metrics.metric_llm_provider_streaming_first_chunk_invalid
    ~labels:first_not_finite ~before:before_nf ~delta:1.0;
  check_metric_delta "negative routes to non_positive reason"
    Metrics.metric_llm_provider_streaming_first_chunk_invalid
    ~labels:first_non_positive ~before:before_np ~delta:1.0

let test_request_latency_cache_miss_clamped_counter () =
  let model_id =
    Printf.sprintf "bridge-latency-cache-miss-%d" (Unix.getpid ())
  in
  let clamp_labels =
    [ ("provider", "unknown")
    ; ("model", model_id)
    ; ("reason", "provider_unknown_cache_miss")
    ]
  in
  let before =
    metric Metrics.metric_llm_provider_request_latency_clamped
      ~labels:clamp_labels
  in
  (* Caller omits [?provider] and the cache has no entry for this
     freshly-minted [model_id] — previously silently fell back to the
     [unknown] label with no operator signal. *)
  Bridge.emit_request_latency ~model_id ~latency_ms:42 ();
  check_metric_delta "cache miss provider attribution increments clamp counter"
    Metrics.metric_llm_provider_request_latency_clamped
    ~labels:clamp_labels ~before ~delta:1.0

let test_request_latency_no_model_id_clamped_counter () =
  let clamp_labels =
    [ ("provider", "unknown")
    ; ("model", "")
    ; ("reason", "provider_unknown_no_model_id")
    ]
  in
  let before =
    metric Metrics.metric_llm_provider_request_latency_clamped
      ~labels:clamp_labels
  in
  Bridge.emit_request_latency ~model_id:"" ~latency_ms:42 ();
  check_metric_delta "empty model_id increments distinct clamp reason"
    Metrics.metric_llm_provider_request_latency_clamped
    ~labels:clamp_labels ~before ~delta:1.0

let assoc_string key attrs =
  match List.assoc_opt key attrs with
  | Some (`String value) -> value
  | Some _ -> Alcotest.failf "expected string attr %s" key
  | None -> Alcotest.failf "missing attr %s" key

let assoc_float key attrs =
  match List.assoc_opt key attrs with
  | Some (`Float value) -> value
  | Some _ -> Alcotest.failf "expected float attr %s" key
  | None -> Alcotest.failf "missing attr %s" key

let assoc_int key attrs =
  match List.assoc_opt key attrs with
  | Some (`Int value) -> value
  | Some _ -> Alcotest.failf "expected int attr %s" key
  | None -> Alcotest.failf "missing attr %s" key

let assoc_bool key attrs =
  match List.assoc_opt key attrs with
  | Some (`Bool value) -> value
  | Some _ -> Alcotest.failf "expected bool attr %s" key
  | None -> Alcotest.failf "missing attr %s" key

let genai_base_labels ~provider ~model_id =
  [ (Otel_genai.Attr_key.gen_ai_operation_name, "chat")
  ; (Otel_genai.Attr_key.gen_ai_provider_name, provider)
  ; (Otel_genai.Attr_key.gen_ai_request_model, model_id)
  ]

let genai_token_labels ~provider ~model_id ~token_type =
  genai_base_labels ~provider ~model_id
  @ [ (Otel_genai.Attr_key.gen_ai_token_type, token_type) ]

let test_token_usage_emits_genai_otel_surface () =
  let events = ref [] in
  let span_attrs = ref [] in
  let provider = "bridge-genai-provider" in
  let model_id = Printf.sprintf "bridge-genai-token-%d" (Unix.getpid ()) in
  let input_labels = genai_token_labels ~provider ~model_id ~token_type:"input" in
  let output_labels = genai_token_labels ~provider ~model_id ~token_type:"output" in
  let before_input =
    metric Otel_genai.Metric_name.client_token_usage ~labels:input_labels
  in
  let before_output =
    metric Otel_genai.Metric_name.client_token_usage ~labels:output_labels
  in
  Otel_spans.with_test_event_emitter ~enabled:true
    ~emit_event:(fun ~name ~attrs -> events := (name, attrs) :: !events)
    ~emit_attrs:(fun ~attrs -> span_attrs := attrs @ !span_attrs)
    (fun () ->
       Bridge.emit_token_usage
         ~provider
         ~model_id
         ~input_tokens:17
         ~output_tokens:23);
  check_metric_delta "genai input token usage +17"
    Otel_genai.Metric_name.client_token_usage
    ~labels:input_labels
    ~before:before_input
    ~delta:17.0;
  check_metric_delta "genai output token usage +23"
    Otel_genai.Metric_name.client_token_usage
    ~labels:output_labels
    ~before:before_output
    ~delta:23.0;
  (match find_otel_sample Otel_genai.Metric_name.client_token_usage ~labels:input_labels with
   | Some { kind = Otel_metrics.Histogram; _ } -> ()
   | Some _ -> Alcotest.fail "genai token usage must export as OTel histogram"
   | None -> Alcotest.fail "missing genai token usage sample");
  Alcotest.(check int)
    "span attr input tokens"
    17
    (assoc_int Otel_genai.Attr_key.gen_ai_usage_input_tokens !span_attrs);
  Alcotest.(check int)
    "span attr output tokens"
    23
    (assoc_int Otel_genai.Attr_key.gen_ai_usage_output_tokens !span_attrs);
  Alcotest.(check string)
    "span attr provider"
    provider
    (assoc_string Otel_genai.Attr_key.gen_ai_provider_name !span_attrs);
  (match List.rev !events with
   | [ name, attrs ] ->
     Alcotest.(check string)
       "operation details event"
       Otel_genai.Event_name.client_inference_operation_details
       name;
     Alcotest.(check int)
       "event input tokens"
       17
       (assoc_int Otel_genai.Attr_key.gen_ai_usage_input_tokens attrs)
   | other ->
     Alcotest.failf "expected one token usage OTel event, got %d"
       (List.length other))

let test_usage_details_emit_cache_reasoning_attrs_without_token_type_aliases () =
  let events = ref [] in
  let span_attrs = ref [] in
  let provider = "bridge-genai-detail-provider" in
  let model_id = Printf.sprintf "bridge-genai-detail-%d" (Unix.getpid ()) in
  let cache_read_labels =
    genai_token_labels ~provider ~model_id ~token_type:"cache_read"
  in
  let reasoning_labels =
    genai_token_labels ~provider ~model_id ~token_type:"reasoning"
  in
  let before_cache_read =
    metric Otel_genai.Metric_name.client_token_usage ~labels:cache_read_labels
  in
  let before_reasoning =
    metric Otel_genai.Metric_name.client_token_usage ~labels:reasoning_labels
  in
  Otel_spans.with_test_event_emitter ~enabled:true
    ~emit_event:(fun ~name ~attrs -> events := (name, attrs) :: !events)
    ~emit_attrs:(fun ~attrs -> span_attrs := attrs @ !span_attrs)
    (fun () ->
       Bridge.emit_usage_details
         ~provider
         ~model_id
         ~cache_creation_input_tokens:5
         ~cache_read_input_tokens:7
         ~reasoning_output_tokens:11
         ());
  check_metric_delta "cache_read is not a gen_ai.token.type alias"
    Otel_genai.Metric_name.client_token_usage
    ~labels:cache_read_labels
    ~before:before_cache_read
    ~delta:0.0;
  check_metric_delta "reasoning is not a gen_ai.token.type alias"
    Otel_genai.Metric_name.client_token_usage
    ~labels:reasoning_labels
    ~before:before_reasoning
    ~delta:0.0;
  Alcotest.(check int)
    "span cache creation tokens"
    5
    (assoc_int
       Otel_genai.Attr_key.gen_ai_usage_cache_creation_input_tokens
       !span_attrs);
  Alcotest.(check int)
    "span cache read tokens"
    7
    (assoc_int
       Otel_genai.Attr_key.gen_ai_usage_cache_read_input_tokens
       !span_attrs);
  Alcotest.(check int)
    "span reasoning tokens"
    11
    (assoc_int
       Otel_genai.Attr_key.gen_ai_usage_reasoning_output_tokens
       !span_attrs);
  (match List.rev !events with
   | [ name, attrs ] ->
     Alcotest.(check string)
       "operation details event"
       Otel_genai.Event_name.client_inference_operation_details
       name;
     Alcotest.(check int)
       "event cache read tokens"
       7
       (assoc_int Otel_genai.Attr_key.gen_ai_usage_cache_read_input_tokens attrs)
  | other ->
     Alcotest.failf "expected one GenAI usage-details event, got %d"
       (List.length other))

let test_usage_details_emit_masc_finish_reason_extension () =
  let events = ref [] in
  let span_attrs = ref [] in
  let provider = "bridge-genai-finish-provider" in
  let model_id = Printf.sprintf "bridge-genai-finish-%d" (Unix.getpid ()) in
  Otel_spans.with_test_event_emitter ~enabled:true
    ~emit_event:(fun ~name ~attrs -> events := (name, attrs) :: !events)
    ~emit_attrs:(fun ~attrs -> span_attrs := attrs @ !span_attrs)
    (fun () ->
       Bridge.emit_usage_details
         ~provider
         ~model_id
         ~request_stream:true
         ~finish_reason:"end_turn"
         ());
  Alcotest.(check string)
    "span finish reason extension"
    "end_turn"
    (assoc_string
       Otel_genai.Attr_key.masc_gen_ai_response_finish_reason
       !span_attrs);
  Alcotest.(check bool)
    "official finish_reasons is not string-encoded"
    false
    (List.mem_assoc "gen_ai.response.finish_reasons" !span_attrs);
  Alcotest.(check bool)
    "span request stream"
    true
    (assoc_bool Otel_genai.Attr_key.gen_ai_request_stream !span_attrs);
  (match List.rev !events with
   | [ name, attrs ] ->
     Alcotest.(check string)
       "operation details event"
       Otel_genai.Event_name.client_inference_operation_details
       name;
     Alcotest.(check string)
       "event finish reason extension"
       "end_turn"
       (assoc_string
          Otel_genai.Attr_key.masc_gen_ai_response_finish_reason
          attrs);
     Alcotest.(check bool)
       "event request stream"
       true
       (assoc_bool Otel_genai.Attr_key.gen_ai_request_stream attrs)
   | other ->
     Alcotest.failf "expected one GenAI finish-reason event, got %d"
       (List.length other))

let test_latency_and_streaming_emit_genai_metrics () =
  let provider = "bridge-genai-latency-provider" in
  let model_id = Printf.sprintf "bridge-genai-latency-%d" (Unix.getpid ()) in
  let labels = genai_base_labels ~provider ~model_id in
  let before_duration =
    metric Otel_genai.Metric_name.client_operation_duration ~labels
  in
  let before_ttf =
    metric Otel_genai.Metric_name.client_operation_time_to_first_chunk ~labels
  in
  let before_chunk =
    metric Otel_genai.Metric_name.client_operation_time_per_output_chunk ~labels
  in
  Bridge.emit_request_latency ~provider ~model_id ~latency_ms:125 ();
  Bridge.emit_streaming_first_chunk ~provider ~model_id ~ttfrc_ms:25.0;
  Bridge.emit_streaming_chunk
    ~provider
    ~model_id
    ~chunk_index:3
    ~inter_chunk_ms:7.5;
  check_metric_delta "genai operation duration +0.125s"
    Otel_genai.Metric_name.client_operation_duration
    ~labels
    ~before:before_duration
    ~delta:0.125;
  check_metric_delta "genai time to first chunk +0.025s"
    Otel_genai.Metric_name.client_operation_time_to_first_chunk
    ~labels
    ~before:before_ttf
    ~delta:0.025;
  check_metric_delta "genai time per output chunk +0.0075s"
    Otel_genai.Metric_name.client_operation_time_per_output_chunk
    ~labels
    ~before:before_chunk
    ~delta:0.0075

let test_error_records_genai_exception_span_signal () =
  let events = ref [] in
  let span_attrs = ref [] in
  let span_status = ref None in
  let provider = "bridge-genai-error-provider" in
  let model_id = Printf.sprintf "bridge-genai-error-%d" (Unix.getpid ()) in
  Bridge.emit_http_status ~provider ~model_id ~status:200;
  Otel_spans.with_test_event_emitter ~enabled:true
    ~emit_event:(fun ~name ~attrs -> events := (name, attrs) :: !events)
    ~emit_attrs:(fun ~attrs -> span_attrs := attrs @ !span_attrs)
    ~set_status:(fun status -> span_status := Some status)
    (fun () -> Bridge.emit_error ~model_id ~error:"deadline exceeded after 30s");
  (match !span_status with
   | Some { Opentelemetry.Span_status.message; code } ->
     Alcotest.(check string)
       "span status message"
       "deadline exceeded after 30s"
       message;
     Alcotest.(check bool)
       "span status error code"
       true
       (code = Opentelemetry.Span_status.Status_code_error)
   | None -> Alcotest.fail "missing GenAI error span status");
  Alcotest.(check string)
    "span error.type"
    "timeout"
    (assoc_string "error.type" !span_attrs);
  Alcotest.(check string)
    "span provider"
    provider
    (assoc_string Otel_genai.Attr_key.gen_ai_provider_name !span_attrs);
  (match List.rev !events with
   | [ name, attrs ] ->
     Alcotest.(check string)
       "exception event name"
       "gen_ai.client.operation.exception"
       name;
     Alcotest.(check string)
       "exception type"
       "timeout"
       (assoc_string "exception.type" attrs)
   | other ->
     Alcotest.failf "expected one GenAI exception event, got %d"
       (List.length other))

let test_streaming_callbacks_emit_otel_events () =
  let events = ref [] in
  let provider = "bridge-otel-provider" in
  let model_id = Printf.sprintf "bridge-otel-model-%d" (Unix.getpid ()) in
  Otel_spans.with_test_event_emitter ~enabled:true
    ~emit_event:(fun ~name ~attrs -> events := (name, attrs) :: !events)
    (fun () ->
       Bridge.emit_streaming_first_chunk ~provider ~model_id ~ttfrc_ms:25.0;
       Bridge.emit_streaming_chunk
         ~provider ~model_id ~chunk_index:3 ~inter_chunk_ms:7.5);
  match List.rev !events with
  | [ first_name, first_attrs; chunk_name, chunk_attrs ] ->
    Alcotest.(check string) "first chunk event" "ttfrc.received" first_name;
    Alcotest.(check string) "chunk event" "streaming.chunk" chunk_name;
    Alcotest.(check string)
      "first provider"
      provider
      (assoc_string "gen_ai.provider.name" first_attrs);
    Alcotest.(check string)
      "first model"
      model_id
      (assoc_string "gen_ai.request.model" first_attrs);
    Alcotest.(check bool)
      "first stream attr"
      true
      (assoc_bool Otel_genai.Attr_key.gen_ai_request_stream first_attrs);
    Alcotest.(check (float 0.0001))
      "ttfrc ms"
      25.0
      (assoc_float "masc.gen_ai.streaming.ttfrc_ms" first_attrs);
    Alcotest.(check int)
      "chunk index"
      3
      (assoc_int "masc.gen_ai.streaming.chunk_index" chunk_attrs);
    Alcotest.(check string)
      "chunk provider"
      provider
      (assoc_string "gen_ai.provider.name" chunk_attrs);
    Alcotest.(check string)
      "chunk model"
      model_id
      (assoc_string "gen_ai.request.model" chunk_attrs);
    Alcotest.(check bool)
      "chunk stream attr"
      true
      (assoc_bool Otel_genai.Attr_key.gen_ai_request_stream chunk_attrs);
    Alcotest.(check (float 0.0001))
      "inter chunk ms"
      7.5
      (assoc_float "masc.gen_ai.streaming.inter_chunk_ms" chunk_attrs)
  | other ->
    Alcotest.failf "expected two OTel streaming events, got %d"
      (List.length other)

let test_request_latency_clamps_zero_ms () =
  let model_id =
    Printf.sprintf "bridge-latency-zero-%d" (Unix.getpid ())
  in
  let provider = "bridge-latency-provider" in
  let labels = [ ("provider", provider); ("model", model_id) ] in
  let before_sum =
    metric Metrics.metric_llm_provider_request_latency ~labels
  in
  let before_count =
    metric (Metrics.metric_llm_provider_request_latency ^ "_count") ~labels
  in
  let clamped_labels =
    [ ("provider", provider); ("model", model_id); ("reason", "non_positive_latency_ms") ]
  in
  let before_clamped =
    metric Metrics.metric_llm_provider_request_latency_clamped
      ~labels:clamped_labels
  in
  Bridge.emit_request_latency ~provider ~model_id ~latency_ms:0 ();
  check_metric_delta "latency sum floors to 1ms"
    Metrics.metric_llm_provider_request_latency
    ~labels ~before:before_sum ~delta:0.001;
  check_metric_delta "latency count +1"
    (Metrics.metric_llm_provider_request_latency ^ "_count")
    ~labels ~before:before_count ~delta:1.0;
  check_metric_delta "latency clamp +1"
    Metrics.metric_llm_provider_request_latency_clamped
    ~labels:clamped_labels ~before:before_clamped ~delta:1.0

let test_request_latency_positive_ms_does_not_clamp () =
  let model_id =
    Printf.sprintf "bridge-latency-positive-%d" (Unix.getpid ())
  in
  let provider = "bridge-positive-provider" in
  let labels =
    [ ("provider", provider); ("model", model_id); ("reason", "non_positive_latency_ms") ]
  in
  let before =
    metric Metrics.metric_llm_provider_request_latency_clamped ~labels
  in
  Bridge.emit_request_latency ~provider ~model_id ~latency_ms:42 ();
  check_metric_delta "positive latency avoids clamp counter"
    Metrics.metric_llm_provider_request_latency_clamped
    ~labels ~before ~delta:0.0

let test_request_latency_uses_provider_seen_from_status () =
  let model_id =
    Printf.sprintf "bridge-latency-status-provider-%d" (Unix.getpid ())
  in
  let provider = "bridge-status-provider" in
  let labels = [ ("provider", provider); ("model", model_id) ] in
  let before =
    metric (Metrics.metric_llm_provider_request_latency ^ "_count") ~labels
  in
  Bridge.emit_http_status ~provider ~model_id ~status:200;
  Bridge.emit_request_latency ~model_id ~latency_ms:125 ();
  check_metric_delta "latency uses provider cached by status"
    (Metrics.metric_llm_provider_request_latency ^ "_count")
    ~labels
    ~before
    ~delta:1.0

let test_error_reason_labels_are_bounded () =
  let model_id =
    Printf.sprintf "bridge-error-reason-%d" (Unix.getpid ())
  in
  let reason_labels reason =
    [ ("model", model_id); ("error_reason", reason) ]
  in
  let before_timeout =
    metric Metrics.metric_llm_provider_errors_by_reason
      ~labels:(reason_labels "timeout")
  in
  let before_rate_limit =
    metric Metrics.metric_llm_provider_errors_by_reason
      ~labels:(reason_labels "rate_limit")
  in
  Bridge.emit_error ~model_id ~error:"deadline exceeded after 30s";
  Bridge.emit_error ~model_id ~error:"HTTP 429 rate limit exceeded";
  check_metric_delta "timeout reason +1"
    Metrics.metric_llm_provider_errors_by_reason
    ~labels:(reason_labels "timeout") ~before:before_timeout ~delta:1.0;
  check_metric_delta "rate limit reason +1"
    Metrics.metric_llm_provider_errors_by_reason
    ~labels:(reason_labels "rate_limit") ~before:before_rate_limit ~delta:1.0

let () =
  Alcotest.run "llm_metric_bridge"
    [
      ( "metrics",
        [
          Alcotest.test_case "metric names are stable" `Quick
            test_metric_names_stable;
          Alcotest.test_case "metric store exports OTel samples" `Quick
            test_metric_store_exports_otel_samples;
          Alcotest.test_case "metric store registers OTel source once" `Quick
            test_metric_store_registers_otel_source_once;
          Alcotest.test_case "sink records OAS callbacks" `Quick
            test_sink_records_oas_callbacks;
          Alcotest.test_case "streaming metrics ignore invalid ms" `Quick
            test_streaming_metrics_ignore_invalid_ms;
          Alcotest.test_case
            "streaming invalid ms increments typed counter" `Quick
            test_streaming_invalid_ms_increments_typed_counter;
          Alcotest.test_case
            "streaming invalid ms distinguishes not_finite from non_positive"
            `Quick
            test_streaming_invalid_ms_distinguishes_not_finite_from_non_positive;
          Alcotest.test_case
            "request latency cache miss increments typed clamp reason" `Quick
            test_request_latency_cache_miss_clamped_counter;
          Alcotest.test_case
            "request latency no model_id increments typed clamp reason" `Quick
            test_request_latency_no_model_id_clamped_counter;
          Alcotest.test_case
            "token usage emits GenAI OTel surface" `Quick
            test_token_usage_emits_genai_otel_surface;
          Alcotest.test_case
            "usage details keep cache and reasoning out of token.type" `Quick
            test_usage_details_emit_cache_reasoning_attrs_without_token_type_aliases;
          Alcotest.test_case
            "usage details emit MASC finish reason extension" `Quick
            test_usage_details_emit_masc_finish_reason_extension;
          Alcotest.test_case
            "latency and streaming emit GenAI metrics" `Quick
            test_latency_and_streaming_emit_genai_metrics;
          Alcotest.test_case
            "error records GenAI exception span signal" `Quick
            test_error_records_genai_exception_span_signal;
          Alcotest.test_case "streaming callbacks emit OTel events" `Quick
            test_streaming_callbacks_emit_otel_events;
          Alcotest.test_case "request latency floors zero ms" `Quick
            test_request_latency_clamps_zero_ms;
          Alcotest.test_case "positive request latency does not clamp" `Quick
            test_request_latency_positive_ms_does_not_clamp;
          Alcotest.test_case "request latency uses provider seen from status" `Quick
            test_request_latency_uses_provider_seen_from_status;
          Alcotest.test_case "error reason labels are bounded" `Quick
            test_error_reason_labels_are_bounded;
        ] );
    ]
