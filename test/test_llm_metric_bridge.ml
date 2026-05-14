module Bridge = Masc_mcp.Llm_metric_bridge
module Prom = Masc_mcp.Prometheus

let metric name ~labels =
  Prom.metric_value_or_zero name ~labels ()

let check_metric_delta label name ~labels ~before ~delta =
  Alcotest.(check (float 0.0001))
    label
    (before +. delta)
    (metric name ~labels)

let test_metric_names_stable () =
  Alcotest.(check string)
    "cache hits metric"
    "masc_llm_provider_cache_hits_total"
    Prom.metric_llm_provider_cache_hits;
  Alcotest.(check string)
    "cache misses metric"
    "masc_llm_provider_cache_misses_total"
    Prom.metric_llm_provider_cache_misses;
  Alcotest.(check string)
    "requests started metric"
    "masc_llm_provider_requests_started_total"
    Prom.metric_llm_provider_requests_started;
  Alcotest.(check string)
    "errors metric"
    "masc_llm_provider_errors_total"
    Prom.metric_llm_provider_errors;
  Alcotest.(check string)
    "errors by reason metric"
    "masc_llm_provider_errors_by_reason_total"
    Prom.metric_llm_provider_errors_by_reason;
  Alcotest.(check string)
    "retries metric"
    "masc_llm_provider_retries_total"
    Prom.metric_llm_provider_retries;
  Alcotest.(check string)
    "input tokens metric"
    "masc_llm_provider_input_tokens_total"
    Prom.metric_llm_provider_input_tokens;
  Alcotest.(check string)
    "output tokens metric"
    "masc_llm_provider_output_tokens_total"
    Prom.metric_llm_provider_output_tokens;
  Alcotest.(check string)
    "circuit state metric"
    "masc_llm_provider_circuit_state"
    Prom.metric_llm_provider_circuit_state;
  Alcotest.(check string)
    "request latency clamped metric"
    "masc_llm_provider_request_latency_clamped_total"
    Prom.metric_llm_provider_request_latency_clamped;
  Alcotest.(check string)
    "streaming first chunk metric"
    "masc_llm_provider_streaming_first_chunk_seconds"
    Prom.metric_llm_provider_streaming_first_chunk;
  Alcotest.(check string)
    "streaming inter chunk metric"
    "masc_llm_provider_streaming_inter_chunk_seconds"
    Prom.metric_llm_provider_streaming_inter_chunk

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
  let before_hit = metric Prom.metric_llm_provider_cache_hits ~labels:model_labels in
  let before_miss = metric Prom.metric_llm_provider_cache_misses ~labels:model_labels in
  let before_start =
    metric Prom.metric_llm_provider_requests_started ~labels:model_labels
  in
  let before_error = metric Prom.metric_llm_provider_errors ~labels:model_labels in
  let error_reason_labels =
    [ ("model", model_id); ("error_reason", "unknown") ]
  in
  let before_error_reason =
    metric Prom.metric_llm_provider_errors_by_reason ~labels:error_reason_labels
  in
  let before_retry = metric Prom.metric_llm_provider_retries ~labels:retry_labels in
  let before_input =
    metric Prom.metric_llm_provider_input_tokens ~labels:provider_model_labels
  in
  let before_output =
    metric Prom.metric_llm_provider_output_tokens ~labels:provider_model_labels
  in
  let before_circuit_state =
    metric Prom.metric_llm_provider_circuit_state ~labels:circuit_labels
  in
  let before_stream_first =
    metric
      (Prom.metric_llm_provider_streaming_first_chunk ^ "_count")
      ~labels:provider_model_labels
  in
  let before_stream_inter =
    metric
      (Prom.metric_llm_provider_streaming_inter_chunk ^ "_count")
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
  sink.on_streaming_first_chunk ~provider ~model_id ~ttfrc_ms:25.0;
  sink.on_streaming_chunk ~provider ~model_id ~chunk_index:1 ~inter_chunk_ms:7.5;
  check_metric_delta "cache hit +1"
    Prom.metric_llm_provider_cache_hits
    ~labels:model_labels ~before:before_hit ~delta:1.0;
  check_metric_delta "cache miss +1"
    Prom.metric_llm_provider_cache_misses
    ~labels:model_labels ~before:before_miss ~delta:1.0;
  check_metric_delta "request start +1"
    Prom.metric_llm_provider_requests_started
    ~labels:model_labels ~before:before_start ~delta:1.0;
  check_metric_delta "error +1"
    Prom.metric_llm_provider_errors
    ~labels:model_labels ~before:before_error ~delta:1.0;
  check_metric_delta "error reason +1"
    Prom.metric_llm_provider_errors_by_reason
    ~labels:error_reason_labels ~before:before_error_reason ~delta:1.0;
  check_metric_delta "retry +1"
    Prom.metric_llm_provider_retries
    ~labels:retry_labels ~before:before_retry ~delta:1.0;
  check_metric_delta "input tokens +17"
    Prom.metric_llm_provider_input_tokens
    ~labels:provider_model_labels ~before:before_input ~delta:17.0;
  check_metric_delta "output tokens +23"
    Prom.metric_llm_provider_output_tokens
    ~labels:provider_model_labels ~before:before_output ~delta:23.0;
  check_metric_delta "circuit state open"
    Prom.metric_llm_provider_circuit_state
    ~labels:circuit_labels ~before:before_circuit_state ~delta:1.0;
  check_metric_delta "streaming first chunk count +1"
    (Prom.metric_llm_provider_streaming_first_chunk ^ "_count")
    ~labels:provider_model_labels ~before:before_stream_first ~delta:1.0;
  check_metric_delta "streaming inter chunk count +1"
    (Prom.metric_llm_provider_streaming_inter_chunk ^ "_count")
    ~labels:provider_model_labels ~before:before_stream_inter ~delta:1.0

