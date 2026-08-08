(** Tests for Log module — structured logging. *)

open Agent_sdk

(* ── Helpers ──────────────────────────────────────────────────── *)

let log = Log.create ~module_name:"test" ()

let setup () =
  Log.clear_sinks ();
  Log.set_global_level Debug
;;

let wait_until predicate =
  while not (predicate ()) do
    Domain.cpu_relax ()
  done
;;

(* ── Tests ────────────────────────────────────────────────────── *)

let test_level_roundtrip () =
  let levels = [ Log.Debug; Log.Info; Log.Warn; Log.Error ] in
  List.iter
    (fun level ->
       let s = Log.level_to_string level in
       match Log.level_of_string s with
       | Ok l ->
         Alcotest.(check string) "roundtrip" (Log.show_level level) (Log.show_level l)
       | Error msg -> Alcotest.fail msg)
    levels
;;

let test_level_yojson_roundtrip () =
  let levels = [ Log.Debug; Log.Info; Log.Warn; Log.Error ] in
  List.iter
    (fun level ->
       let json = Log.level_to_yojson level in
       match Log.level_of_yojson json with
       | Ok l ->
         Alcotest.(check string)
           "yojson roundtrip"
           (Log.show_level level)
           (Log.show_level l)
       | Error msg -> Alcotest.fail msg)
    levels
;;

let test_level_of_string_error () =
  match Log.level_of_string "invalid" with
  | Ok _ -> Alcotest.fail "expected error"
  | Error _ -> ()
;;

let test_collector_sink () =
  setup ();
  let sink, get = Log.collector_sink () in
  Log.add_sink sink;
  Log.info log "hello" [ Log.S ("key", "val") ];
  let records = get () in
  Alcotest.(check int) "one record" 1 (List.length records);
  let r = List.hd records in
  Alcotest.(check string) "message" "hello" r.message;
  Alcotest.(check string) "module" "test" r.module_name
;;

let test_level_filtering () =
  setup ();
  Log.set_global_level Warn;
  let sink, get = Log.collector_sink () in
  Log.add_sink sink;
  Log.debug log "skipped" [];
  Log.info log "skipped" [];
  Log.warn log "included" [];
  Log.error log "included" [];
  let records = get () in
  Alcotest.(check int) "two records" 2 (List.length records)
;;

let test_field_to_json () =
  let cases =
    [ Log.S ("name", "alice"), ("name", `String "alice")
    ; Log.I ("count", 42), ("count", `Int 42)
    ; Log.F ("ratio", 0.5), ("ratio", `Float 0.5)
    ; Log.B ("ok", true), ("ok", `Bool true)
    ; Log.J ("data", `List [ `Int 1 ]), ("data", `List [ `Int 1 ])
    ]
  in
  List.iter
    (fun (field, (ek, ev)) ->
       let k, v = Log.field_to_json field in
       Alcotest.(check string) "key" ek k;
       Alcotest.(check string)
         "value"
         (Yojson.Safe.to_string ev)
         (Yojson.Safe.to_string v))
    cases
;;

let test_explicit_env_secret_field_is_redacted () =
  let getenv name =
    if String.equal name "OAS_TEST_EXPLICIT_SECRET" then Some "opaque-env-value" else None
  in
  match Llm_provider.Secret.of_env ~getenv "OAS_TEST_EXPLICIT_SECRET" with
  | None -> Alcotest.fail "expected the injected environment value"
  | Some secret ->
    let key, value = Log.field_to_json (Log.Secret ("credential", secret)) in
    Alcotest.(check string) "key" "credential" key;
    Alcotest.(check string) "typed secret" {|"<redacted>"|} (Yojson.Safe.to_string value)
;;

let test_record_to_json () =
  let r : Log.record =
    { ts = 1700000000.0
    ; level = Info
    ; module_name = "api"
    ; message = "request"
    ; fields = [ Log.I ("status", 200) ]
    ; trace_id = Some "abc123"
    ; span_id = None
    }
  in
  let json = Log.record_to_json r in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "msg" "request" (json |> member "msg" |> to_string);
  Alcotest.(check string) "level" "info" (json |> member "level" |> to_string);
  Alcotest.(check string) "module" "api" (json |> member "module" |> to_string);
  Alcotest.(check int) "status" 200 (json |> member "status" |> to_int);
  Alcotest.(check string) "trace_id" "abc123" (json |> member "trace_id" |> to_string)
;;

let test_multiple_sinks () =
  setup ();
  let sink1, get1 = Log.collector_sink () in
  let sink2, get2 = Log.collector_sink () in
  Log.add_sink sink1;
  Log.add_sink sink2;
  Log.info log "fanout" [];
  Alcotest.(check int) "sink1" 1 (List.length (get1 ()));
  Alcotest.(check int) "sink2" 1 (List.length (get2 ()))
;;

