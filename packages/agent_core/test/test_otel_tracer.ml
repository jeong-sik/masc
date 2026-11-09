(** Tests for otel_tracer.ml — OpenTelemetry-compatible tracer. *)

open Alcotest
open Agent_core

let with_eio f () = Eio_main.run (fun _env -> f ())

(* -- Helpers ------------------------------------------------------------ *)

let default_attrs
      ?(name = "test_op")
      ?(agent = "test-agent")
      ?(turn = 1)
      ?(kind = Tracing.Agent_run)
      ?(extra = [])
      ?(links = [])
      ()
  : Tracing.span_attrs
  =
  { kind; name; agent_name = agent; turn; extra; links }
;;

let is_hex s =
  String.length s > 0
  && String.to_seq s
     |> Seq.for_all (fun c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
;;

let json_assoc_field key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

(* -- Config ------------------------------------------------------------- *)

let test_default_config_is_env_free () =
  check
    string
    "service_name"
    Otel_tracer.default_service_name
    Otel_tracer.default_config.service_name;
  check (option string) "endpoint" None Otel_tracer.default_config.endpoint
;;

let test_default_config_from_env_reads_getenv_at_call_time () =
  let endpoint = "http://collector.example/v1/traces" in
  let calls = ref [] in
  let getenv name =
    calls := name :: !calls;
    if String.equal name Otel_tracer.otel_endpoint_env_var then Some endpoint else None
  in
  let config = Otel_tracer.default_config_from_env ~getenv () in
  check string "service_name" Otel_tracer.default_service_name config.service_name;
  check (option string) "endpoint" (Some endpoint) config.endpoint;
  check (list string) "env keys" [ Otel_tracer.otel_endpoint_env_var ] (List.rev !calls)
;;

let test_create_instance_reads_env_at_call_time () =
  let endpoint = "http://ctor.example/v1/traces" in
  let calls = ref [] in
  let getenv name =
    calls := name :: !calls;
    if String.equal name Otel_tracer.otel_endpoint_env_var then Some endpoint else None
  in
  let inst = Otel_tracer.create_instance ~getenv () in
  check (option string) "endpoint" (Some endpoint) inst.config.endpoint;
  check (list string) "env keys" [ Otel_tracer.otel_endpoint_env_var ] (List.rev !calls)
;;

let test_create_instance_eio_reads_env_at_call_time () =
  let endpoint = "http://ctor-eio.example/v1/traces" in
  let calls = ref [] in
  let getenv name =
    calls := name :: !calls;
    if String.equal name Otel_tracer.otel_endpoint_env_var then Some endpoint else None
  in
  let inst = Otel_tracer.create_instance_eio ~getenv () in
  check (option string) "endpoint" (Some endpoint) inst.config.endpoint;
  check (list string) "env keys" [ Otel_tracer.otel_endpoint_env_var ] (List.rev !calls)
;;

(* ── Span Lifecycle ──────────────────────────────────────────────── *)

let test_start_span_name_format () =
  let inst = Otel_tracer.create_instance () in
  let span =
    Otel_tracer.inst_start_span inst (default_attrs ~kind:Tracing.Api_call ~name:"chat" ())
  in
  check string "name is kind/name" "api_call/chat" span.name;
  Otel_tracer.inst_end_span inst span ~ok:true
;;

let test_start_span_attributes () =
  let inst = Otel_tracer.create_instance () in
  let span =
    Otel_tracer.inst_start_span inst
      (default_attrs
         ~agent:"my-agent"
         ~turn:3
         ~name:"do_thing"
         ~extra:[ "custom_key", "custom_val" ]
         ())
  in
  let attrs = span.attributes in
  check
    bool
    "has gen_ai.agent.name"
    true
    (List.mem ("gen_ai.agent.name", "my-agent") attrs);
  check bool "has gen_ai.turn" true (List.mem ("gen_ai.turn", "3") attrs);
  check
    bool
    "has gen_ai.operation.name"
    true
    (List.mem ("gen_ai.operation.name", "do_thing") attrs);
  check bool "has extra attr" true (List.mem ("custom_key", "custom_val") attrs);
  Otel_tracer.inst_end_span inst span ~ok:true
;;

let test_start_span_kind_mapping () =
  let inst = Otel_tracer.create_instance () in
  let span = Otel_tracer.inst_start_span inst (default_attrs ~kind:Tracing.Api_call ()) in
  check int "Api_call maps to Client (3)" 3 (Otel_tracer.otel_span_kind_to_int span.kind);
  Otel_tracer.inst_end_span inst span ~ok:true;
  let span2 = Otel_tracer.inst_start_span inst (default_attrs ~kind:Tracing.Agent_run ()) in
  check
    int
    "Agent_run maps to Internal (1)"
    1
    (Otel_tracer.otel_span_kind_to_int span2.kind);
  Otel_tracer.inst_end_span inst span2 ~ok:true
;;

let test_end_span_sets_status () =
  let inst = Otel_tracer.create_instance () in
  let span_ok = Otel_tracer.inst_start_span inst (default_attrs ~name:"ok_op" ()) in
  Otel_tracer.inst_end_span inst span_ok ~ok:true;
  let span_ok = List.hd (Otel_tracer.inst_flush inst) in
  check (option bool) "ok=true sets Some true" (Some true) span_ok.status;
  check bool "end_time_ns is set" true (span_ok.end_time_ns <> None);
  let span_err = Otel_tracer.inst_start_span inst (default_attrs ~name:"err_op" ()) in
  Otel_tracer.inst_end_span inst span_err ~ok:false;
  let span_err = List.hd (Otel_tracer.inst_flush inst) in
  check (option bool) "ok=false sets Some false" (Some false) span_err.status
;;

let test_end_span_moves_to_completed () =
  let inst = Otel_tracer.create_instance () in
  let span = Otel_tracer.inst_start_span inst (default_attrs ()) in
  check int "completed=0 after start" 0 (Otel_tracer.inst_completed_count inst);
  Otel_tracer.inst_end_span inst span ~ok:true;
  check int "completed=1 after end" 1 (Otel_tracer.inst_completed_count inst)
;;

let test_start_span_hex_ids () =
  let inst = Otel_tracer.create_instance () in
  let span = Otel_tracer.inst_start_span inst (default_attrs ()) in
  check int "trace_id is 32 chars" 32 (String.length span.trace_id);
  check int "span_id is 16 chars" 16 (String.length span.span_id);
  check bool "trace_id is valid hex" true (is_hex span.trace_id);
  check bool "span_id is valid hex" true (is_hex span.span_id);
  check
    bool
    "trace_id is not all zero"
    false
    (String.for_all (Char.equal '0') span.trace_id);
  check
    bool
    "span_id is not all zero"
    false
    (String.for_all (Char.equal '0') span.span_id);
  Otel_tracer.inst_end_span inst span ~ok:true
;;

(* ── Span Hierarchy ──────────────────────────────────────────────── *)

let test_child_inherits_trace_id () =
  let inst = Otel_tracer.create_instance () in
  let parent = Otel_tracer.inst_start_span inst (default_attrs ~name:"parent" ()) in
  let child = Otel_tracer.inst_start_span inst (default_attrs ~name:"child" ()) in
  check string "child inherits parent trace_id" parent.trace_id child.trace_id;
  Otel_tracer.inst_end_span inst child ~ok:true;
  Otel_tracer.inst_end_span inst parent ~ok:true
;;

let test_child_has_parent_span_id () =
  let inst = Otel_tracer.create_instance () in
  let parent = Otel_tracer.inst_start_span inst (default_attrs ~name:"parent" ()) in
  let child = Otel_tracer.inst_start_span inst (default_attrs ~name:"child" ()) in
  check
    (option string)
    "child parent_span_id = parent span_id"
    (Some parent.span_id)
    child.parent_span_id;
  Otel_tracer.inst_end_span inst child ~ok:true;
  Otel_tracer.inst_end_span inst parent ~ok:true
;;

let test_root_span_no_parent () =
  let inst = Otel_tracer.create_instance () in
  let root = Otel_tracer.inst_start_span inst (default_attrs ~name:"root" ()) in
  check (option string) "root has no parent_span_id" None root.parent_span_id;
  Otel_tracer.inst_end_span inst root ~ok:true
;;

(* ── Events & Attributes ────────────────────────────────────────── *)

let test_add_event () =
  let inst = Otel_tracer.create_instance () in
  let module T = (val Otel_tracer.tracer_of_instance inst : Tracing.TRACER) in
  let span = T.start_span (default_attrs ()) in
  T.add_event span "something happened";
  T.end_span span ~ok:true;
  let span = List.hd (Otel_tracer.inst_flush inst) in
  check int "events list has 1 entry" 1 (List.length span.events);
  let evt = List.hd span.events in
  check string "event name" "something happened" evt.event_name;
  check bool "timestamp > 0" true (Int64.compare evt.timestamp_ns 0L > 0)
;;

let test_add_attrs () =
  let inst = Otel_tracer.create_instance () in
  let module T = (val Otel_tracer.tracer_of_instance inst : Tracing.TRACER) in
  let span = T.start_span (default_attrs ()) in
  T.add_attrs span [ "extra_k", "extra_v" ];
  T.end_span span ~ok:true;
  let span = List.hd (Otel_tracer.inst_flush inst) in
  check bool "contains new attr" true (List.mem ("extra_k", "extra_v") span.attributes)
;;

let test_multiple_events_order () =
  let inst = Otel_tracer.create_instance () in
  let module T = (val Otel_tracer.tracer_of_instance inst : Tracing.TRACER) in
  let span = T.start_span (default_attrs ()) in
  T.add_event span "first";
  T.add_event span "second";
  T.add_event span "third";
  T.end_span span ~ok:true;
  let span = List.hd (Otel_tracer.inst_flush inst) in
  check int "3 events" 3 (List.length span.events);
  let names = List.map (fun (e : Otel_tracer.otel_event) -> e.event_name) span.events in
  check (list string) "insertion order preserved" [ "first"; "second"; "third" ] names
;;

(* ── Buffer Management ───────────────────────────────────────────── *)

let test_flush_returns_completed () =
  let inst = Otel_tracer.create_instance () in
  let s1 = Otel_tracer.inst_start_span inst (default_attrs ~name:"s1" ()) in
  Otel_tracer.inst_end_span inst s1 ~ok:true;
  let s2 = Otel_tracer.inst_start_span inst (default_attrs ~name:"s2" ()) in
  Otel_tracer.inst_end_span inst s2 ~ok:true;
  let flushed = Otel_tracer.inst_flush inst in
  check int "flush returns 2 spans" 2 (List.length flushed);
  check int "completed_count is 0 after flush" 0 (Otel_tracer.inst_completed_count inst)
;;

let test_double_flush () =
  let inst = Otel_tracer.create_instance () in
  let s = Otel_tracer.inst_start_span inst (default_attrs ()) in
  Otel_tracer.inst_end_span inst s ~ok:true;
  let first = Otel_tracer.inst_flush inst in
  check int "first flush has 1" 1 (List.length first);
  let second = Otel_tracer.inst_flush inst in
  check int "second flush is empty" 0 (List.length second)
;;

(* ── JSON Serialization ──────────────────────────────────────────── *)

let test_span_to_json_fields () =
  let inst = Otel_tracer.create_instance () in
  let span = Otel_tracer.inst_start_span inst (default_attrs ~name:"json_test" ()) in
  Otel_tracer.inst_end_span inst span ~ok:true;
  let json = Otel_tracer.span_to_json span in
  let required_fields =
    [ "traceId"
    ; "spanId"
    ; "name"
    ; "kind"
    ; "startTimeUnixNano"
    ; "endTimeUnixNano"
    ; "status"
    ; "attributes"
    ; "events"
    ]
  in
  List.iter
    (fun field ->
       check
         bool
         (Printf.sprintf "has field '%s'" field)
         true
         (json_assoc_field field json <> None))
    required_fields
;;

let test_attrs_to_json_format () =
  let json = Otel_tracer.attrs_to_json [ "mykey", "myval" ] in
  match json with
  | `List [ `Assoc fields ] ->
    let key_val = List.assoc_opt "key" fields in
    check
      (option string)
      "key field"
      (Some "mykey")
      (match key_val with
       | Some (`String s) -> Some s
       | _ -> None);
    let value_obj = List.assoc_opt "value" fields in
    let str_val =
      match value_obj with
      | Some obj -> json_assoc_field "stringValue" obj
      | None -> None
    in
    check
      (option string)
      "stringValue field"
      (Some "myval")
      (match str_val with
       | Some (`String s) -> Some s
       | _ -> None)
  | _ -> fail "expected list with one assoc"