let test_streaming_metrics_ignore_invalid_ms () =
  let model_id =
    Printf.sprintf "bridge-streaming-invalid-%d" (Unix.getpid ())
  in
  let provider = "bridge-streaming-provider" in
  let labels = [ ("provider", provider); ("model", model_id) ] in
  let first_before =
    metric (Prom.metric_llm_provider_streaming_first_chunk ^ "_count") ~labels
  in
  let inter_before =
    metric (Prom.metric_llm_provider_streaming_inter_chunk ^ "_count") ~labels
  in
  Bridge.emit_streaming_first_chunk ~provider ~model_id ~ttfrc_ms:0.0;
  Bridge.emit_streaming_chunk
    ~provider ~model_id ~chunk_index:1 ~inter_chunk_ms:(0.0 /. 0.0);
  check_metric_delta "invalid first chunk ignored"
    (Prom.metric_llm_provider_streaming_first_chunk ^ "_count")
    ~labels ~before:first_before ~delta:0.0;
  check_metric_delta "invalid inter chunk ignored"
    (Prom.metric_llm_provider_streaming_inter_chunk ^ "_count")
    ~labels ~before:inter_before ~delta:0.0

let test_request_latency_clamps_zero_ms () =
  let model_id =
    Printf.sprintf "bridge-latency-zero-%d" (Unix.getpid ())
  in
  let provider = "bridge-latency-provider" in
  let labels = [ ("provider", provider); ("model", model_id) ] in
  let before_sum =
    metric Prom.metric_llm_provider_request_latency ~labels
  in
  let before_count =
    metric (Prom.metric_llm_provider_request_latency ^ "_count") ~labels
  in
  let clamped_labels =
    [ ("provider", provider); ("model", model_id); ("reason", "non_positive_latency_ms") ]
  in
  let before_clamped =
    metric Prom.metric_llm_provider_request_latency_clamped
      ~labels:clamped_labels
  in
  Bridge.emit_request_latency ~provider ~model_id ~latency_ms:0 ();
  check_metric_delta "latency sum floors to 1ms"
    Prom.metric_llm_provider_request_latency
    ~labels ~before:before_sum ~delta:0.001;
  check_metric_delta "latency count +1"
    (Prom.metric_llm_provider_request_latency ^ "_count")
    ~labels ~before:before_count ~delta:1.0;
  check_metric_delta "latency clamp +1"
    Prom.metric_llm_provider_request_latency_clamped
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
    metric Prom.metric_llm_provider_request_latency_clamped ~labels
  in
  Bridge.emit_request_latency ~provider ~model_id ~latency_ms:42 ();
  check_metric_delta "positive latency avoids clamp counter"
    Prom.metric_llm_provider_request_latency_clamped
    ~labels ~before ~delta:0.0

let test_request_latency_uses_provider_seen_from_status () =
  let model_id =
    Printf.sprintf "bridge-latency-status-provider-%d" (Unix.getpid ())
  in
  let provider = "bridge-status-provider" in
  let labels = [ ("provider", provider); ("model", model_id) ] in
  let before =
    metric (Prom.metric_llm_provider_request_latency ^ "_count") ~labels
  in
  Bridge.emit_http_status ~provider ~model_id ~status:200;
  Bridge.emit_request_latency ~model_id ~latency_ms:125 ();
  check_metric_delta "latency uses provider cached by status"
    (Prom.metric_llm_provider_request_latency ^ "_count")
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
    metric Prom.metric_llm_provider_errors_by_reason
      ~labels:(reason_labels "timeout")
  in
  let before_rate_limit =
    metric Prom.metric_llm_provider_errors_by_reason
      ~labels:(reason_labels "rate_limit")
  in
  Bridge.emit_error ~model_id ~error:"deadline exceeded after 30s";
  Bridge.emit_error ~model_id ~error:"HTTP 429 rate limit exceeded";
  check_metric_delta "timeout reason +1"
    Prom.metric_llm_provider_errors_by_reason
    ~labels:(reason_labels "timeout") ~before:before_timeout ~delta:1.0;
  check_metric_delta "rate limit reason +1"
    Prom.metric_llm_provider_errors_by_reason
    ~labels:(reason_labels "rate_limit") ~before:before_rate_limit ~delta:1.0

let () =
  Alcotest.run "llm_metric_bridge"
    [
      ( "metrics",
        [
          Alcotest.test_case "metric names are stable" `Quick
            test_metric_names_stable;
          Alcotest.test_case "sink records OAS callbacks" `Quick
            test_sink_records_oas_callbacks;
          Alcotest.test_case "streaming metrics ignore invalid ms" `Quick
            test_streaming_metrics_ignore_invalid_ms;
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
