(** Tests for otel_tracer.ml -- OTel-compatible TRACER implementation *)

open Alcotest
open Agent_core

(* -- Helpers ---------------------------------------------------------- *)

let default_attrs
      ?(kind = Tracing.Agent_run)
      ?(name = "test")
      ?(agent_name = "agent-a")
      ?(turn = 1)
      ?(extra = [])
      ?(links = [])
      ()
  : Tracing.span_attrs
  =
  { kind; name; agent_name; turn; extra; links }
;;

let with_reset f () =
  Otel_tracer.reset ();
  Fun.protect ~finally:(fun () -> Otel_tracer.reset ()) f
;;

let with_eio_reset f () =
  Eio_main.run
  @@ fun _env ->
  Otel_tracer.reset ();
  Fun.protect ~finally:(fun () -> Otel_tracer.reset ()) f
;;

(* -- span_lifecycle --------------------------------------------------- *)

let test_start_span_creates_span () =
  let s = Otel_tracer.start_span (default_attrs ()) in
  check int "trace_id length" 32 (String.length s.trace_id);
  check int "span_id length" 16 (String.length s.span_id);
  check bool "end_time not set" true (s.end_time_ns = None);
  check bool "status not set" true (s.status = None);
  check bool "name contains agent_run" true (String.length s.name > 0)
;;

let test_end_span_sets_end_time () =
  let s = Otel_tracer.start_span (default_attrs ()) in
  Otel_tracer.end_span s ~ok:true;
  let s = List.hd (Otel_tracer.flush ()) in
  check bool "end_time is set" true (s.end_time_ns <> None);
  match s.end_time_ns with
  | Some end_t -> check bool "end >= start" true (end_t >= s.start_time_ns)
  | None -> fail "end_time should be set"
;;

let test_end_span_ok_true () =
  let s = Otel_tracer.start_span (default_attrs ()) in
  Otel_tracer.end_span s ~ok:true;
  let s = List.hd (Otel_tracer.flush ()) in
  check (option bool) "status is Some true" (Some true) s.status
;;

let test_end_span_ok_false () =
  let s = Otel_tracer.start_span (default_attrs ()) in
  Otel_tracer.end_span s ~ok:false;
  let s = List.hd (Otel_tracer.flush ()) in
  check (option bool) "status is Some false" (Some false) s.status
;;

(* -- span_kind_mapping ------------------------------------------------ *)

let test_agent_run_maps_to_internal () =
  check
    bool
    "Agent_run -> Internal"
    true
    (Otel_tracer.map_span_kind Tracing.Agent_run = Otel_tracer.Internal)
;;

let test_api_call_maps_to_client () =
  check
    bool
    "Api_call -> Client"
    true
    (Otel_tracer.map_span_kind Tracing.Api_call = Otel_tracer.Client)
;;

let test_tool_exec_maps_to_internal () =
  check
    bool
    "Tool_exec -> Internal"
    true
    (Otel_tracer.map_span_kind Tracing.Tool_exec = Otel_tracer.Internal)
;;

let test_hook_invoke_maps_to_internal () =
  check
    bool
    "Hook_invoke -> Internal"
    true
    (Otel_tracer.map_span_kind Tracing.Hook_invoke = Otel_tracer.Internal)
;;

(* -- semantic_conventions --------------------------------------------- *)

let test_gen_ai_agent_name () =
  let s = Otel_tracer.start_span (default_attrs ~agent_name:"my-agent" ()) in
  Otel_tracer.end_span s ~ok:true;
  let has_attr =
    List.exists (fun (k, v) -> k = "gen_ai.agent.name" && v = "my-agent") s.attributes
  in
  check bool "gen_ai.agent.name present" true has_attr
;;

let test_gen_ai_turn () =
  let s = Otel_tracer.start_span (default_attrs ~turn:7 ()) in
  Otel_tracer.end_span s ~ok:true;
  let has_attr = List.exists (fun (k, v) -> k = "gen_ai.turn" && v = "7") s.attributes in
  check bool "gen_ai.turn present" true has_attr
;;

