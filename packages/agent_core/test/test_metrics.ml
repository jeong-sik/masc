(** Tests for metrics.ml — Agent-core metrics collection. *)

open Alcotest
open Agent_core

let with_eio f () = Eio_main.run (fun _env -> f ())

let test_counter_basic () =
  let m = Metrics.create () in
  let c = Metrics.counter m ~name:"test.counter" ~unit_:"1" in
  Metrics.incr c 5;
  Metrics.incr c 3;
  check int "counter total" 8 (Metrics.counter_value c ())
;;

let test_counter_with_labels () =
  let m = Metrics.create () in
  let c = Metrics.counter m ~name:"gen_ai.client.token.usage" ~unit_:"token" in
  Metrics.incr c ~labels:[ "gen_ai.token.type", "input" ] 150;
  Metrics.incr c ~labels:[ "gen_ai.token.type", "output" ] 42;
  Metrics.incr c ~labels:[ "gen_ai.token.type", "input" ] 50;
  check
    int
    "input tokens"
    200
    (Metrics.counter_value c ~labels:[ "gen_ai.token.type", "input" ] ());
  check
    int
    "output tokens"
    42
    (Metrics.counter_value c ~labels:[ "gen_ai.token.type", "output" ] ());
  check int "unlabeled" 0 (Metrics.counter_value c ())
;;

let test_histogram_basic () =
  let m = Metrics.create () in
  let h =
    Metrics.histogram
      m
      ~name:"gen_ai.client.operation.duration"
      ~buckets:[ 0.1; 0.5; 1.0; 5.0 ]
  in
  Metrics.observe h 0.05;
  Metrics.observe h 0.3;
  Metrics.observe h 2.5;
  check int "count" 3 (Metrics.histogram_count h)
;;

let test_histogram_with_labels () =
  let m = Metrics.create () in
  let h =
    Metrics.histogram
      m
      ~name:"gen_ai.client.operation.duration"
      ~buckets:[ 0.1; 0.5; 1.0; 5.0 ]
  in
  Metrics.observe
    h
    ~labels:[ "gen_ai.system", "openai"; "gen_ai.request.model", "gpt-5" ]
    0.3;
  Metrics.observe
    h
    ~labels:[ "gen_ai.system", "openai"; "gen_ai.request.model", "gpt-5" ]
    0.9;
  Metrics.observe
    h
    ~labels:[ "gen_ai.system", "anthropic"; "gen_ai.request.model", "claude" ]
    2.5;
  check int "total count" 3 (Metrics.histogram_count h);
  check
    int
    "openai count"
    2
    (Metrics.histogram_count
       ~labels:[ "gen_ai.request.model", "gpt-5"; "gen_ai.system", "openai" ]
       h);
  check
    int
    "missing label count"
    0
    (Metrics.histogram_count ~labels:[ "gen_ai.system", "missing" ] h)
;;

let test_counter_same_name_returns_same () =
  let m = Metrics.create () in
  let c1 = Metrics.counter m ~name:"x" ~unit_:"1" in
  let c2 = Metrics.counter m ~name:"x" ~unit_:"1" in
  Metrics.incr c1 10;
  check int "same counter" 10 (Metrics.counter_value c2 ())
;;

let test_reset () =
  let m = Metrics.create () in
  let c = Metrics.counter m ~name:"x" ~unit_:"1" in
  let h = Metrics.histogram m ~name:"y" ~buckets:[ 1.0 ] in
  Metrics.incr c 5;
  Metrics.observe h 0.5;
  Metrics.reset m;
  check int "counter reset" 0 (Metrics.counter_value c ());
  check int "histogram reset" 0 (Metrics.histogram_count h)
;;