;;

let test_status_to_json () =
  let inst = Otel_tracer.create_instance () in
  (* UNSET: status = None *)
  let s_unset = Otel_tracer.inst_start_span inst (default_attrs ~name:"unset" ()) in
  let j_unset = Otel_tracer.status_to_json s_unset in
  check
    (option int)
    "UNSET code=0"
    (Some 0)
    (match json_assoc_field "code" j_unset with
     | Some (`Int n) -> Some n
     | _ -> None);
  Otel_tracer.inst_end_span inst s_unset ~ok:true;
  let s_unset = List.hd (Otel_tracer.inst_flush inst) in
  (* OK: s_unset now has status=Some true (mutable record, mutated by end_span) *)
  let j_ok = Otel_tracer.status_to_json s_unset in
  check
    (option int)
    "OK code=1"
    (Some 1)
    (match json_assoc_field "code" j_ok with
     | Some (`Int n) -> Some n
     | _ -> None);
  check bool "OK has no message field" true (json_assoc_field "message" j_ok = None);
  (* ERROR: status = Some false *)
  let s_err = Otel_tracer.inst_start_span inst (default_attrs ~name:"err" ()) in
  Otel_tracer.inst_end_span inst s_err ~ok:false;
  let s_err = List.hd (Otel_tracer.inst_flush inst) in
  let j_err = Otel_tracer.status_to_json s_err in
  check
    (option int)
    "ERROR code=2"
    (Some 2)
    (match json_assoc_field "code" j_err with
     | Some (`Int n) -> Some n
     | _ -> None);
  check
    (option string)
    "ERROR message"
    (Some "error")
    (match json_assoc_field "message" j_err with
     | Some (`String s) -> Some s
     | _ -> None)