let test_gen_ai_operation_name () =
  let s = Otel_tracer.start_span (default_attrs ~name:"create_message" ()) in
  Otel_tracer.end_span s ~ok:true;
  let has_attr =
    List.exists
      (fun (k, v) -> k = "gen_ai.operation.name" && v = "create_message")
      s.attributes
  in
  check bool "gen_ai.operation.name present" true has_attr
;;

let test_extra_attrs_included () =
  let s =
    Otel_tracer.start_span
      (default_attrs ~extra:[ "model", "claude-4"; "region", "us" ] ())
  in
  Otel_tracer.end_span s ~ok:true;
  let has_model =
    List.exists (fun (k, v) -> k = "model" && v = "claude-4") s.attributes
  in
  let has_region = List.exists (fun (k, v) -> k = "region" && v = "us") s.attributes in
  check bool "model attr present" true has_model;
  check bool "region attr present" true has_region
;;

(* -- span_name -------------------------------------------------------- *)

let test_span_name_format () =
  let name =
    Otel_tracer.make_span_name
      (default_attrs ~kind:Tracing.Api_call ~name:"create_msg" ())
  in
  check string "format is kind/name" "api_call/create_msg" name
;;

let test_span_name_agent_run () =
  let name =
    Otel_tracer.make_span_name (default_attrs ~kind:Tracing.Agent_run ~name:"main" ())
  in
  check string "agent_run/main" "agent_run/main" name
;;

let test_span_name_tool_exec () =
  let name =
    Otel_tracer.make_span_name (default_attrs ~kind:Tracing.Tool_exec ~name:"grep" ())
  in
  check string "tool_exec/grep" "tool_exec/grep" name
;;

let test_span_name_hook_invoke () =
  let name =
    Otel_tracer.make_span_name (default_attrs ~kind:Tracing.Hook_invoke ~name:"pre" ())
  in
  check string "hook_invoke/pre" "hook_invoke/pre" name
;;

(* -- parent_child ----------------------------------------------------- *)

let test_nested_spans_share_trace_id () =
  let parent = Otel_tracer.start_span (default_attrs ~name:"parent" ()) in
  let child = Otel_tracer.start_span (default_attrs ~name:"child" ()) in
  check string "same trace_id" parent.trace_id child.trace_id;
  Otel_tracer.end_span child ~ok:true;
  Otel_tracer.end_span parent ~ok:true
;;

let test_child_has_parent_span_id () =
  let parent = Otel_tracer.start_span (default_attrs ~name:"parent" ()) in
  let child = Otel_tracer.start_span (default_attrs ~name:"child" ()) in
  check
    (option string)
    "parent_span_id matches"
    (Some parent.span_id)
    child.parent_span_id;
  Otel_tracer.end_span child ~ok:true;
  Otel_tracer.end_span parent ~ok:true
;;

let test_sibling_spans_different_ids () =
  let parent = Otel_tracer.start_span (default_attrs ~name:"parent" ()) in
  let child1 = Otel_tracer.start_span (default_attrs ~name:"child1" ()) in
  Otel_tracer.end_span child1 ~ok:true;
  let child2 = Otel_tracer.start_span (default_attrs ~name:"child2" ()) in
  Otel_tracer.end_span child2 ~ok:true;
  check bool "different span_ids" true (child1.span_id <> child2.span_id);
  check string "same trace_id" parent.trace_id child1.trace_id;
  check string "same trace_id" parent.trace_id child2.trace_id;
  Otel_tracer.end_span parent ~ok:true
;;

let test_root_span_no_parent () =
  let s = Otel_tracer.start_span (default_attrs ()) in
  check (option string) "no parent" None s.parent_span_id;
  Otel_tracer.end_span s ~ok:true
;;

(* -- events ----------------------------------------------------------- *)

let test_add_event_records () =
  let s = Otel_tracer.start_span (default_attrs ()) in
  Otel_tracer.add_event s "something happened";
  Otel_tracer.end_span s ~ok:true;
  let s = List.hd (Otel_tracer.flush ()) in
  check int "one event" 1 (List.length s.events);
  check string "event name" "something happened" (List.hd s.events).event_name;
  Otel_tracer.end_span s ~ok:true