let test_concurrent_add_sink_keeps_all_registrations () =
  setup ();
  let domain_count = max 2 (min 8 (Domain.recommended_domain_count ())) in
  let rounds = 32 in
  for round = 1 to rounds do
    Log.clear_sinks ();
    let ready = Atomic.make 0 in
    let go = Atomic.make false in
    let counters = Array.init domain_count (fun _ -> Atomic.make 0) in
    let domains =
      List.init domain_count (fun i ->
        Domain.spawn (fun () ->
          ignore (Atomic.fetch_and_add ready 1);
          wait_until (fun () -> Atomic.get go);
          let sink (_record : Log.record) =
            ignore (Atomic.fetch_and_add counters.(i) 1)
          in
          Log.add_sink sink))
    in
    wait_until (fun () -> Atomic.get ready = domain_count);
    Atomic.set go true;
    List.iter Domain.join domains;
    Log.info log "fanout-concurrent" [ Log.I ("round", round) ];
    Array.iteri
      (fun i counter ->
         Alcotest.(check int)
           (Printf.sprintf "round %d sink %d invoked once" round i)
           1
           (Atomic.get counter))
      counters
  done
;;

let test_clear_sinks_racing_add_sink_removes_stale_sinks () =
  setup ();
  let rounds = 64 in
  for round = 1 to rounds do
    Log.clear_sinks ();
    let old_hits = Atomic.make 0 in
    let new_hits = Atomic.make 0 in
    let old_sink (_record : Log.record) = ignore (Atomic.fetch_and_add old_hits 1) in
    let new_sink (_record : Log.record) = ignore (Atomic.fetch_and_add new_hits 1) in
    Log.add_sink old_sink;
    let ready = Atomic.make 0 in
    let go = Atomic.make false in
    let clear_domain =
      Domain.spawn (fun () ->
        ignore (Atomic.fetch_and_add ready 1);
        wait_until (fun () -> Atomic.get go);
        Log.clear_sinks ())
    in
    let add_domain =
      Domain.spawn (fun () ->
        ignore (Atomic.fetch_and_add ready 1);
        wait_until (fun () -> Atomic.get go);
        Log.add_sink new_sink)
    in
    wait_until (fun () -> Atomic.get ready = 2);
    Atomic.set go true;
    Domain.join clear_domain;
    Domain.join add_domain;
    Log.info log "clear-vs-add" [ Log.I ("round", round) ];
    Alcotest.(check int)
      (Printf.sprintf "round %d old sink should stay cleared" round)
      0
      (Atomic.get old_hits);
    Alcotest.(check bool)
      (Printf.sprintf "round %d new sink is either kept or cleared" round)
      true
      (let hits = Atomic.get new_hits in
       hits = 0 || hits = 1)
  done
;;

let test_with_trace_context () =
  setup ();
  let sink, get = Log.collector_sink () in
  Log.add_sink sink;
  let traced = Log.with_trace_id log ~trace_id:"t1" in
  let traced = Log.with_span_id traced ~span_id:"s1" in
  Log.info traced "traced" [];
  let records = get () in
  let r = List.hd records in
  Alcotest.(check (option string)) "trace_id" (Some "t1") r.trace_id;
  Alcotest.(check (option string)) "span_id" (Some "s1") r.span_id
;;

let test_empty_fields () =
  setup ();
  let sink, get = Log.collector_sink () in
  Log.add_sink sink;
  Log.info log "bare" [];
  let records = get () in
  let r = List.hd records in
  Alcotest.(check int) "no fields" 0 (List.length r.fields)
;;

let test_all_levels () =
  setup ();
  let sink, get = Log.collector_sink () in
  Log.add_sink sink;
  Log.debug log "d" [];
  Log.info log "i" [];
  Log.warn log "w" [];
  Log.error log "e" [];
  let records = get () in
  Alcotest.(check int) "four records" 4 (List.length records);
  let messages = List.map (fun (r : Log.record) -> r.message) records in
  Alcotest.(check (list string)) "order" [ "d"; "i"; "w"; "e" ] messages
;;

(* ── Additional coverage tests ─────────────────────────────── *)