;;

(* ── First-class Module ──────────────────────────────────────────── *)

(* ── Metric API ─────────────────────────────────────────────────── *)

let test_record_metric_counter () =
  let inst : Otel_tracer.instance =
    { config = Otel_tracer.default_config
    ; mu = Otel_tracer.Stdlib_mu (Mutex.create ())
    ; fiber_key = None
    ; current_spans = []
    ; completed_spans = []
    ; metrics = []
    }
  in
  Otel_tracer.inst_record_metric
    inst
    ~name:"agent_core.eval.total"
    ~value:42.0
    ~metric_type:Otel_tracer.Counter;
  let metrics = Otel_tracer.inst_get_metrics inst in
  check int "one metric recorded" 1 (List.length metrics);
  let name, value, mt = List.hd metrics in
  check string "metric name" "agent_core.eval.total" name;
  check (float 0.01) "metric value" 42.0 value;
  check bool "metric type" true (mt = Otel_tracer.Counter)
;;

let test_record_metric_gauge () =
  let inst : Otel_tracer.instance =
    { config = Otel_tracer.default_config
    ; mu = Otel_tracer.Stdlib_mu (Mutex.create ())
    ; fiber_key = None
    ; current_spans = []
    ; completed_spans = []
    ; metrics = []
    }
  in
  Otel_tracer.inst_record_metric
    inst
    ~name:"agent_core.eval.coverage"
    ~value:0.85
    ~metric_type:Otel_tracer.Gauge;
  let metrics = Otel_tracer.inst_get_metrics inst in
  check int "one metric" 1 (List.length metrics);
  let _, _, mt = List.hd metrics in
  check bool "gauge type" true (mt = Otel_tracer.Gauge)