;;

let test_multiple_events_preserved () =
  let s = Otel_tracer.start_span (default_attrs ()) in
  Otel_tracer.add_event s "event1";
  Otel_tracer.add_event s "event2";
  Otel_tracer.add_event s "event3";
  Otel_tracer.end_span s ~ok:true;
  let s = List.hd (Otel_tracer.flush ()) in
  check int "three events" 3 (List.length s.events);
  let names = List.map (fun (e : Otel_tracer.otel_event) -> e.event_name) s.events in
  check (list string) "event order" [ "event1"; "event2"; "event3" ] names;
  Otel_tracer.end_span s ~ok:true
;;

(* -- attributes ------------------------------------------------------- *)

let test_add_attrs_appends () =
  let s = Otel_tracer.start_span (default_attrs ()) in
  let initial_count = List.length s.attributes in
  Otel_tracer.add_attrs s [ "extra_key", "extra_val" ];
  Otel_tracer.end_span s ~ok:true;
  let s = List.hd (Otel_tracer.flush ()) in
  check int "one more attr" (initial_count + 1) (List.length s.attributes);
  let has = List.exists (fun (k, v) -> k = "extra_key" && v = "extra_val") s.attributes in
  check bool "new attr present" true has;
  Otel_tracer.end_span s ~ok:true
;;

let test_multiple_add_attrs_accumulate () =
  let s = Otel_tracer.start_span (default_attrs ()) in
  let initial_count = List.length s.attributes in
  Otel_tracer.add_attrs s [ "k1", "v1" ];
  Otel_tracer.add_attrs s [ "k2", "v2"; "k3", "v3" ];
  Otel_tracer.end_span s ~ok:true;
  let s = List.hd (Otel_tracer.flush ()) in
  check int "three more attrs" (initial_count + 3) (List.length s.attributes);
  Otel_tracer.end_span s ~ok:true
;;

(* -- export ----------------------------------------------------------- *)

let test_span_to_json_valid () =
  let s = Otel_tracer.start_span (default_attrs ()) in
  Otel_tracer.end_span s ~ok:true;
  let json = Otel_tracer.span_to_json s in
  (* Should be a JSON object with required fields *)
  let open Yojson.Safe.Util in
  let trace_id = json |> member "traceId" |> to_string in
  let span_id = json |> member "spanId" |> to_string in
  let name = json |> member "name" |> to_string in
  check int "traceId length" 32 (String.length trace_id);
  check int "spanId length" 16 (String.length span_id);
  check bool "name non-empty" true (String.length name > 0)
;;

let test_span_to_json_has_parent () =
  let parent = Otel_tracer.start_span (default_attrs ~name:"p" ()) in
  let child = Otel_tracer.start_span (default_attrs ~name:"c" ()) in
  Otel_tracer.end_span child ~ok:true;
  Otel_tracer.end_span parent ~ok:true;
  let json = Otel_tracer.span_to_json child in
  let open Yojson.Safe.Util in
  let pid = json |> member "parentSpanId" |> to_string in
  check string "parentSpanId matches" parent.span_id pid
;;

let test_to_otlp_json_wraps_in_resource_spans () =
  let s = Otel_tracer.start_span (default_attrs ()) in
  Otel_tracer.end_span s ~ok:true;
  let json = Otel_tracer.to_otlp_json Otel_tracer.default_config in
  let open Yojson.Safe.Util in
  let rs = json |> member "resourceSpans" |> to_list in
  check bool "resourceSpans non-empty" true (List.length rs > 0);
  let scope_spans = List.hd rs |> member "scopeSpans" |> to_list in
  check bool "scopeSpans non-empty" true (List.length scope_spans > 0);
  let spans = List.hd scope_spans |> member "spans" |> to_list in
  check bool "spans non-empty" true (List.length spans > 0)
;;