let test_otlp_json_structure () =
  let m = Metrics.create () in
  let c = Metrics.counter m ~name:"test.c" ~unit_:"1" in
  Metrics.incr c 1;
  let h = Metrics.histogram m ~name:"test.h" ~buckets:[ 1.0; 5.0 ] in
  Metrics.observe h 2.0;
  let json = Metrics.to_otlp_json m in
  let open Yojson.Safe.Util in
  let rm = json |> member "resourceMetrics" |> to_list in
  check bool "has resourceMetrics" true (List.length rm > 0);
  let sm = List.hd rm |> member "scopeMetrics" |> to_list in
  check bool "has scopeMetrics" true (List.length sm > 0);
  let metrics = List.hd sm |> member "metrics" |> to_list in
  check int "2 metrics" 2 (List.length metrics)
;;

let prometheus_lines text =
  text |> String.split_on_char '\n' |> List.filter (fun line -> line <> "")
;;

let check_line label expected text =
  check bool label true (List.mem expected (prometheus_lines text))
;;

let test_prometheus_text_counter_normalizes_names_and_labels () =
  let m = Metrics.create () in
  let c = Metrics.counter m ~name:"gen_ai.client.token.usage" ~unit_:"token" in
  Metrics.incr c ~labels:[ "gen_ai.token.type", "input" ] 150;
  Metrics.incr c ~labels:[ "gen_ai.token.type", "output" ] 42;
  let text = Metrics.to_prometheus_text m in
  check_line
    "counter HELP"
    "# HELP gen_ai_client_token_usage gen_ai.client.token.usage"
    text;
  check_line "counter TYPE" "# TYPE gen_ai_client_token_usage counter" text;
  check_line
    "input counter sample"
    "gen_ai_client_token_usage{gen_ai_token_type=\"input\"} 150"
    text;
  check_line
    "output counter sample"
    "gen_ai_client_token_usage{gen_ai_token_type=\"output\"} 42"
    text
;;

let test_prometheus_text_histogram_exports_buckets_sum_and_count () =
  let m = Metrics.create () in
  let h =
    Metrics.histogram m ~name:"gen_ai.client.operation.duration" ~buckets:[ 1.0; 2.0 ]
  in
  Metrics.observe h 1.0;
  Metrics.observe h 3.0;
  let text = Metrics.to_prometheus_text m in
  check_line
    "histogram HELP"
    "# HELP gen_ai_client_operation_duration gen_ai.client.operation.duration"
    text;
  check_line "histogram TYPE" "# TYPE gen_ai_client_operation_duration histogram" text;
  check_line "bucket le 1" "gen_ai_client_operation_duration_bucket{le=\"1\"} 1" text;
  check_line "bucket le 2" "gen_ai_client_operation_duration_bucket{le=\"2\"} 1" text;
  check_line
    "bucket le +Inf"
    "gen_ai_client_operation_duration_bucket{le=\"+Inf\"} 2"
    text;
  check_line "histogram sum" "gen_ai_client_operation_duration_sum 4" text;
  check_line "histogram count" "gen_ai_client_operation_duration_count 2" text
;;

let test_register_rejects_duplicate_bucket_bounds () =
  (* Root fix for PR #1564: duplicate bucket bounds are now rejected at
     register time (mirroring PR #1570's normalized-name collision
     check). The emit path used to silently dedupe via
     [List.sort_uniq]; that was a telemetry-as-fix workaround. *)
  let m = Metrics.create () in
  match Metrics.histogram m ~name:"dup.bounds" ~buckets:[ 1.0; 1.0; 2.0 ] with
  | exception Invalid_argument _ -> ()
  | _ -> fail "expected Invalid_argument on duplicate bucket bounds"
;;

let test_prometheus_text_histogram_exports_zero_series_on_create_and_reset () =
  let m = Metrics.create () in
  let h = Metrics.histogram m ~name:"empty.histogram" ~buckets:[ 1.0; 2.0 ] in
  let check_zero_series prefix text =
    check_line (prefix ^ " bucket le 1") "empty_histogram_bucket{le=\"1\"} 0" text;
    check_line (prefix ^ " bucket le 2") "empty_histogram_bucket{le=\"2\"} 0" text;
    check_line (prefix ^ " bucket le +Inf") "empty_histogram_bucket{le=\"+Inf\"} 0" text;
    check_line (prefix ^ " sum") "empty_histogram_sum 0" text;
    check_line (prefix ^ " count") "empty_histogram_count 0" text
  in
  check_zero_series "fresh" (Metrics.to_prometheus_text m);
  Metrics.observe h 3.0;
  Metrics.reset m;
  check_zero_series "reset" (Metrics.to_prometheus_text m)