;;

let test_record_multiple_metrics () =
  let inst : Otel_tracer.instance =
    { config = Otel_tracer.default_config
    ; mu = Otel_tracer.Stdlib_mu (Mutex.create ())
    ; fiber_key = None
    ; current_spans = []
    ; completed_spans = []
    ; metrics = []
    }
  in
  Otel_tracer.inst_record_metric
    inst
    ~name:"m1"
    ~value:1.0
    ~metric_type:Otel_tracer.Counter;
  Otel_tracer.inst_record_metric inst ~name:"m2" ~value:2.0 ~metric_type:Otel_tracer.Gauge;
  Otel_tracer.inst_record_metric
    inst
    ~name:"m3"
    ~value:3.0
    ~metric_type:Otel_tracer.Histogram;
  let metrics = Otel_tracer.inst_get_metrics inst in
  check int "three metrics" 3 (List.length metrics);
  let names = List.map (fun (n, _, _) -> n) metrics in
  check (list string) "insertion order" [ "m1"; "m2"; "m3" ] names
;;

let test_clear_metrics () =
  let inst : Otel_tracer.instance =
    { config = Otel_tracer.default_config
    ; mu = Otel_tracer.Stdlib_mu (Mutex.create ())
    ; fiber_key = None
    ; current_spans = []
    ; completed_spans = []
    ; metrics = []
    }
  in
  Otel_tracer.inst_record_metric
    inst
    ~name:"m1"
    ~value:1.0
    ~metric_type:Otel_tracer.Counter;
  Otel_tracer.inst_clear_metrics inst;
  let metrics = Otel_tracer.inst_get_metrics inst in
  check int "empty after clear" 0 (List.length metrics)