let test_to_otlp_json_service_name () =
  let s = Otel_tracer.start_span (default_attrs ()) in
  Otel_tracer.end_span s ~ok:true;
  let cfg = { Otel_tracer.service_name = "my-service"; endpoint = None } in
  let json = Otel_tracer.to_otlp_json cfg in
  let j_str = Yojson.Safe.to_string json in
  check
    bool
    "contains service name"
    true
    (try
       let _ = String.index_from j_str 0 'm' in
       String.length j_str > 0
       &&
       let open Yojson.Safe.Util in
       let rs = json |> member "resourceSpans" |> to_list in
       let resource = List.hd rs |> member "resource" in
       let attrs = resource |> member "attributes" |> to_list in
       List.exists
         (fun a ->
            a |> member "key" |> to_string = "service.name"
            && a |> member "value" |> member "stringValue" |> to_string = "my-service")
         attrs
     with
     | _ -> false)
;;

let test_flush_returns_and_clears () =
  let s1 = Otel_tracer.start_span (default_attrs ~name:"s1" ()) in
  Otel_tracer.end_span s1 ~ok:true;
  let s2 = Otel_tracer.start_span (default_attrs ~name:"s2" ()) in
  Otel_tracer.end_span s2 ~ok:true;
  check int "2 completed before flush" 2 (Otel_tracer.completed_count ());
  let flushed = Otel_tracer.flush () in
  check int "flush returns 2" 2 (List.length flushed);
  check int "0 completed after flush" 0 (Otel_tracer.completed_count ())
;;

let test_reset_clears_everything () =
  let s = Otel_tracer.start_span (default_attrs ()) in
  ignore s;
  (* s is still active (not ended) *)
  check bool "active > 0" true (Otel_tracer.active_count () > 0);
  Otel_tracer.reset ();
  check int "active after reset" 0 (Otel_tracer.active_count ());
  check int "completed after reset" 0 (Otel_tracer.completed_count ())
;;

(* -- integration ------------------------------------------------------ *)

let test_create_returns_valid_tracer () =
  let tracer = Otel_tracer.create () in
  let module T = (val tracer : Tracing.TRACER) in
  let span = T.start_span (default_attrs ()) in
  T.add_event span "evt";
  T.add_attrs span [ "k", "v" ];
  T.end_span span ~ok:true;
  check pass "tracer works" () ()
;;

let test_with_span_works_with_otel () =
  let tracer = Otel_tracer.create () in
  let result =
    Tracing.with_span tracer (default_attrs ~name:"with_span_test" ()) (fun _t -> 42)
  in
  check int "returns value" 42 result
;;

let test_interchangeable_with_null () =
  (* The same code should work with both null and otel tracers *)
  let run_with_tracer (t : Tracing.t) =
    Tracing.with_span t (default_attrs ~name:"interop" ()) (fun _t -> "ok")
  in
  let r1 = run_with_tracer Tracing.null in
  let r2 = run_with_tracer (Otel_tracer.create ()) in
  check string "null tracer result" "ok" r1;
  check string "otel tracer result" "ok" r2
;;

(* -- test runner ------------------------------------------------------ *)

