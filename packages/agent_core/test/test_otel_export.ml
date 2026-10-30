(** Tests for Otel_export — OTLP HTTP/JSON span exporter.

    All tests use mock spans (no LLM calls). HTTP transport is tested
    via Eio mock network where possible, and unit tests for serialization
    and batch logic. *)

open Agent_core
open Otel_export

(* ── Test helpers ────────────────────────────────────────────── *)

let make_test_span ?(name = "test_span") () : Otel_tracer.span =
  { trace_id = "aaaa1234aaaa1234aaaa1234aaaa1234"
  ; span_id = "bbbb5678bbbb5678"
  ; parent_span_id = None
  ; name
  ; kind = Internal
  ; start_time_ns = Int64.of_int 1000000000
  ; end_time_ns = Some (Int64.of_int 2000000000)
  ; status = Some true
  ; attributes = [ "test.key", "test.value" ]
  ; events = []
  ; links = []
  }
;;

let make_instance ?(service_name = "test-service") () =
  Otel_tracer.create_instance ~config:{ Otel_tracer.service_name; endpoint = None } ()
;;

let record_span ?(name = "exported_span") ?(turn = 1) instance =
  let attrs : Tracing.span_attrs =
    { name
    ; agent_name = "otel-export-test"
    ; turn
    ; kind = Tracing.Agent_run
    ; extra = [ "test.case", name ]
    ; links = []
    }
  in
  let span = Otel_tracer.inst_start_span instance attrs in
  Otel_tracer.inst_end_span instance span ~ok:true
;;