;;

let test_register_rejects_normalized_collision_counter_counter () =
  let m = Metrics.create () in
  let _ = Metrics.counter m ~name:"foo.bar" ~unit_:"1" in
  match Metrics.counter m ~name:"foo_bar" ~unit_:"1" with
  | exception Invalid_argument _ -> ()
  | _ -> fail "expected Invalid_argument on counter-counter normalized collision"
;;

let test_register_rejects_normalized_collision_counter_histogram () =
  let m = Metrics.create () in
  let _ = Metrics.counter m ~name:"shared.name" ~unit_:"1" in
  match Metrics.histogram m ~name:"shared_name" ~buckets:[ 1.0 ] with
  | exception Invalid_argument _ -> ()
  | _ -> fail "expected Invalid_argument on counter-histogram normalized collision"
;;

let test_register_same_name_same_kind_is_idempotent () =
  let m = Metrics.create () in
  let _ = Metrics.counter m ~name:"foo.bar" ~unit_:"1" in
  (* Same name + same kind is the documented "register or retrieve" path. *)
  let _ = Metrics.counter m ~name:"foo.bar" ~unit_:"1" in
  ()
;;

let test_prometheus_text_histogram_exports_labeled_series () =
  let m = Metrics.create () in
  let h = Metrics.histogram m ~name:"gen_ai.client.ttfrc" ~buckets:[ 1.0; 2.0 ] in
  let labels = [ "gen_ai.system", "openai"; "gen_ai.request.model", "gpt-5" ] in
  Metrics.observe h ~labels 0.5;
  Metrics.observe h ~labels 3.0;
  let text = Metrics.to_prometheus_text m in
  check_line
    "labeled bucket"
    "gen_ai_client_ttfrc_bucket{gen_ai_request_model=\"gpt-5\",gen_ai_system=\"openai\",le=\"1\"} \
     1"
    text;
  check_line
    "labeled +Inf bucket"
    "gen_ai_client_ttfrc_bucket{gen_ai_request_model=\"gpt-5\",gen_ai_system=\"openai\",le=\"+Inf\"} \
     2"
    text;
  check_line
    "labeled sum"
    "gen_ai_client_ttfrc_sum{gen_ai_request_model=\"gpt-5\",gen_ai_system=\"openai\"} 3.5"
    text;
  check_line
    "labeled count"
    "gen_ai_client_ttfrc_count{gen_ai_request_model=\"gpt-5\",gen_ai_system=\"openai\"} 2"
    text
;;