let () =
  run
    "OTel Tracer"
    [ ( "span_lifecycle"
      , [ test_case
            "start_span creates span"
            `Quick
            (with_reset test_start_span_creates_span)
        ; test_case
            "end_span sets end_time"
            `Quick
            (with_reset test_end_span_sets_end_time)
        ; test_case "end_span ok:true" `Quick (with_reset test_end_span_ok_true)
        ; test_case "end_span ok:false" `Quick (with_reset test_end_span_ok_false)
        ] )
    ; ( "span_kind_mapping"
      , [ test_case
            "Agent_run -> Internal"
            `Quick
            (with_reset test_agent_run_maps_to_internal)
        ; test_case "Api_call -> Client" `Quick (with_reset test_api_call_maps_to_client)
        ; test_case
            "Tool_exec -> Internal"
            `Quick
            (with_reset test_tool_exec_maps_to_internal)
        ; test_case
            "Hook_invoke -> Internal"
            `Quick
            (with_reset test_hook_invoke_maps_to_internal)
        ] )
    ; ( "semantic_conventions"
      , [ test_case "gen_ai.agent.name" `Quick (with_reset test_gen_ai_agent_name)
        ; test_case "gen_ai.turn" `Quick (with_reset test_gen_ai_turn)
        ; test_case "gen_ai.operation.name" `Quick (with_reset test_gen_ai_operation_name)
        ; test_case "extra attrs included" `Quick (with_reset test_extra_attrs_included)
        ] )
    ; ( "span_name"
      , [ test_case "kind/name format" `Quick (with_reset test_span_name_format)
        ; test_case "agent_run/name" `Quick (with_reset test_span_name_agent_run)
        ; test_case "tool_exec/name" `Quick (with_reset test_span_name_tool_exec)
        ; test_case "hook_invoke/name" `Quick (with_reset test_span_name_hook_invoke)
        ] )
    ; ( "parent_child"
      , [ test_case
            "nested share trace_id"
            `Quick
            (with_reset test_nested_spans_share_trace_id)
        ; test_case
            "child has parent_span_id"
            `Quick
            (with_reset test_child_has_parent_span_id)
        ; test_case
            "siblings different span_ids"
            `Quick
            (with_reset test_sibling_spans_different_ids)
        ; test_case "root has no parent" `Quick (with_reset test_root_span_no_parent)
        ] )
    ; ( "events"
      , [ test_case "add_event records" `Quick (with_reset test_add_event_records)
        ; test_case
            "multiple events preserved"
            `Quick
            (with_reset test_multiple_events_preserved)
        ] )
    ; ( "attributes"
      , [ test_case "add_attrs appends" `Quick (with_reset test_add_attrs_appends)
        ; test_case
            "multiple add_attrs accumulate"
            `Quick
            (with_reset test_multiple_add_attrs_accumulate)
        ] )
    ; ( "export"
      , [ test_case "span_to_json valid" `Quick (with_reset test_span_to_json_valid)
        ; test_case
            "span_to_json has parent"
            `Quick
            (with_reset test_span_to_json_has_parent)
        ; test_case
            "to_otlp_json wraps"
            `Quick
            (with_reset test_to_otlp_json_wraps_in_resource_spans)
        ; test_case
            "to_otlp_json service_name"
            `Quick
            (with_reset test_to_otlp_json_service_name)
        ; test_case
            "flush returns and clears"
            `Quick
            (with_reset test_flush_returns_and_clears)
        ; test_case
            "reset clears everything"
            `Quick
            (with_reset test_reset_clears_everything)
        ] )
    ; ( "integration"
      , [ test_case
            "create returns valid tracer"
            `Quick
            (with_eio_reset test_create_returns_valid_tracer)
        ; test_case
            "with_span works with otel"
            `Quick
            (with_eio_reset test_with_span_works_with_otel)
        ; test_case
            "interchangeable with null"
            `Quick
            (with_eio_reset test_interchangeable_with_null)
        ] )
    ; ( "edge_cases"
      , [ test_case
            "span_to_json with end_time_ns None"
            `Quick
            (with_reset (fun () ->
               (* In-progress span: end_time_ns is None, JSON should use start_time_ns *)
               let s = Otel_tracer.start_span (default_attrs ~name:"in_progress" ()) in
               let json = Otel_tracer.span_to_json s in
               let open Yojson.Safe.Util in
               let start_ns = json |> member "startTimeUnixNano" |> to_string in
               let end_ns = json |> member "endTimeUnixNano" |> to_string in
               check string "end falls back to start" start_ns end_ns;
               check
                 bool
                 "status is UNSET"
                 true
                 (json |> member "status" |> member "code" |> to_int = 0);
               Otel_tracer.end_span s ~ok:true))
        ; test_case
            "flush empties completed_spans"
            `Quick
            (with_reset (fun () ->
               let s1 = Otel_tracer.start_span (default_attrs ~name:"f1" ()) in
               Otel_tracer.end_span s1 ~ok:true;
               let s2 = Otel_tracer.start_span (default_attrs ~name:"f2" ()) in
               Otel_tracer.end_span s2 ~ok:false;
               check int "2 before flush" 2 (Otel_tracer.completed_count ());
               let flushed = Otel_tracer.flush () in
               check int "flushed 2" 2 (List.length flushed);
               check int "0 after flush" 0 (Otel_tracer.completed_count ());
               (* Second flush returns empty *)
               let flushed2 = Otel_tracer.flush () in
               check int "second flush empty" 0 (List.length flushed2)))
        ; test_case
            "reset clears both current and completed"
            `Quick
            (with_reset (fun () ->
               (* Create active span (not ended) *)
               let _active = Otel_tracer.start_span (default_attrs ~name:"active" ()) in
               (* Create completed span *)
               let done_ = Otel_tracer.start_span (default_attrs ~name:"done" ()) in
               Otel_tracer.end_span done_ ~ok:true;
               check bool "has active" true (Otel_tracer.active_count () > 0);
               check bool "has completed" true (Otel_tracer.completed_count () > 0);
               Otel_tracer.reset ();
               check int "active after reset" 0 (Otel_tracer.active_count ());
               check int "completed after reset" 0 (Otel_tracer.completed_count ())))
        ; test_case
            "concurrent with_span via Eio fibers"
            `Quick
            (with_eio_reset (fun () ->
               (* Already inside Eio_main.run via with_eio_reset *)
               let tracer = Otel_tracer.create_eio () in
               let results = Array.make 4 "" in
               Eio.Fiber.all
                 (List.init 4 (fun i () ->
                    let name = Printf.sprintf "fiber_%d" i in
                    let v =
                      Tracing.with_span tracer (default_attrs ~name ()) (fun _t ->
                        Printf.sprintf "ok_%d" i)
                    in
                    results.(i) <- v));
               (* All fibers completed and produced correct results *)
               Array.iteri
                 (fun i v ->
                    check
                      string
                      (Printf.sprintf "fiber %d" i)
                      (Printf.sprintf "ok_%d" i)
                      v)
                 results))
        ; test_case
            "span_to_json with events"
            `Quick
            (with_reset (fun () ->
               let s = Otel_tracer.start_span (default_attrs ~name:"evts" ()) in
               Otel_tracer.add_event s "start_processing";
               Otel_tracer.add_event s "end_processing";
               Otel_tracer.end_span s ~ok:true;
               let s = List.hd (Otel_tracer.flush ()) in
               let json = Otel_tracer.span_to_json s in
               let open Yojson.Safe.Util in
               let events = json |> member "events" |> to_list in
               check int "2 events in json" 2 (List.length events);
               let name0 = List.hd events |> member "name" |> to_string in
               check string "first event" "start_processing" name0))
        ; test_case
            "span error status json"
            `Quick
            (with_reset (fun () ->
               let s = Otel_tracer.start_span (default_attrs ~name:"err" ()) in
               Otel_tracer.end_span s ~ok:false;
               let s = List.hd (Otel_tracer.flush ()) in
               let json = Otel_tracer.span_to_json s in
               let open Yojson.Safe.Util in
               let code = json |> member "status" |> member "code" |> to_int in
               let msg = json |> member "status" |> member "message" |> to_string in
               check int "error code 2" 2 code;
               check string "error message" "error" msg))
        ; test_case
            "generated IDs are valid hex"
            `Quick
            (with_reset (fun () ->
               let is_hex_char c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') in
               for _ = 1 to 20 do
                 let s = Otel_tracer.start_span (default_attrs ()) in
                 check int "trace_id length" 32 (String.length s.trace_id);
                 check int "span_id length" 16 (String.length s.span_id);
                 String.iter
                   (fun c -> check bool "trace_id hex char" true (is_hex_char c))
                   s.trace_id;
                 String.iter
                   (fun c -> check bool "span_id hex char" true (is_hex_char c))
                   s.span_id;
                 Otel_tracer.end_span s ~ok:true
               done))
        ; test_case
            "generated IDs are unique"
            `Quick
            (with_reset (fun () ->
               let ids =
                 List.init 50 (fun _ ->
                   let s = Otel_tracer.start_span (default_attrs ()) in
                   let id = s.span_id in
                   Otel_tracer.end_span s ~ok:true;
                   id)
               in
               let unique = List.sort_uniq String.compare ids in
               check int "all span_ids unique" (List.length ids) (List.length unique)))
        ] )
    ]
;;