let with_mock_collector ~port handler f =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let socket =
      Eio.Net.listen
        env#net
        ~sw
        ~backlog:128
        ~reuse_addr:true
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
    in
    let server = Cohttp_eio.Server.make ~callback:handler () in
    Eio.Fiber.fork ~sw (fun () ->
      Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
    let endpoint = Printf.sprintf "http://127.0.0.1:%d/v1/traces" port in
    f ~sw ~clock:env#clock ~net:env#net ~endpoint;
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let read_request_body body =
  Eio.Buf_read.(of_flow ~max_size:(1024 * 1024) body |> take_all)
;;

let body_has_service_name expected body =
  let open Yojson.Safe.Util in
  let attrs =
    body
    |> Yojson.Safe.from_string
    |> member "resourceSpans"
    |> to_list
    |> List.hd
    |> member "resource"
    |> member "attributes"
    |> to_list
  in
  List.exists
    (fun attr ->
       String.equal (attr |> member "key" |> to_string) "service.name"
       && String.equal
            (attr |> member "value" |> member "stringValue" |> to_string)
            expected)
    attrs
;;

let body_has_metric expected body =
  let open Yojson.Safe.Util in
  let metrics =
    body
    |> Yojson.Safe.from_string
    |> member "resourceMetrics"
    |> to_list
    |> List.hd
    |> member "scopeMetrics"
    |> to_list
    |> List.hd
    |> member "metrics"
    |> to_list
  in
  List.exists
    (fun metric -> String.equal (metric |> member "name" |> to_string) expected)
    metrics
;;

(* ── Config tests ────────────────────────────────────────────── *)

let test_default_config () =
  let config = default_export_config ~endpoint:"http://localhost:4318/v1/traces" in
  Alcotest.(check string) "endpoint" "http://localhost:4318/v1/traces" config.endpoint;
  Alcotest.(check (float 0.01)) "flush_interval" 5.0 config.flush_interval_sec;
  Alcotest.(check int) "max_batch_size" 512 config.max_batch_size;
  Alcotest.(check int) "max_retries" 3 config.max_retries;
  Alcotest.(check (float 0.01)) "timeout" 10.0 config.timeout_sec
;;

let test_default_config_custom_endpoint () =
  let config = default_export_config ~endpoint:"https://otel.example.com/v1/traces" in
  Alcotest.(check string) "endpoint" "https://otel.example.com/v1/traces" config.endpoint
;;

(* ── Serialization tests ─────────────────────────────────────── *)

let test_build_otlp_body_structure () =
  let span = make_test_span () in
  let body = build_otlp_body ~service_name:"test-svc" [ span ] in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  (* Top-level resourceSpans array *)
  let rs = json |> member "resourceSpans" |> to_list in
  Alcotest.(check int) "resourceSpans count" 1 (List.length rs);
  (* Resource attributes contain service.name *)
  let resource = List.hd rs |> member "resource" in
  let attrs = resource |> member "attributes" |> to_list in
  let service_attr =
    List.find (fun a -> a |> member "key" |> to_string = "service.name") attrs
  in
  let svc_name = service_attr |> member "value" |> member "stringValue" |> to_string in
  Alcotest.(check string) "service.name" "test-svc" svc_name;
  (* Scope spans contain our span *)
  let scope_spans = List.hd rs |> member "scopeSpans" |> to_list in
  let spans = List.hd scope_spans |> member "spans" |> to_list in
  Alcotest.(check int) "span count" 1 (List.length spans);
  let span_json = List.hd spans in
  Alcotest.(check string)
    "traceId"
    "aaaa1234aaaa1234aaaa1234aaaa1234"
    (span_json |> member "traceId" |> to_string);
  Alcotest.(check string) "name" "test_span" (span_json |> member "name" |> to_string)
;;

let test_build_otlp_body_empty () =
  let body = build_otlp_body ~service_name:"svc" [] in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  let scope_spans =
    json
    |> member "resourceSpans"
    |> to_list
    |> List.hd
    |> member "scopeSpans"
    |> to_list
    |> List.hd
    |> member "spans"
    |> to_list
  in
  Alcotest.(check int) "empty spans" 0 (List.length scope_spans)
;;

let test_build_otlp_body_multiple_spans () =
  let s1 = make_test_span ~name:"span_1" () in
  let s2 = make_test_span ~name:"span_2" () in
  let s3 = make_test_span ~name:"span_3" () in
  let body = build_otlp_body ~service_name:"svc" [ s1; s2; s3 ] in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  let spans =
    json
    |> member "resourceSpans"
    |> to_list
    |> List.hd
    |> member "scopeSpans"
    |> to_list
    |> List.hd
    |> member "spans"
    |> to_list
  in
  Alcotest.(check int) "3 spans" 3 (List.length spans)
;;

(* ── Batch splitting tests ───────────────────────────────────── *)

let test_split_batches_single () =
  let spans = List.init 3 (fun _ -> make_test_span ()) in
  let batches = split_batches 10 [] spans in
  Alcotest.(check int) "1 batch" 1 (List.length batches);
  Alcotest.(check int) "3 spans in batch" 3 (List.length (List.hd batches))
;;

let test_split_batches_multiple () =
  let spans = List.init 5 (fun _ -> make_test_span ()) in
  let batches = split_batches 2 [] spans in
  Alcotest.(check int) "3 batches" 3 (List.length batches);
  Alcotest.(check int) "batch 1 size" 2 (List.length (List.nth batches 0));
  Alcotest.(check int) "batch 2 size" 2 (List.length (List.nth batches 1));
  Alcotest.(check int) "batch 3 size" 1 (List.length (List.nth batches 2))
;;

let test_split_batches_exact () =
  let spans = List.init 4 (fun _ -> make_test_span ()) in
  let batches = split_batches 2 [] spans in
  Alcotest.(check int) "2 batches" 2 (List.length batches);
  List.iter (fun b -> Alcotest.(check int) "batch size 2" 2 (List.length b)) batches
;;

let test_split_batches_empty () =
  let batches = split_batches 10 [] [] in
  Alcotest.(check int) "0 batches" 0 (List.length batches)
;;

(* ── Flush with no spans ─────────────────────────────────────── *)

let test_flush_empty_instance () =
  Eio_main.run
  @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run
  @@ fun sw ->
  let instance = make_instance () in
  let config = default_export_config ~endpoint:"http://localhost:19999/v1/traces" in
  let result = flush_to_collector ~sw ~clock ~net ~config instance in
  match result with
  | Exported { span_count; metric_count } ->
    Alcotest.(check int) "0 spans exported" 0 span_count;
    Alcotest.(check int) "0 metrics exported" 0 metric_count
  | _ -> Alcotest.fail "expected Exported for empty flush"
;;

let test_flush_to_collector_exports_batches () =
  let request_count = ref 0 in
  let request_paths = ref [] in
  let bodies = ref [] in
  let handler _conn req body =
    incr request_count;
    request_paths := Uri.path (Cohttp.Request.uri req) :: !request_paths;
    bodies := read_request_body body :: !bodies;
    Cohttp_eio.Server.respond_string ~status:`OK ~body:"{}" ()
  in
  with_mock_collector ~port:18352 handler (fun ~sw ~clock ~net ~endpoint ->
    let instance = make_instance ~service_name:"otel-export-success" () in
    record_span ~name:"span-a" ~turn:1 instance;
    record_span ~name:"span-b" ~turn:2 instance;
    record_span ~name:"span-c" ~turn:3 instance;
    let config =
      { (default_export_config ~endpoint) with
        max_batch_size = 2
      ; max_retries = 0
      ; timeout_sec = 2.0
      }
    in
    match flush_to_collector ~sw ~clock ~net ~config instance with
    | Exported { span_count; metric_count } ->
      Alcotest.(check int) "exported spans" 3 span_count;
      Alcotest.(check int) "exported metrics" 0 metric_count;
      Alcotest.(check int) "two batches posted" 2 !request_count;
      Alcotest.(check int) "spans drained" 0 (Otel_tracer.inst_completed_count instance);
      Alcotest.(check (list string))
        "paths"
        [ "/v1/traces"; "/v1/traces" ]
        (List.rev !request_paths);
      Alcotest.(check bool)
        "body carries service"
        true
        (List.exists (body_has_service_name "otel-export-success") !bodies)
    | Partial_failure _ -> Alcotest.fail "expected full export, got partial failure"
    | Failed { reason } -> Alcotest.failf "expected full export, got failure: %s" reason)
;;

let test_flush_to_collector_exports_metrics () =
  let request_count = ref 0 in
  let request_paths = ref [] in
  let bodies = ref [] in
  let handler _conn req body =
    incr request_count;
    request_paths := Uri.path (Cohttp.Request.uri req) :: !request_paths;
    bodies := read_request_body body :: !bodies;
    Cohttp_eio.Server.respond_string ~status:`OK ~body:"{}" ()
  in
  with_mock_collector ~port:18356 handler (fun ~sw ~clock ~net ~endpoint ->
    let instance = make_instance ~service_name:"otel-export-metrics" () in
    Otel_tracer.inst_record_metric
      instance
      ~name:"agent_core.eval.coverage"
      ~value:0.75
      ~metric_type:Otel_tracer.Gauge;
    let config =
      { (default_export_config ~endpoint) with max_retries = 0; timeout_sec = 2.0 }
    in
    match flush_to_collector ~sw ~clock ~net ~config instance with
    | Exported { span_count; metric_count } ->
      Alcotest.(check int) "no spans" 0 span_count;
      Alcotest.(check int) "one metric" 1 metric_count;
      Alcotest.(check int) "one request" 1 !request_count;
      Alcotest.(check (list string)) "metric path" [ "/v1/metrics" ] !request_paths;
      Alcotest.(check int)
        "metrics drained"
        0
        (List.length (Otel_tracer.inst_get_metrics instance));
      Alcotest.(check bool)
        "body carries metric"
        true
        (List.exists (body_has_metric "agent_core.eval.coverage") !bodies)
    | Partial_failure _ -> Alcotest.fail "expected metric export success"
    | Failed { reason } -> Alcotest.failf "expected metric export success: %s" reason)
;;

let test_flush_to_collector_reports_partial_failure () =
  let request_count = ref 0 in
  let handler _conn _req body =
    ignore (read_request_body body : string);
    incr request_count;
    if !request_count = 1
    then Cohttp_eio.Server.respond_string ~status:`OK ~body:"{}" ()
    else Cohttp_eio.Server.respond_string ~status:`Internal_server_error ~body:"boom" ()
  in
  with_mock_collector ~port:18353 handler (fun ~sw ~clock ~net ~endpoint ->
    let instance = make_instance ~service_name:"otel-export-partial" () in
    record_span ~name:"span-a" ~turn:1 instance;
    record_span ~name:"span-b" ~turn:2 instance;
    record_span ~name:"span-c" ~turn:3 instance;
    let config =
      { (default_export_config ~endpoint) with
        max_batch_size = 2
      ; max_retries = 0
      ; timeout_sec = 2.0
      }
    in
    match flush_to_collector ~sw ~clock ~net ~config instance with
    | Partial_failure { exported; dropped; metric_exported; metric_dropped; reason } ->
      Alcotest.(check int) "exported first batch" 2 exported;
      Alcotest.(check int) "dropped failed batch" 1 dropped;
      Alcotest.(check int) "no metric exported" 0 metric_exported;
      Alcotest.(check int) "no metric dropped" 0 metric_dropped;
      Alcotest.(check string) "reason" "HTTP 500" reason
    | Exported _ -> Alcotest.fail "expected partial failure"
    | Failed { reason } -> Alcotest.failf "expected partial failure, got %s" reason)
;;

let test_flush_to_collector_reports_total_failure () =
  let handler _conn _req body =
    ignore (read_request_body body : string);
    Cohttp_eio.Server.respond_string ~status:`Service_unavailable ~body:"nope" ()
  in
  with_mock_collector ~port:18354 handler (fun ~sw ~clock ~net ~endpoint ->
    let instance = make_instance ~service_name:"otel-export-fail" () in
    record_span ~name:"span-a" ~turn:1 instance;
    record_span ~name:"span-b" ~turn:2 instance;
    let config =
      { (default_export_config ~endpoint) with
        max_batch_size = 10
      ; max_retries = 0
      ; timeout_sec = 2.0
      }
    in
    match flush_to_collector ~sw ~clock ~net ~config instance with
    | Failed { reason } -> Alcotest.(check string) "reason" "HTTP 503" reason
    | Exported _ -> Alcotest.fail "expected total failure"
    | Partial_failure _ -> Alcotest.fail "expected total failure, got partial")
;;

let test_force_flush_updates_total_exported () =
  let handler _conn _req body =
    ignore (read_request_body body : string);
    Cohttp_eio.Server.respond_string ~status:`OK ~body:"{}" ()
  in
  with_mock_collector ~port:18355 handler (fun ~sw ~clock ~net ~endpoint ->
    let instance = make_instance ~service_name:"otel-export-force" () in
    record_span ~name:"span-a" ~turn:1 instance;
    record_span ~name:"span-b" ~turn:2 instance;
    let config =
      { (default_export_config ~endpoint) with
        flush_interval_sec = 60.0
      ; max_batch_size = 10
      ; max_retries = 0
      ; timeout_sec = 2.0
      }
    in
    let exporter = start_daemon ~sw ~clock ~net ~config instance in
    Alcotest.(check int) "initial total" 0 (total_exported exporter);
    match force_flush ~sw ~clock ~net exporter with
    | Exported { span_count; metric_count } ->
      Alcotest.(check int) "force span count" 2 span_count;
      Alcotest.(check int) "force metric count" 0 metric_count;
      Alcotest.(check int) "total exported" 2 (total_exported exporter)
    | Partial_failure _ -> Alcotest.fail "expected force flush success"
    | Failed { reason } -> Alcotest.failf "expected force flush success: %s" reason)
;;

exception Cancel_test

let test_export_batch_cancellation_not_retried () =
  let request_count = ref 0 in
  let handler _conn _req body =
    ignore (read_request_body body : string);
    incr request_count;
    Cohttp_eio.Server.respond_string ~status:`Internal_server_error ~body:"boom" ()
  in
  with_mock_collector ~port:18357 handler (fun ~sw ~clock ~net ~endpoint ->
    let instance = make_instance ~service_name:"otel-export-cancel" () in
    record_span ~name:"span-a" ~turn:1 instance;
    let config =
      { (default_export_config ~endpoint) with max_retries = 3; timeout_sec = 0.1 }
    in
    let t0 = Eio.Time.now clock in
    let outcome = ref None in
    (try
       Eio.Switch.run
       @@ fun export_sw ->
       Eio.Fiber.fork ~sw:export_sw (fun () ->
         outcome
         := Some
              (try
                 `Result (flush_to_collector ~sw:export_sw ~clock ~net ~config instance)
               with
               | Eio.Cancel.Cancelled _ -> `Cancelled
               | exn -> `Other exn));
       Eio.Time.sleep clock 0.3;
       Eio.Switch.fail export_sw Cancel_test
     with
     | Cancel_test -> ());
    let elapsed = Eio.Time.now clock -. t0 in
    Alcotest.(check bool) "cancelled quickly" true (elapsed < 1.0);
    match !outcome with
    | None -> Alcotest.fail "expected outcome before switch failed"
    | Some `Cancelled -> ()
    | Some (`Result _) -> Alcotest.fail "expected cancellation, got result"
    | Some (`Other exn) ->
      Alcotest.failf "expected cancellation, got %s" (Printexc.to_string exn))
;;

(* ── Export result type tests ────────────────────────────────── *)

let test_export_result_variants () =
  (* Verify constructors are well-formed *)
  let e = Exported { span_count = 5; metric_count = 7 } in
  let p =
    Partial_failure
      { exported = 3
      ; dropped = 2
      ; metric_exported = 4
      ; metric_dropped = 1
      ; reason = "timeout"
      }
  in
  let f = Failed { reason = "connection refused" } in
  (match e with
   | Exported { span_count; metric_count } ->
     Alcotest.(check int) "exported spans" 5 span_count;
     Alcotest.(check int) "exported metrics" 7 metric_count
   | _ -> ());
  (match p with
   | Partial_failure { exported; dropped; metric_exported; metric_dropped; _ } ->
     Alcotest.(check int) "partial exported" 3 exported;
     Alcotest.(check int) "partial dropped" 2 dropped;
     Alcotest.(check int) "partial metric exported" 4 metric_exported;
     Alcotest.(check int) "partial metric dropped" 1 metric_dropped
   | _ -> ());
  match f with
  | Failed { reason } ->
    Alcotest.(check string) "failed reason" "connection refused" reason
  | _ -> ()
;;

(* ── Instance integration test ───────────────────────────────── *)

let test_instance_flush_clears_spans () =
  Eio_main.run
  @@ fun _env ->
  let instance = make_instance () in
  let attrs : Tracing.span_attrs =
    { name = "test_op"
    ; agent_name = "test_agent"
    ; turn = 1
    ; kind = Tracing.Agent_run
    ; extra = []
    ; links = []
    }
  in
  let span = Otel_tracer.inst_start_span instance attrs in
  Otel_tracer.inst_end_span instance span ~ok:true;
  Alcotest.(check int) "1 completed" 1 (Otel_tracer.inst_completed_count instance);
  let flushed = Otel_tracer.inst_flush instance in
  Alcotest.(check int) "flushed 1" 1 (List.length flushed);
  Alcotest.(check int) "0 after flush" 0 (Otel_tracer.inst_completed_count instance)
;;

(* ── Total exported counter ──────────────────────────────────── *)

let test_total_exported_via_daemon () =
  Eio_main.run
  @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let instance = make_instance () in
  let config =
    { (default_export_config ~endpoint:"http://127.0.0.1:1/v1/traces") with
      flush_interval_sec = 60.0
    }
  in
  (* start_daemon with unreachable endpoint + long interval.
     The Switch.run exits immediately after we check total_exported,
     which cancels the daemon fiber. *)
  Eio.Switch.run
  @@ fun sw ->
  let t = start_daemon ~sw ~clock ~net ~config instance in
  Alcotest.(check int) "initial 0" 0 (total_exported t)
;;

(* Switch exits here → daemon fiber cancelled *)

(* ── Test suite ──────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "otel_export"
    [ ( "config"
      , [ Alcotest.test_case "default_config" `Quick test_default_config
        ; Alcotest.test_case "custom_endpoint" `Quick test_default_config_custom_endpoint
        ] )
    ; ( "serialization"
      , [ Alcotest.test_case "otlp_body_structure" `Quick test_build_otlp_body_structure
        ; Alcotest.test_case "otlp_body_empty" `Quick test_build_otlp_body_empty
        ; Alcotest.test_case
            "otlp_body_multiple"
            `Quick
            test_build_otlp_body_multiple_spans
        ] )
    ; ( "batch"
      , [ Alcotest.test_case "single_batch" `Quick test_split_batches_single
        ; Alcotest.test_case "multiple_batches" `Quick test_split_batches_multiple
        ; Alcotest.test_case "exact_split" `Quick test_split_batches_exact
        ; Alcotest.test_case "empty" `Quick test_split_batches_empty
        ] )
    ; ( "flush"
      , [ Alcotest.test_case "empty_instance" `Quick test_flush_empty_instance
        ; Alcotest.test_case
            "exports batches"
            `Quick
            test_flush_to_collector_exports_batches
        ; Alcotest.test_case
            "exports metrics"
            `Quick
            test_flush_to_collector_exports_metrics
        ; Alcotest.test_case
            "partial failure"
            `Quick
            test_flush_to_collector_reports_partial_failure
        ; Alcotest.test_case
            "total failure"
            `Quick
            test_flush_to_collector_reports_total_failure
        ; Alcotest.test_case
            "force flush total"
            `Quick
            test_force_flush_updates_total_exported
        ; Alcotest.test_case
            "cancellation not retried"
            `Quick
            test_export_batch_cancellation_not_retried
        ] )
    ; "result_types", [ Alcotest.test_case "variants" `Quick test_export_result_variants ]
    ; ( "instance"
      , [ Alcotest.test_case "flush_clears" `Quick test_instance_flush_clears_spans
        ; Alcotest.test_case "total_exported_daemon" `Quick test_total_exported_via_daemon
        ] )
    ]
;;