let test_level_of_yojson_non_string () =
  match Log.level_of_yojson (`Int 42) with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error for non-string"
;;

let test_pp_level () =
  let buf = Buffer.create 16 in
  let fmt = Format.formatter_of_buffer buf in
  Log.pp_level fmt Log.Debug;
  Format.pp_print_flush fmt ();
  Alcotest.(check string) "debug" "debug" (Buffer.contents buf)
;;

let test_show_level () =
  Alcotest.(check string) "info" "info" (Log.show_level Log.Info);
  Alcotest.(check string) "warn" "warn" (Log.show_level Log.Warn)
;;

let test_stderr_sink () =
  setup ();
  let sink = Log.stderr_sink () in
  let record : Log.record =
    { ts = 1000000000.0
    ; level = Log.Warn
    ; module_name = "test"
    ; message = "test stderr"
    ; fields = [ Log.S ("key", "val"); Log.I ("n", 42) ]
    ; trace_id = None
    ; span_id = None
    }
  in
  (* Should not raise *)
  sink record
;;

let test_dropped_without_sink_count () =
  setup ();
  Alcotest.(check int) "initial count" 0 (Log.dropped_without_sink_count ());
  Log.warn log "no sink" [];
  Log.error log "still no sink" [];
  Alcotest.(check int) "records without sink" 2 (Log.dropped_without_sink_count ());
  let sink, get = Log.collector_sink () in
  Log.add_sink sink;
  Log.error log "with sink" [];
  Alcotest.(check int) "count unchanged after sink" 2 (Log.dropped_without_sink_count ());
  Alcotest.(check int) "sink receives record" 1 (List.length (get ()));
  Log.clear_sinks ();
  Alcotest.(check int) "clear resets count" 0 (Log.dropped_without_sink_count ())
;;

let test_dropped_without_sink_ignores_below_level () =
  setup ();
  (* Records filtered out by the global level threshold are not "enabled"
     and must NOT bump the dropped-without-sink counter, even when no sink
     is attached. *)
  Log.set_global_level Log.Error;
  Log.debug log "below threshold" [];
  Log.info log "below threshold" [];
  Log.warn log "below threshold" [];
  Alcotest.(check int)
    "below-level records do not increment counter"
    0
    (Log.dropped_without_sink_count ());
  Log.error log "above threshold no sink" [];
  Alcotest.(check int)
    "enabled record without sink increments counter"
    1
    (Log.dropped_without_sink_count ())
;;

let test_emit_below_level () =
  setup ();
  Log.set_global_level Log.Error;
  let sink, get = Log.collector_sink () in
  Log.add_sink sink;
  Log.debug log "should be skipped" [];
  Log.info log "also skipped" [];
  Log.warn log "also skipped" [];
  let records = get () in
  Alcotest.(check int) "0 below error" 0 (List.length records);
  setup () (* Reset for other tests *)
;;

let test_record_to_json_with_all_field_types () =
  let record : Log.record =
    { ts = 1.0
    ; level = Log.Info
    ; module_name = "m"
    ; message = "msg"
    ; fields =
        [ Log.S ("s", "str")
        ; Log.I ("i", 10)
        ; Log.F ("f", 1.5)
        ; Log.B ("b", true)
        ; Log.J ("j", `Assoc [ "x", `Int 1 ])
        ]
    ; trace_id = Some "trace-123"
    ; span_id = Some "span-456"
    }
  in
  let json = Log.record_to_json record in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "trace_id" "trace-123" (json |> member "trace_id" |> to_string);
  Alcotest.(check string) "span_id" "span-456" (json |> member "span_id" |> to_string);
  Alcotest.(check string) "s field" "str" (json |> member "s" |> to_string);
  Alcotest.(check int) "i field" 10 (json |> member "i" |> to_int)
;;

(* ── Runner ───────────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "Log"
    [ ( "level"
      , [ Alcotest.test_case "roundtrip" `Quick test_level_roundtrip
        ; Alcotest.test_case "yojson roundtrip" `Quick test_level_yojson_roundtrip
        ; Alcotest.test_case "error on invalid" `Quick test_level_of_string_error
        ; Alcotest.test_case "of_yojson non-string" `Quick test_level_of_yojson_non_string
        ; Alcotest.test_case "pp_level" `Quick test_pp_level
        ; Alcotest.test_case "show_level" `Quick test_show_level
        ] )
    ; ( "sink"
      , [ Alcotest.test_case "collector" `Quick test_collector_sink
        ; Alcotest.test_case "level filtering" `Quick test_level_filtering
        ; Alcotest.test_case "multiple sinks" `Quick test_multiple_sinks
        ; Alcotest.test_case
            "concurrent add_sink keeps all registrations"
            `Quick
            test_concurrent_add_sink_keeps_all_registrations
        ; Alcotest.test_case
            "clear_sinks racing add_sink removes stale sinks"
            `Quick
            test_clear_sinks_racing_add_sink_removes_stale_sinks
        ; Alcotest.test_case "stderr sink" `Quick test_stderr_sink
        ; Alcotest.test_case
            "dropped without sink count"
            `Quick
            test_dropped_without_sink_count
        ; Alcotest.test_case
            "dropped without sink ignores below-level records"
            `Quick
            test_dropped_without_sink_ignores_below_level
        ] )
    ; ( "field"
      , [ Alcotest.test_case "to_json" `Quick test_field_to_json
        ; Alcotest.test_case
            "explicit env secret is redacted"
            `Quick
            test_explicit_env_secret_field_is_redacted
        ] )
    ; ( "record"
      , [ Alcotest.test_case "to_json" `Quick test_record_to_json
        ; Alcotest.test_case "empty fields" `Quick test_empty_fields
        ; Alcotest.test_case
            "all field types"
            `Quick
            test_record_to_json_with_all_field_types
        ] )
    ; "context", [ Alcotest.test_case "trace/span" `Quick test_with_trace_context ]
    ; ( "integration"
      , [ Alcotest.test_case "all levels" `Quick test_all_levels
        ; Alcotest.test_case "emit below level" `Quick test_emit_below_level
        ] )
    ]
;;