;;

let test_metric_entry_to_json () =
  let entry : Otel_tracer.metric_entry =
    { m_name = "agent_core.eval.total"; m_value = 5.0; m_type = Otel_tracer.Counter }
  in
  let json = Otel_tracer.metric_entry_to_json entry in
  check bool "has name" true (json_assoc_field "name" json <> None);
  check
    (option string)
    "name value"
    (Some "agent_core.eval.total")
    (match json_assoc_field "name" json with
     | Some (`String s) -> Some s
     | _ -> None);
  check bool "has sum (counter)" true (json_assoc_field "sum" json <> None)
;;

let test_metric_entry_gauge_json () =
  let entry : Otel_tracer.metric_entry =
    { m_name = "agent_core.eval.coverage"; m_value = 0.95; m_type = Otel_tracer.Gauge }
  in
  let json = Otel_tracer.metric_entry_to_json entry in
  check bool "has gauge" true (json_assoc_field "gauge" json <> None);
  check bool "no sum" true (json_assoc_field "sum" json = None)
;;

(* ── Trace Context Propagation ─────────────────────────────────────── *)

let test_traceparent_of_span () =
  let inst = Otel_tracer.create_instance () in
  let span = Otel_tracer.inst_start_span inst (default_attrs ~name:"propagate" ()) in
  let expected = Printf.sprintf "00-%s-%s-01" span.trace_id span.span_id in
  check string "traceparent sampled" expected (Otel_tracer.traceparent_of_span span);
  let unsampled = Printf.sprintf "00-%s-%s-00" span.trace_id span.span_id in
  check
    string
    "traceparent unsampled"
    unsampled
    (Otel_tracer.traceparent_of_span ~sampled:false span);
  Otel_tracer.inst_end_span inst span ~ok:true
;;

let test_trace_context_headers_of_span () =
  let inst = Otel_tracer.create_instance () in
  let span = Otel_tracer.inst_start_span inst (default_attrs ~name:"headers" ()) in
  let headers =
    Otel_tracer.trace_context_headers_of_span ~tracestate:"vendor=value" span
  in
  check
    (list (pair string string))
    "headers"
    [ "traceparent", Otel_tracer.traceparent_of_span span; "tracestate", "vendor=value" ]
    headers;
  Otel_tracer.inst_end_span inst span ~ok:true
;;

let test_instance_trace_context_headers () =
  let inst = Otel_tracer.create_instance () in
  check
    (list (pair string string))
    "empty when no active span"
    []
    (Otel_tracer.inst_trace_context_headers inst);
  let span = Otel_tracer.inst_start_span inst (default_attrs ~name:"active" ()) in
  check
    (list (pair string string))
    "active span header"
    [ "traceparent", Otel_tracer.traceparent_of_span span ]
    (Otel_tracer.inst_trace_context_headers inst);
  Otel_tracer.inst_end_span inst span ~ok:true
;;

let test_first_class_trace_context_headers () =
  let tracer = Otel_tracer.tracer_of_instance (Otel_tracer.create_instance ()) in
  Tracing.with_span
    tracer
    (default_attrs ~name:"first_class_context" ())
    (fun active_tracer ->
       match Tracing.trace_context_headers active_tracer with
       | [ ("traceparent", value) ] ->
         check int "traceparent length" 55 (String.length value)
       | headers ->
         failf "unexpected headers: %s" (String.concat "," (List.map fst headers)))
;;

let test_map_span_kind () =
  let kind = Otel_tracer.map_span_kind in
  check bool "Agent_run -> Internal" true (kind Tracing.Agent_run = Otel_tracer.Internal);
  check bool "Api_call -> Client" true (kind Tracing.Api_call = Otel_tracer.Client);
  check bool "Tool_exec -> Internal" true (kind Tracing.Tool_exec = Otel_tracer.Internal);
  check bool "Hook_invoke -> Internal" true (kind Tracing.Hook_invoke = Otel_tracer.Internal)
;;

let test_make_span_name () =
  let name kind = Otel_tracer.make_span_name (default_attrs ~kind ~name:"op" ()) in
  check string "agent_run" "agent_run/op" (name Tracing.Agent_run);
  check string "api_call" "api_call/op" (name Tracing.Api_call);
  check string "tool_exec" "tool_exec/op" (name Tracing.Tool_exec);
  check string "hook_invoke" "hook_invoke/op" (name Tracing.Hook_invoke)
;;

(* ── Entry point ─────────────────────────────────────────────────── *)

let () =
  run
    "Otel_tracer"
    [ ( "config"
      , [ test_case "default_config is env-free" `Quick test_default_config_is_env_free
        ; test_case
            "default_config_from_env reads injected env"
            `Quick
            test_default_config_from_env_reads_getenv_at_call_time
        ; test_case
            "create_instance reads env at call time"
            `Quick
            test_create_instance_reads_env_at_call_time
        ; test_case
            "create_instance_eio reads env at call time"
            `Quick
            (with_eio test_create_instance_eio_reads_env_at_call_time)
        ] )
    ; ( "span_lifecycle"
      , [ test_case "start_span name format" `Quick test_start_span_name_format
        ; test_case "start_span attributes" `Quick test_start_span_attributes
        ; test_case "start_span kind mapping" `Quick test_start_span_kind_mapping
        ; test_case "end_span sets status" `Quick test_end_span_sets_status
        ; test_case "end_span moves to completed" `Quick test_end_span_moves_to_completed
        ; test_case "map_span_kind" `Quick test_map_span_kind
        ; test_case "make_span_name" `Quick test_make_span_name
        ; test_case "hex IDs valid" `Quick test_start_span_hex_ids
        ] )
    ; ( "span_hierarchy"
      , [ test_case "child inherits trace_id" `Quick test_child_inherits_trace_id
        ; test_case "child has parent_span_id" `Quick test_child_has_parent_span_id
        ; test_case "root has no parent" `Quick test_root_span_no_parent
        ] )
    ; ( "events_and_attributes"
      , [ test_case "add_event" `Quick test_add_event
        ; test_case "add_attrs" `Quick test_add_attrs
        ; test_case "multiple events preserve order" `Quick test_multiple_events_order
        ] )
    ; ( "buffer_management"
      , [ test_case "flush returns completed" `Quick test_flush_returns_completed
        ; test_case "double flush empty" `Quick test_double_flush
        ] )
    ; ( "json_serialization"
      , [ test_case "span_to_json has required fields" `Quick test_span_to_json_fields
        ; test_case "attrs_to_json format" `Quick test_attrs_to_json_format
        ; test_case "status_to_json codes" `Quick test_status_to_json
        ] )
    ; ( "metrics_api"
      , [ test_case "record counter metric" `Quick test_record_metric_counter
        ; test_case "record gauge metric" `Quick test_record_metric_gauge
        ; test_case "record multiple metrics" `Quick test_record_multiple_metrics
        ; test_case "clear metrics" `Quick test_clear_metrics
        ; test_case "metric_entry_to_json counter" `Quick test_metric_entry_to_json
        ; test_case "metric_entry_to_json gauge" `Quick test_metric_entry_gauge_json
        ] )
    ; ( "trace_context"
      , [ test_case "traceparent of span" `Quick test_traceparent_of_span
        ; test_case
            "trace context headers of span"
            `Quick
            test_trace_context_headers_of_span
        ; test_case
            "instance trace context headers"
            `Quick
            (with_eio test_instance_trace_context_headers)
        ; test_case
            "first-class trace context headers"
            `Quick
            (with_eio test_first_class_trace_context_headers)
        ] )
    ]
;;
