(** Tests for [Dashboard_oas_bridge].

    Per-call telemetry collector for I1 telemetry pipeline (#11924). Covers
    ring-buffer semantics (record/recent/clear), runtime-lane compatibility
    filters, and the nearest-rank percentile in {!Dashboard_oas_bridge.summary},
    plus provider-error count aggregation for I2 (#11925). *)

module DOB = Dashboard_oas_bridge
module Json = Yojson.Safe.Util

let make_sample
      ?(provider = "anthropic")
      ?(model = "claude-opus")
      ?(ttfb = 100.0)
      ?(dur = 200.0)
      ?(serialization = 5.0)
      ?(usage_reported = true)
      ?(input = 100)
      ?(output = 200)
      ?(throughput = 1000.0)
      ?(cost = 0.001)
      ?(cache = false)
      ?(status = DOB.Success)
      ?(retry = 0)
      ()
  : DOB.sample
  =
  { provider_id = provider
  ; model_id = model
  ; ttfb_ms = ttfb
  ; total_duration_ms = dur
  ; serialization_ms = serialization
  ; usage_reported
  ; input_tokens = (if usage_reported then Some input else None)
  ; output_tokens = (if usage_reported then Some output else None)
  ; throughput_tokens_per_s = (if usage_reported then Some throughput else None)
  ; cost_usd = (if usage_reported then Some cost else None)
  ; cache_hit = (if usage_reported then Some cache else None)
  ; status
  ; retry_count = retry
  }
;;

let setup () = DOB.clear ()

let make_usage ?cost ?(cache_creation = 0) ?(cache_read = 0) ~input ~output ()
  : Agent_sdk.Types.api_usage
  =
  { input_tokens = input
  ; output_tokens = output
  ; cache_creation_input_tokens = cache_creation
  ; cache_read_input_tokens = cache_read
  ; cost_usd = cost
  }
;;

let make_telemetry ?timings ?(request_latency_ms = 0) ?ttfrc_ms ?prefill_ms ()
  : Agent_sdk.Types.inference_telemetry
  =
  { system_fingerprint = None
  ; timings
  ; reasoning_tokens = None
  ; request_latency_ms = Some request_latency_ms
  ; peak_memory_gb = None
  ; provider_kind = None
  ; reasoning_effort = None
  ; canonical_model_id = None
  ; reasoning_source = None
  ; effective_context_window = None
  ; provider_internal_action_count = None
  ; ttfrc_ms
  ; prefill_ms
  }
;;

let make_response ?usage ?telemetry ?(model = "claude-opus") ()
  : Agent_sdk.Types.api_response
  =
  { id = "resp-1"
  ; model
  ; stop_reason = Agent_sdk.Types.EndTurn
  ; content = []
  ; usage
  ; telemetry
  }
;;

(* --- record + recent --- *)

let test_record_then_recent () =
  setup ();
  DOB.record (make_sample ());
  match DOB.recent () with
  | [ (sample, _) ] ->
    Alcotest.(check string) "provider normalized" "runtime" sample.provider_id;
    Alcotest.(check string) "model normalized" "runtime" sample.model_id
  | xs -> Alcotest.failf "expected one sample, got %d" (List.length xs)
;;

let test_legacy_provider_filter_selects_runtime_lane () =
  setup ();
  DOB.record (make_sample ~provider:"anthropic" ());
  Alcotest.(check int)
    "legacy provider filter maps to runtime"
    1
    (List.length (DOB.recent ~provider:"nope" ()))
;;

(* --- runtime-lane compatibility filters --- *)

let test_provider_filter_is_runtime_lane_alias () =
  setup ();
  DOB.record (make_sample ~provider:"anthropic" ());
  DOB.record (make_sample ~provider:"anthropic" ());
  DOB.record (make_sample ~provider:"ollama" ());
  Alcotest.(check int)
    "anthropic aliases runtime"
    3
    (List.length (DOB.recent ~provider:"anthropic" ()));
  Alcotest.(check int)
    "ollama aliases runtime"
    3
    (List.length (DOB.recent ~provider:"ollama" ()));
  Alcotest.(check int) "all merged" 3 (List.length (DOB.recent ()))
;;

(* --- summary on empty / non-empty --- *)

let test_summary_empty () =
  setup ();
  let r = DOB.summary () in
  Alcotest.(check int) "sample_count" 0 r.DOB.sample_count;
  Alcotest.(check (float 1e-9)) "ttfb_p50" 0.0 r.DOB.ttfb_p50_ms
;;

let test_summary_percentile_nearest_rank () =
  setup ();
  (* Insert 10 samples with ttfb in {0, 100, 200, ..., 900}. *)
  for i = 0 to 9 do
    DOB.record (make_sample ~ttfb:(float_of_int (i * 100)) ())
  done;
  let r = DOB.summary () in
  Alcotest.(check int) "n=10" 10 r.DOB.sample_count;
  (* nearest-rank: idx_p50 = ceil(0.5 * 10) - 1 = 4 -> sorted[4] = 400. *)
  Alcotest.(check (float 1e-9)) "p50 = 400" 400.0 r.DOB.ttfb_p50_ms;
  (* idx_p95 = ceil(0.95 * 10) - 1 = 9 -> sorted[9] = 900. *)
  Alcotest.(check (float 1e-9)) "p95 = 900" 900.0 r.DOB.ttfb_p95_ms
;;

let test_summary_cache_and_cost () =
  setup ();
  DOB.record (make_sample ~cache:true ~cost:0.10 ());
  DOB.record (make_sample ~cache:false ~cost:0.20 ());
  DOB.record (make_sample ~cache:true ~cost:0.30 ());
  let r = DOB.summary () in
  Alcotest.(check (float 1e-9)) "cache_hit_ratio" (2.0 /. 3.0) r.DOB.cache_hit_ratio;
  Alcotest.(check (float 1e-9)) "total_cost_usd" 0.60 r.DOB.total_cost_usd
;;

let test_summary_status_counts () =
  setup ();
  DOB.record (make_sample ~status:DOB.Success ());
  DOB.record (make_sample ~status:(DOB.Error { transient = true }) ());
  DOB.record (make_sample ~status:DOB.Timeout ());
  DOB.record (make_sample ~status:(DOB.Cancelled { reason = "user" }) ());
  let r = DOB.summary () in
  Alcotest.(check (float 1e-9)) "error_ratio" 0.5 r.DOB.error_ratio;
  Alcotest.(check int) "cancelled_count" 1 r.DOB.cancelled_count
;;

(* --- dashboard JSON surface --- *)

let test_sample_json_preserves_signal_fields () =
  let json =
    DOB.sample_to_yojson
      (make_sample
         ~provider:"ollama"
         ~model:"qwen3"
         ~ttfb:12.0
         ~dur:34.0
         ~serialization:2.0
         ~input:123
         ~output:45
         ~throughput:200.0
         ~cost:0.03
         ~cache:true
         ~status:(DOB.Cancelled { reason = "operator" })
         ~retry:2
         ())
  in
  Alcotest.(check string)
    "provider redacted"
    "runtime"
    (json |> Json.member "provider_id" |> Json.to_string);
  Alcotest.(check string)
    "model redacted"
    "runtime"
    (json |> Json.member "model_id" |> Json.to_string);
  Alcotest.(check (float 1e-9))
    "ttfb"
    12.0
    (json |> Json.member "ttfb_ms" |> Json.to_float);
  Alcotest.(check (float 1e-9))
    "duration"
    34.0
    (json |> Json.member "total_duration_ms" |> Json.to_float);
  Alcotest.(check (float 1e-9))
    "serialization"
    2.0
    (json |> Json.member "serialization_ms" |> Json.to_float);
  Alcotest.(check bool)
    "usage reported"
    true
    (json |> Json.member "usage_reported" |> Json.to_bool);
  Alcotest.(check int) "input" 123 (json |> Json.member "input_tokens" |> Json.to_int);
  Alcotest.(check int) "output" 45 (json |> Json.member "output_tokens" |> Json.to_int);
  Alcotest.(check (float 1e-9))
    "throughput"
    200.0
    (json |> Json.member "throughput_tokens_per_s" |> Json.to_float);
  Alcotest.(check (float 1e-9))
    "cost"
    0.03
    (json |> Json.member "cost_usd" |> Json.to_float);
  Alcotest.(check bool) "cache" true (json |> Json.member "cache_hit" |> Json.to_bool);
  Alcotest.(check string)
    "status kind"
    "cancelled"
    (json |> Json.member "status" |> Json.member "kind" |> Json.to_string);
  Alcotest.(check string)
    "status reason"
    "operator"
    (json |> Json.member "status" |> Json.member "reason" |> Json.to_string);
  Alcotest.(check int) "retry" 2 (json |> Json.member "retry_count" |> Json.to_int)
;;

let test_recent_json_provider_filter_is_runtime_alias () =
  setup ();
  DOB.record (make_sample ~provider:"anthropic" ());
  DOB.record (make_sample ~provider:"ollama" ~model:"qwen3" ());
  let json = DOB.recent_json ~provider:"ollama" ~limit:5 () in
  Alcotest.(check bool)
    "generated_at present"
    true
    (json |> Json.member "generated_at" |> Json.to_string |> String.length > 0);
  Alcotest.(check string)
    "dashboard surface"
    "/api/v1/dashboard/oas/telemetry/recent"
    (json |> Json.member "dashboard_surface" |> Json.to_string);
  Alcotest.(check string)
    "source"
    "oas_runtime_bridge"
    (json |> Json.member "source" |> Json.to_string);
  Alcotest.(check string)
    "durable replay surface"
    "/api/v1/dashboard/telemetry?source=oas_event"
    (json
     |> Json.member "retention"
     |> Json.member "durable_replay_surface"
     |> Json.to_string);
  Alcotest.(check string)
    "provider redacted"
    "runtime"
    (json |> Json.member "provider" |> Json.to_string);
  Alcotest.(check int) "limit" 5 (json |> Json.member "limit" |> Json.to_int);
  Alcotest.(check int) "count" 2 (json |> Json.member "count" |> Json.to_int);
  match json |> Json.member "samples" |> Json.to_list with
  | samples ->
    List.iter
      (fun entry ->
         Alcotest.(check string)
           "sample provider redacted"
           "runtime"
           (entry |> Json.member "sample" |> Json.member "provider_id" |> Json.to_string))
      samples
;;

let test_summary_json_contains_aggregate () =
  setup ();
  DOB.record (make_sample ~cache:true ~status:DOB.Success ());
  DOB.record (make_sample ~cache:false ~status:DOB.Timeout ());
  let json = DOB.summary_json ~provider:"anthropic" ~limit:10 () in
  Alcotest.(check string)
    "dashboard surface"
    "/api/v1/dashboard/oas/telemetry/summary"
    (json |> Json.member "dashboard_surface" |> Json.to_string);
  Alcotest.(check int)
    "retention cap"
    200
    (json |> Json.member "retention" |> Json.member "per_provider_cap" |> Json.to_int);
  let summary = json |> Json.member "summary" in
  Alcotest.(check int)
    "sample_count"
    2
    (summary |> Json.member "sample_count" |> Json.to_int);
  Alcotest.(check (float 1e-9))
    "cache_hit_ratio"
    0.5
    (summary |> Json.member "cache_hit_ratio" |> Json.to_float);
  Alcotest.(check (float 1e-9))
    "error_ratio"
    0.5
    (summary |> Json.member "error_ratio" |> Json.to_float)
;;

(* --- clear --- *)

let test_clear_provider () =
  setup ();
  DOB.record (make_sample ~provider:"anthropic" ());
  DOB.record (make_sample ~provider:"ollama" ());
  DOB.clear ~provider:"anthropic" ();
  Alcotest.(check int)
    "legacy provider clears runtime lane"
    0
    (List.length (DOB.recent ~provider:"anthropic" ()));
  Alcotest.(check int) "other legacy alias also cleared" 0 (List.length (DOB.recent ~provider:"ollama" ()));
  Alcotest.(check int) "all cleared" 0 (List.length (DOB.recent ()))
;;

(* --- OAS response projection --- *)

let test_sample_of_response_uses_usage_and_native_telemetry () =
  let usage = make_usage ~input:11 ~output:5 ~cache_read:7 ~cost:0.12 () in
  let timings : Agent_sdk.Types.inference_timings =
    { prompt_n = Some 11
    ; prompt_ms = Some 510.0
    ; prompt_per_second = Some 21.55
    ; predicted_n = Some 5
    ; predicted_ms = Some 61.3
    ; predicted_per_second = Some 81.56
    ; cache_n = Some 7
    }
  in
  let telemetry = make_telemetry ~timings ~request_latency_ms:620 () in
  let response = make_response ~usage ~telemetry ~model:"gpt-4" () in
  let sample =
    DOB.sample_of_response
      ~provider_id:"openai_compat"
      ~model_id:"gpt-4"
      ~status:DOB.Success
      response
  in
  Alcotest.(check string) "provider normalized" "runtime" sample.provider_id;
  Alcotest.(check string) "model normalized" "runtime" sample.model_id;
  Alcotest.(check bool) "usage reported" true sample.usage_reported;
  Alcotest.(check bool) "input tokens" true (sample.input_tokens = Some 11);
  Alcotest.(check bool) "output tokens" true (sample.output_tokens = Some 5);
  Alcotest.(check (float 1e-9)) "ttfb" 510.0 sample.ttfb_ms;
  Alcotest.(check (float 1e-9)) "duration" 620.0 sample.total_duration_ms;
  Alcotest.(check bool)
    "native throughput"
    true
    (sample.throughput_tokens_per_s = Some 81.56);
  Alcotest.(check bool) "cost" true (sample.cost_usd = Some 0.12);
  Alcotest.(check bool) "cache hit" true (sample.cache_hit = Some true)
;;

let test_sample_of_response_derives_wall_throughput () =
  let usage = make_usage ~input:100 ~output:50 () in
  let telemetry = make_telemetry ~request_latency_ms:250 () in
  let response = make_response ~usage ~telemetry ~model:"ollama:qwen" () in
  let sample =
    DOB.sample_of_response
      ~provider_id:"ollama"
      ~model_id:"ollama:qwen"
      ~status:DOB.Success
      response
  in
  Alcotest.(check (float 1e-9)) "duration" 250.0 sample.total_duration_ms;
  Alcotest.(check bool)
    "wall throughput"
    true
    (sample.throughput_tokens_per_s = Some 200.0)
;;

let test_sample_of_response_prefers_ttfrc_for_ttfb () =
  let usage = make_usage ~input:100 ~output:50 () in
  let timings : Agent_sdk.Types.inference_timings =
    { prompt_n = Some 100
    ; prompt_ms = Some 510.0
    ; prompt_per_second = Some 196.0
    ; predicted_n = Some 50
    ; predicted_ms = Some 100.0
    ; predicted_per_second = Some 500.0
    ; cache_n = None
    }
  in
  let telemetry =
    make_telemetry ~timings ~request_latency_ms:750 ~ttfrc_ms:42.0 ()
  in
  let response = make_response ~usage ~telemetry ~model:"kimi-for-coding" () in
  let sample =
    DOB.sample_of_response
      ~provider_id:"kimi_cli"
      ~model_id:"kimi-for-coding"
      ~status:DOB.Success
      response
  in
  Alcotest.(check (float 1e-9))
    "ttfrc drives first response latency"
    42.0
    sample.ttfb_ms;
  Alcotest.(check (float 1e-9))
    "request latency still drives total duration"
    750.0
    sample.total_duration_ms
;;

let test_sample_of_response_derives_duration_from_timing_components () =
  let usage = make_usage ~input:100 ~output:88 () in
  let timings : Agent_sdk.Types.inference_timings =
    { prompt_n = None
    ; prompt_ms = Some 120.0
    ; prompt_per_second = None
    ; predicted_n = None
    ; predicted_ms = Some 880.0
    ; predicted_per_second = None
    ; cache_n = None
    }
  in
  let telemetry = make_telemetry ~timings ~request_latency_ms:0 () in
  let response = make_response ~usage ~telemetry ~model:"ollama:qwen" () in
  let sample =
    DOB.sample_of_response
      ~provider_id:"ollama"
      ~model_id:"ollama:qwen"
      ~status:DOB.Success
      response
  in
  Alcotest.(check (float 1e-9))
    "duration falls back to prompt+decode timings"
    1000.0
    sample.total_duration_ms;
  Alcotest.(check (float 1e-9)) "ttfb still uses prompt timing" 120.0 sample.ttfb_ms;
  match sample.throughput_tokens_per_s with
  | Some throughput ->
    Alcotest.(check (float 1e-9))
      "wall throughput uses derived decode time"
      100.0
      throughput
  | None -> Alcotest.fail "expected derived throughput"
;;

let test_sample_of_response_uses_ttfrc_for_duration_fallback () =
  let usage = make_usage ~input:100 ~output:88 () in
  let timings : Agent_sdk.Types.inference_timings =
    { prompt_n = None
    ; prompt_ms = Some 120.0
    ; prompt_per_second = None
    ; predicted_n = None
    ; predicted_ms = Some 880.0
    ; predicted_per_second = None
    ; cache_n = None
    }
  in
  let telemetry =
    make_telemetry ~timings ~request_latency_ms:0 ~ttfrc_ms:450.0 ()
  in
  let response = make_response ~usage ~telemetry ~model:"ollama:qwen" () in
  let sample =
    DOB.sample_of_response
      ~provider_id:"ollama"
      ~model_id:"ollama:qwen"
      ~status:DOB.Success
      response
  in
  Alcotest.(check (float 1e-9))
    "duration falls back to ttfrc+decode timings"
    1330.0
    sample.total_duration_ms;
  Alcotest.(check (float 1e-9)) "ttfb uses ttfrc" 450.0 sample.ttfb_ms;
  match sample.throughput_tokens_per_s with
  | Some throughput ->
    Alcotest.(check (float 1e-9))
      "wall throughput uses decode duration after ttfrc"
      100.0
      throughput
  | None -> Alcotest.fail "expected derived throughput"
;;

let test_record_response_records_missing_usage_as_unknown_sample () =
  setup ();
  let response =
    make_response
      ~telemetry:(make_telemetry ~request_latency_ms:33 ())
      ~model:"kimi-for-coding"
      ()
  in
  DOB.record_response
    ~provider_id:"kimi_cli"
    ~model_id:"kimi-for-coding"
    ~status:(DOB.Error { transient = false })
    response;
  match DOB.recent ~provider:"kimi_cli" () with
  | [ (sample, _) ] ->
    Alcotest.(check string) "provider normalized" "runtime" sample.provider_id;
    Alcotest.(check string) "model normalized" "runtime" sample.model_id;
    Alcotest.(check bool) "usage reported" false sample.usage_reported;
    Alcotest.(check bool) "input tokens unknown" true (sample.input_tokens = None);
    Alcotest.(check bool) "output tokens unknown" true (sample.output_tokens = None);
    Alcotest.(check bool) "throughput unknown" true (sample.throughput_tokens_per_s = None);
    Alcotest.(check bool) "cost unknown" true (sample.cost_usd = None);
    Alcotest.(check (float 1e-9)) "duration" 33.0 sample.total_duration_ms;
    Alcotest.(check bool) "cache hit unknown" true (sample.cache_hit = None)
  | xs -> Alcotest.failf "expected one sample, got %d" (List.length xs)
;;

(* --- signal coverage ratchet --- *)

(** Verify that all telemetry signals are present as keys in the JSON output
    of [sample_to_yojson].  This ratchet fails CI if any signal is dropped from
    the serialization layer. *)
let expected_signal_keys =
  [ "provider_id"
  ; "model_id"
  ; "ttfb_ms"
  ; "total_duration_ms"
  ; "serialization_ms"
  ; "usage_reported"
  ; "input_tokens"
  ; "output_tokens"
  ; "throughput_tokens_per_s"
  ; "cost_usd"
  ; "cache_hit"
  ; "status"
  ; "retry_count"
  ]
;;

let test_signal_json_keys_all_present () =
  let json = DOB.sample_to_yojson (make_sample ()) in
  let keys =
    match json with
    | `Assoc pairs -> List.map fst pairs
    | _ -> Alcotest.fail "expected Assoc"
  in
  List.iter
    (fun expected_key ->
       Alcotest.(check bool)
         (Printf.sprintf "signal key '%s' present" expected_key)
         true
         (List.mem expected_key keys))
    expected_signal_keys;
  Alcotest.(check int) "exactly 13 signal keys" 13 (List.length keys)
;;

let test_serialization_ms_propagates_through_sample_of_response () =
  let usage = make_usage ~input:10 ~output:5 () in
  let response = make_response ~usage () in
  let sample =
    DOB.sample_of_response
      ~provider_id:"openai_compat"
      ~model_id:"gpt-4"
      ~serialization_ms:7.5
      ~status:DOB.Success
      response
  in
  Alcotest.(check (float 1e-9)) "serialization_ms preserved" 7.5 sample.serialization_ms
;;

let test_serialization_ms_defaults_to_zero () =
  let response = make_response () in
  let sample =
    DOB.sample_of_response
      ~provider_id:"anthropic"
      ~model_id:"claude"
      ~status:DOB.Success
      response
  in
  Alcotest.(check (float 1e-9))
    "serialization_ms defaults to 0"
    0.0
    sample.serialization_ms
;;

let test_record_response_serialization_ms_round_trips () =
  setup ();
  let response =
    make_response ~telemetry:(make_telemetry ~request_latency_ms:100 ()) ()
  in
  DOB.record_response
    ~provider_id:"anthropic"
    ~model_id:"claude"
    ~serialization_ms:3.14
    ~status:DOB.Success
    response;
  match DOB.recent ~provider:"anthropic" () with
  | [ (sample, _) ] ->
    Alcotest.(check (float 1e-9))
      "serialization_ms round-trips"
      3.14
      sample.serialization_ms
  | xs -> Alcotest.failf "expected one sample, got %d" (List.length xs)
;;

let () =
  Alcotest.run
    "Dashboard_oas_bridge"
    [ ( "record_recent"
      , [ Alcotest.test_case "record + recent" `Quick test_record_then_recent
        ; Alcotest.test_case
            "legacy provider filter"
            `Quick
            test_legacy_provider_filter_selects_runtime_lane
        ] )
    ; ( "provider_filter"
      , [ Alcotest.test_case
            "runtime lane alias"
            `Quick
            test_provider_filter_is_runtime_lane_alias
        ] )
    ; ( "summary"
      , [ Alcotest.test_case "empty" `Quick test_summary_empty
        ; Alcotest.test_case
            "percentile nearest-rank"
            `Quick
            test_summary_percentile_nearest_rank
        ; Alcotest.test_case "cache hit + cost" `Quick test_summary_cache_and_cost
        ; Alcotest.test_case "status counts" `Quick test_summary_status_counts
        ] )
    ; ( "json"
      , [ Alcotest.test_case
            "sample fields"
            `Quick
            test_sample_json_preserves_signal_fields
        ; Alcotest.test_case
            "recent provider filter alias"
            `Quick
            test_recent_json_provider_filter_is_runtime_alias
        ; Alcotest.test_case
            "summary aggregate"
            `Quick
            test_summary_json_contains_aggregate
        ] )
    ; ( "clear"
      , [ Alcotest.test_case "clear provider" `Quick test_clear_provider
        ] )
    ; ( "oas_response"
      , [ Alcotest.test_case
            "usage + native telemetry"
            `Quick
            test_sample_of_response_uses_usage_and_native_telemetry
        ; Alcotest.test_case
            "wall throughput fallback"
            `Quick
            test_sample_of_response_derives_wall_throughput
        ; Alcotest.test_case
            "ttfrc drives ttfb"
            `Quick
            test_sample_of_response_prefers_ttfrc_for_ttfb
        ; Alcotest.test_case
            "timing components avoid zero duration"
            `Quick
            test_sample_of_response_derives_duration_from_timing_components
        ; Alcotest.test_case
            "ttfrc duration fallback"
            `Quick
            test_sample_of_response_uses_ttfrc_for_duration_fallback
        ; Alcotest.test_case
            "missing usage records unknown sample"
            `Quick
            test_record_response_records_missing_usage_as_unknown_sample
        ] )
    ; ( "signal_ratchet"
      , [ Alcotest.test_case
            "all 13 JSON keys present"
            `Quick
            test_signal_json_keys_all_present
        ; Alcotest.test_case
            "serialization_ms via sample_of_response"
            `Quick
            test_serialization_ms_propagates_through_sample_of_response
        ; Alcotest.test_case
            "serialization_ms defaults to zero"
            `Quick
            test_serialization_ms_defaults_to_zero
        ; Alcotest.test_case
            "serialization_ms round-trips via record_response"
            `Quick
            test_record_response_serialization_ms_round_trips
        ] )
    ]
;;