let test_otlp_json_histogram_exports_labeled_datapoints () =
  let m = Metrics.create () in
  let h = Metrics.histogram m ~name:"gen_ai.client.ttfrc" ~buckets:[ 1.0; 2.0 ] in
  Metrics.observe h ~labels:[ "gen_ai.system", "openai" ] 0.5;
  let json = Metrics.to_otlp_json m in
  let open Yojson.Safe.Util in
  let metrics =
    json
    |> member "resourceMetrics"
    |> to_list
    |> List.hd
    |> member "scopeMetrics"
    |> to_list
    |> List.hd
    |> member "metrics"
    |> to_list
  in
  let metric =
    List.find
      (fun metric -> metric |> member "name" |> to_string = "gen_ai.client.ttfrc")
      metrics
  in
  let data_point_attributes data_point =
    match member "attributes" data_point with
    | `List attrs -> attrs
    | _ -> []
  in
  let data_point =
    metric
    |> member "histogram"
    |> member "dataPoints"
    |> to_list
    |> List.find (fun data_point -> data_point_attributes data_point <> [])
  in
  let attrs = data_point_attributes data_point in
  check int "one attribute" 1 (List.length attrs);
  check string "attribute key" "gen_ai.system" (List.hd attrs |> member "key" |> to_string);
  check
    string
    "attribute value"
    "openai"
    (List.hd attrs |> member "value" |> member "stringValue" |> to_string)
;;

let test_otlp_json_histogram_exports_zero_datapoint_before_observe () =
  let m = Metrics.create () in
  let _ = Metrics.histogram m ~name:"gen_ai.client.zero" ~buckets:[ 1.0; 2.0 ] in
  let json = Metrics.to_otlp_json m in
  let open Yojson.Safe.Util in
  let metrics =
    json
    |> member "resourceMetrics"
    |> to_list
    |> List.hd
    |> member "scopeMetrics"
    |> to_list
    |> List.hd
    |> member "metrics"
    |> to_list
  in
  let metric =
    List.find
      (fun metric -> metric |> member "name" |> to_string = "gen_ai.client.zero")
      metrics
  in
  let data_points = metric |> member "histogram" |> member "dataPoints" |> to_list in
  check int "one zero datapoint" 1 (List.length data_points);
  let data_point = List.hd data_points in
  check string "count" "0" (data_point |> member "count" |> to_string);
  check (float 0.000001) "sum" 0.0 (data_point |> member "sum" |> to_float);
  check
    int
    "bucket count length"
    3
    (data_point |> member "bucketCounts" |> to_list |> List.length);
  let attrs =
    match member "attributes" data_point with
    | `List attrs -> attrs
    | _ -> []
  in
  check int "no attributes" 0 (List.length attrs)
;;

let () =
  run
    "Metrics"
    [ ( "counter"
      , [ test_case "basic increment" `Quick (with_eio test_counter_basic)
        ; test_case "labeled counters" `Quick (with_eio test_counter_with_labels)
        ; test_case
            "same name returns same"
            `Quick
            (with_eio test_counter_same_name_returns_same)
        ] )
    ; ( "histogram"
      , [ test_case "basic observe" `Quick (with_eio test_histogram_basic)
        ; test_case "labeled observe" `Quick (with_eio test_histogram_with_labels)
        ] )
    ; ( "lifecycle"
      , [ test_case "reset clears all" `Quick (with_eio test_reset)
        ; test_case "otlp json structure" `Quick (with_eio test_otlp_json_structure)
        ] )
    ; ( "prometheus"
      , [ test_case
            "counter text export normalizes names and labels"
            `Quick
            (with_eio test_prometheus_text_counter_normalizes_names_and_labels)
        ; test_case
            "histogram text export emits buckets sum and count"
            `Quick
            (with_eio test_prometheus_text_histogram_exports_buckets_sum_and_count)
        ; test_case
            "histogram text export preserves zero series"
            `Quick
            (with_eio
               test_prometheus_text_histogram_exports_zero_series_on_create_and_reset)
        ; test_case
            "histogram text export emits labeled series"
            `Quick
            (with_eio test_prometheus_text_histogram_exports_labeled_series)
        ; test_case
            "histogram OTLP export emits labeled datapoints"
            `Quick
            (with_eio test_otlp_json_histogram_exports_labeled_datapoints)
        ; test_case
            "histogram OTLP export preserves zero datapoint"
            `Quick
            (with_eio test_otlp_json_histogram_exports_zero_datapoint_before_observe)
        ] )
    ; ( "registration"
      , [ test_case
            "rejects counter-counter normalized collision"
            `Quick
            (with_eio test_register_rejects_normalized_collision_counter_counter)
        ; test_case
            "rejects counter-histogram normalized collision"
            `Quick
            (with_eio test_register_rejects_normalized_collision_counter_histogram)
        ; test_case
            "same name + same kind stays idempotent"
            `Quick
            (with_eio test_register_same_name_same_kind_is_idempotent)
        ; test_case
            "rejects duplicate histogram bucket bounds"
            `Quick
            (with_eio test_register_rejects_duplicate_bucket_bounds)
        ] )
    ]
;;
