(** Semantic contracts for the opt-in observer. These are not performance
    admission tests: durations and allocation amounts have no thresholds. *)

module Observation = Agent_core.Base.Schema_observation
module Types = Agent_core.Types

exception Product_failure of int ref

let check_bool label expected actual = Alcotest.(check bool) label expected actual
let check_int label expected actual = Alcotest.(check int) label expected actual

let schema () =
  Types.tool_schema_of_params
    ~name:"schema-observation-fixture"
    ~description:"A real SDK schema with UTF-8: 관측"
    ~parameters:[]
    ()
;;

let field name = function
  | `Assoc fields ->
    (match List.assoc_opt name fields with
     | Some value -> value
     | None -> Alcotest.failf "missing field %s" name)
  | _ -> Alcotest.failf "expected object for field %s" name
;;

let update name transform = function
  | `Assoc fields when List.mem_assoc name fields ->
    `Assoc (List.map (fun (key, value) ->
      key, if key = name then transform value else value) fields)
  | _ -> Alcotest.failf "cannot update field %s" name
;;

let json_list = function
  | `List values -> values
  | _ -> Alcotest.fail "expected JSON list"
;;

let report_json owner = Observation.report_to_json (Observation.snapshot owner)
let events report = json_list (field "events" report)
let payload event = field "payload" event
let kind event = field "kind" (payload event)

let expect_valid label report =
  match Observation.report_of_json report with
  | Ok _ -> ()
  | Error error -> Alcotest.failf "%s: %s" label error
;;

let expect_invalid label report =
  match Observation.report_of_json report with
  | Error _ -> ()
  | Ok _ -> Alcotest.failf "%s: contradictory report accepted" label
;;

let first_payload kind_name transform report =
  let rec change = function
    | [] -> Alcotest.failf "no %s event" kind_name
    | event :: rest when kind event = `String kind_name ->
      update "payload" transform event :: rest
    | event :: rest -> event :: change rest
  in
  update "events" (fun values -> `List (change (json_list values))) report
;;

let check_exception expected operation =
  match operation () with
  | _ -> Alcotest.fail "product exception was swallowed"
  | exception actual ->
    check_bool "original exception object" true (actual == expected)
;;

let check_passthrough () =
  let key = schema () in
  check_bool "observer is unbound" false (Observation.enabled ());
  check_bool "unbound identity allocation" true
    (Observation.fresh_object_id () = None && Observation.schema key = None);
  let surface_calls = ref 0 in
  Observation.surface ~site:Built_surface (fun () -> incr surface_calls; [key]);
  check_int "unbound surface thunk is skipped" 0 !surface_calls;
  let observer_calls = ref 0 in
  ignore (Observation.observer_work (fun () -> incr observer_calls; Some 3));
  check_int "unbound diagnostic thunk is skipped" 0 !observer_calls;
  let calls = ref 0 in
  let original = Ok (ref 17) in
  let result = Observation.measure ~site:Phase0_bytes ~schema:key (fun () ->
    incr calls; original) in
  check_bool "original result object" true (result == original);
  check_int "measurement operation once" 1 !calls;
  let bytes = Bytes.to_string (Bytes.of_string "UTF-8 관측") in
  let encode_calls = ref 0 in
  let encoded = Observation.encode ~site:Reserve_encode ~schema:key (fun () ->
    incr encode_calls; bytes) in
  check_bool "original encoded string" true (encoded == bytes);
  check_int "encoder operation once" 1 !encode_calls;
  let constructor_calls = ref 0 in
  let original_error = Error (ref "product error") in
  let error = Observation.constructor ~site:Bridge_plain_constructor (fun () ->
    incr constructor_calls; original_error) in
  check_bool "original constructor error object" true (error == original_error);
  check_int "constructor operation once" 1 !constructor_calls;
  List.iter (fun expected ->
    let raised_calls = ref 0 in
    check_exception expected (fun () ->
      Observation.measure ~site:Phase0_bytes (fun () ->
        incr raised_calls; raise expected));
    check_int "raising operation once" 1 !raised_calls)
    [Product_failure (ref 9); Eio.Cancel.Cancelled Exit];
  let json = Agent_core.Tool.wire_json_of_schema key in
  check_int "raw SDK byte-count call retains behavior"
    (String.length (Yojson.Safe.to_string json))
    (Agent_core.Tool.wire_bytes_of_schema key)
;;

let test_raw_non_eio () = check_passthrough ()

let test_disabled_and_binding_restoration () =
  let disabled = Observation.create ~mode:Disabled in
  Observation.within disabled check_passthrough;
  Eio_main.run (fun _ ->
    let active = Observation.create ~mode:Identity_only in
    Observation.within active (fun () ->
      check_bool "outer observer enabled" true (Observation.enabled ());
      Observation.within disabled check_passthrough;
      check_bool "outer binding restored" true (Observation.enabled ());
      ignore (Observation.measure ~site:Phase0_bytes (fun () -> 7)));
    check_int "outer observer receives only restored work" 2
      (List.length (events (report_json active))));
  let report = report_json disabled in
  check_int "disabled event count" 0 (List.length (events report));
  check_bool "disabled has no probes" true (field "probe_calls" report = `Int 0);
  check_bool "disabled has no bookkeeping" true
    (field "calls" (field "bookkeeping" report) = `Int 0);
  expect_valid "disabled report" report
;;

let identity key =
  match Observation.schema key with
  | Some id -> Observation.object_id_to_string id
  | None -> Alcotest.fail "active observer did not identify schema"
;;

let test_physical_identity_and_inventory () =
  Eio_main.run (fun _ ->
    let owner = Observation.create ~mode:Identity_only in
    let first = schema () and equal_content = schema () in
    check_bool "fixture values are structurally equal" true (first = equal_content);
    check_bool "fixture records are distinct" false (first == equal_content);
    let first_id, second_id = Observation.within owner (fun () ->
      let first_id = identity first in
      Alcotest.(check string) "same physical schema has same ID" first_id (identity first);
      let second_id = identity equal_content in
      check_bool "equal content does not merge physical identity" false (first_id = second_id);
      Observation.surface ~site:Built_surface (fun () -> [first; equal_content; first]);
      first_id, second_id)
    in
    let report = report_json owner in
    let inventory = match events report with
      | [event] when kind event = `String "surface" -> field "schema_ids" (payload event)
      | _ -> Alcotest.fail "expected one surface event" in
    check_bool "inventory preserves order and duplicate occurrence" true
      (inventory = `List [`String first_id; `String second_id; `String first_id]);
    check_bool "identity-only does not probe clocks or allocations" true
      (field "probe_calls" report = `Int 0 && field "clock_origin_ns" report = `Null);
    expect_valid "identity report" report)
;;

let test_active_result_and_exception () =
  Eio_main.run (fun _ ->
    List.iter (fun mode ->
      let owner = Observation.create ~mode in
      let key = schema () in
      Observation.within owner (fun () ->
        let calls = ref 0 in
        let original = Ok (ref 19) in
        let result = Observation.measure ~site:Phase0_bytes (fun () -> incr calls; original) in
        check_bool "active original result object" true (result == original);
        check_int "active operation once" 1 !calls;
        let bytes = Bytes.to_string (Bytes.of_string "encoder bytes 관측") in
        let encoded = Observation.encode ~site:Reserve_encode ~schema:key (fun () -> bytes) in
        check_bool "active original string" true (encoded == bytes);
        let constructed = Ok key in
        let calls = ref 0 in
        let result = Observation.constructor ~site:Bridge_plain_constructor (fun () ->
          incr calls; constructed) in
        check_bool "active original constructor result" true (result == constructed);
        check_int "active successful constructor once" 1 !calls;
        let rejected = Error (ref "schema rejection") in
        let calls = ref 0 in
        let result = Observation.constructor ~site:Bridge_plain_constructor (fun () ->
          incr calls; rejected) in
        check_bool "active original constructor error" true (result == rejected);
        check_int "active rejected constructor once" 1 !calls;
        List.iter (fun error ->
          let calls = ref 0 in
          check_exception error (fun () ->
            Observation.measure ~site:Phase0_bytes (fun () -> incr calls; raise error));
          check_int "active raising operation once" 1 !calls)
          [Product_failure (ref 23); Eio.Cancel.Cancelled Exit]);
      let report = report_json owner in
      let completions = List.filter_map (fun event ->
        if kind event = `String "span_finished"
        then Some (field "completion" (payload event)) else None) (events report) in
      check_bool "raise and cancellation recorded separately" true
        (completions = [`String "returned"; `String "returned"; `String "returned"
          ; `String "returned_error"; `String "raised"; `String "cancelled"]);
      expect_valid "active complete report" report)
      [Observation.Identity_only; Observation.Timed])
;;

let test_observer_failure_isolation () =
  Eio_main.run (fun _ ->
    let owner = Observation.create ~mode:Identity_only in
    Observation.within owner (fun () ->
      let attempts = ref 0 in
      let result = Observation.observer_work (fun () ->
        incr attempts; raise (Product_failure (ref 31))) in
      check_bool "ordinary diagnostic failure is isolated" true (result = None);
      check_int "diagnostic failure is not retried" 1 !attempts;
      let product_calls = ref 0 in
      ignore (Observation.measure ~site:Phase0_bytes (fun () -> incr product_calls));
      check_int "subsequent product operation runs once" 1 !product_calls;
      let cancellation = Eio.Cancel.Cancelled Exit in
      check_exception cancellation (fun () ->
        Observation.observer_work (fun () -> raise cancellation)));
    let report = report_json owner in
    check_bool "ordinary diagnostic failure is counted" true (field "failures" report = `Int 1);
    check_bool "failure leaves coverage incomplete" true
      (field "coverage" report = `String "incomplete");
    expect_valid "incomplete diagnostic report" report)
;;

let test_capture_across_domain () =
  Eio_main.run (fun env ->
    let owner = Observation.create ~mode:Timed in
    let caller_domain = (Domain.self () :> int) in
    Observation.within owner (fun () ->
      Observation.with_wake ~keeper:"fixture" ~trace_id:"original-wake"
        ~absolute_turn:42 ~execution_scope:(Some "owned-test") ~cause:(Some "test") (fun () ->
        Observation.with_attempt ~routing_run_id:"fixture-run" ~lane_attempt_index:0
          ~runtime_id:"fixture-runtime" (fun () ->
          Observation.with_provider_turn ~ordinal:2 (fun () ->
            let expected_scope = Option.map Observation.scope_to_json (Observation.current_scope ()) in
            let work = Observation.capture (fun () ->
              Observation.measure ~site:Worker_work (fun () ->
                (Domain.self () :> int),
                Option.map Observation.scope_to_json (Observation.current_scope ()))) in
            let worker_domain, actual_scope =
              Observation.measure ~site:Worker_queue_and_await (fun () ->
                Eio.Domain_manager.run (Eio.Stdenv.domain_mgr env) work) in
            check_bool "work ran in another actual Eio domain" false (worker_domain = caller_domain);
            check_bool "captured scalar scope survives domain handoff" true (actual_scope = expected_scope);
            check_bool "caller scope remains bound" true
              (Option.map Observation.scope_to_json (Observation.current_scope ()) = expected_scope);
            let report = report_json owner in
            let worker_finish = List.find_opt (fun event ->
              kind event = `String "span_finished"
              && field "site" (payload event) = `String "worker_work") (events report) in
            (match worker_finish with
             | None -> Alcotest.fail "worker observation was not recorded"
             | Some event ->
               check_bool "worker event carries original scope" true
                 (Some (field "scope" event) = expected_scope);
               let timing = field "measurement" (payload event) in
               check_bool "allocation interval names worker domain" true
                 (field "entry_domain" timing = `Int worker_domain
                  && field "exit_domain" timing = `Int worker_domain));
            expect_valid "cross-domain report" report)))))
;;

let test_captured_scope_survives_yield_and_sibling () =
  Eio_main.run (fun env ->
    let owner = Observation.create ~mode:Timed in
    let sibling_owner = Observation.create ~mode:Timed in
    let original = ref 71 and sibling_original = ref 73 in
    Observation.within owner (fun () ->
      Observation.with_wake ~keeper:"captured" ~trace_id:"captured-wake"
        ~absolute_turn:4 ~execution_scope:None ~cause:None (fun () ->
        let expected = Option.map Observation.scope_to_json (Observation.current_scope ()) in
        let work = Observation.capture (fun () ->
          (* These Eio resources belong to the worker, not to the caller domain. *)
          Eio.Switch.run (fun sw ->
            let ready, ready_u = Eio.Promise.create () in
            let release, release_u = Eio.Promise.create () in
            let sibling = Eio.Fiber.fork_promise ~sw (fun () ->
              Observation.within sibling_owner (fun () ->
                Observation.with_wake ~keeper:"sibling" ~trace_id:"sibling-wake"
                  ~absolute_turn:9 ~execution_scope:None ~cause:None (fun () ->
                  let sibling_scope = Option.map Observation.scope_to_json (Observation.current_scope ()) in
                  Eio.Promise.resolve ready_u sibling_scope;
                  Observation.measure ~site:Phase0_bytes (fun () ->
                    Eio.Promise.await release;
                    Eio.Fiber.yield ();
                    check_bool "sibling keeps its own binding after yielding" true
                      (Option.map Observation.scope_to_json (Observation.current_scope ()) = sibling_scope);
                    sibling_original)))) in
            let sibling_scope = Eio.Promise.await ready in
            check_bool "a suspended sibling does not replace the captured binding" true
              (Option.map Observation.scope_to_json (Observation.current_scope ()) = expected);
            let result = Observation.measure ~site:Worker_work (fun () ->
              Eio.Promise.resolve release_u ();
              Eio.Fiber.yield ();
              check_bool "captured work keeps its binding after yielding" true
                (Option.map Observation.scope_to_json (Observation.current_scope ()) = expected);
              original) in
            check_bool "sibling returns its original result" true
              (Eio.Promise.await_exn sibling == sibling_original);
            result, sibling_scope)) in
        let result, sibling_scope = Observation.measure ~site:Worker_queue_and_await (fun () ->
          Eio.Domain_manager.run (Eio.Stdenv.domain_mgr env) work) in
        check_bool "captured work returns its original result" true (result == original);
        check_bool "the sibling scope is distinct" false (sibling_scope = expected);
        check_bool "caller binding is restored after worker settlement" true
          (Option.map Observation.scope_to_json (Observation.current_scope ()) = expected);
        List.iter (fun (label, observed_owner, scope, finished) ->
          let report = report_json observed_owner in
          check_int (label ^ " has no open spans") 0
            Yojson.Safe.Util.(field "active_spans" report |> to_int);
          check_bool (label ^ " retains only its original scope") true
            (List.for_all (fun event -> Some (field "scope" event) = scope) (events report));
          check_int (label ^ " measured operations finish") finished
            (List.length (List.filter (fun event -> kind event = `String "span_finished") (events report)));
          expect_valid (label ^ " yielded report") report)
          ["captured", owner, expected, 2; "sibling", sibling_owner, sibling_scope, 1]));
    check_bool "worker bindings do not escape the owning scope" true
      (Observation.current_scope () = None))
;;

let test_cancelled_yielded_capture_closes_spans () =
  Eio_main.run (fun env ->
    let owner = Observation.create ~mode:Timed in
    let cleaned = Atomic.make false in
    Observation.within owner (fun () ->
      Observation.with_wake ~keeper:"cancelled" ~trace_id:"cancelled-wake"
        ~absolute_turn:5 ~execution_scope:None ~cause:None (fun () ->
        let expected = Option.map Observation.scope_to_json (Observation.current_scope ()) in
        let work = Observation.capture (fun () ->
          Eio.Cancel.sub (fun cancel ->
            Eio.Switch.run (fun sw ->
              let ready, ready_u = Eio.Promise.create () in
              let cancelled_wait, _ = Eio.Promise.create () in
              Eio.Fiber.fork ~sw (fun () ->
                Eio.Promise.await ready;
                Eio.Cancel.cancel cancel Exit);
              Observation.measure ~site:Worker_work (fun () ->
                Fun.protect ~finally:(fun () -> Atomic.set cleaned true) (fun () ->
                  Eio.Promise.resolve ready_u ();
                  Eio.Fiber.yield ();
                  Eio.Promise.await cancelled_wait))))) in
        (match Observation.measure ~site:Worker_queue_and_await (fun () ->
           Eio.Domain_manager.run (Eio.Stdenv.domain_mgr env) work) with
         | () -> Alcotest.fail "worker cancellation was swallowed"
         | exception Eio.Cancel.Cancelled Exit -> ());
        check_bool "worker cleanup settled before cancellation returned" true (Atomic.get cleaned);
        check_bool "cancellation restores caller scope" true
          (Option.map Observation.scope_to_json (Observation.current_scope ()) = expected)));
    check_bool "cancelled capture leaves no binding behind" true
      (Observation.current_scope () = None);
    let report = report_json owner in
    let completions = List.filter_map (fun event ->
      if kind event = `String "span_finished" then Some (field "completion" (payload event))
      else None) (events report) in
    check_bool "worker and caller wait both retain cancellation" true
      (completions = [`String "cancelled"; `String "cancelled"]);
    check_int "cancelled spans are closed" 0 Yojson.Safe.Util.(field "active_spans" report |> to_int);
    expect_valid "cancelled yielded capture report" report)
;;

let[@inline never] observe_ephemeral owner =
  let key = schema () in
  let weak = Weak.create 1 in
  Weak.set weak 0 (Some key);
  let report = Observation.within owner (fun () ->
    Observation.surface ~site:Built_surface (fun () -> [key]);
    Observation.snapshot owner) in
  weak, report
;;

let test_report_does_not_retain_schema () =
  Eio_main.run (fun _ ->
    let owner = Observation.create ~mode:Identity_only in
    let weak, retained_report = observe_ephemeral owner in
    (* Two full collections allow an ephemeron key to clear. The owner and its
       report are deliberately used afterward, so neither may disappear early. *)
    Gc.full_major ();
    Gc.full_major ();
    check_bool "schema is collectible while observer and report remain" false (Weak.check weak 0);
    let original = Observation.report_to_json retained_report in
    check_int "retained report still contains inventory" 1 (List.length (events original));
    expect_valid "retained scalar report" original;
    check_int "live observer still contains inventory" 1 (List.length (events (report_json owner))))
;;

let complete_timed_report () =
  Eio_main.run (fun _ ->
    let owner = Observation.create ~mode:Timed in
    let key = schema () in
    Observation.within owner (fun () ->
      Observation.with_wake ~keeper:"codec-fixture" ~trace_id:"codec-wake"
        ~absolute_turn:1 ~execution_scope:None ~cause:None (fun () ->
        Observation.with_provider_turn ~ordinal:0 (fun () ->
          ignore (Observation.encode ~site:Reserve_encode ~schema:key (fun () -> "bytes"));
          Observation.surface ~site:Built_surface (fun () -> [key]);
          Observation.cache ~schema:key (Json_lookup Existing_json))));
    report_json owner)
;;

let test_strict_decoder () =
  let report = complete_timed_report () in
  expect_valid "original timed report" report;
  let malformed =
    [ "duplicate field", (match report with
        | `Assoc fields -> `Assoc (("schema_version", `Int 1) :: fields)
        | _ -> Alcotest.fail "expected report object")
    ; "unknown field", (match report with
        | `Assoc fields -> `Assoc (("invented", `Bool true) :: fields)
        | _ -> Alcotest.fail "expected report object")
    ; "nonfinite allocation", update "bookkeeping"
        (update "calling_domain_allocated_bytes" (fun _ -> `Float Float.nan)) report
    ; "event order", update "events" (fun values -> match json_list values with
        | first :: rest -> `List (update "sequence" (fun _ -> `Int 2) first :: rest)
        | [] -> Alcotest.fail "expected original events") report
    ; "wrong observer", update "events" (fun values -> match json_list values with
        | first :: rest -> `List (update "scope"
            (update "observer_id" (fun _ -> `String "9223372036854775807")) first :: rest)
        | [] -> Alcotest.fail "expected original events") report
    ; "finished operation changed", first_payload "span_finished"
        (update "operation" (fun _ -> `String "measured")) report
    ; "finished scope changed", update "events" (fun values ->
        `List (List.map (fun event ->
          if kind event = `String "span_finished" then
            update "scope" (update "wake" (update "trace_id" (fun _ -> `String "different-wake"))) event
          else event) (json_list values))) report
    ; "reused wake identity contradicts original", update "events" (fun values ->
        `List (List.map (fun event ->
          if kind event = `String "surface" then
            update "scope" (update "wake" (update "trace_id" (fun _ -> `String "other-original"))) event
          else event) (json_list values))) report
    ; "reused provider candidate contradicts ordinal", update "events" (fun values ->
        `List (List.map (fun event ->
          if kind event = `String "surface" then
            update "scope" (update "provider_turn" (update "ordinal" (fun _ -> `Int 17))) event
          else event) (json_list values))) report
    ; "complete timed span lacks timing", first_payload "span_finished"
        (update "measurement" (fun _ -> `Null)) report
    ; "complete encoder lacks schema identity", first_payload "span_started"
        (update "schema_id" (fun _ -> `Null))
        (first_payload "span_finished" (update "schema_id" (fun _ -> `Null)) report)
    ; "complete inventory lacks schema identity", first_payload "surface"
        (update "schema_ids" (fun _ -> `List [`Null])) report
    ; "complete cache lacks schema identity", first_payload "cache"
        (update "schema_id" (fun _ -> `Null)) report
    ; "negative encoded byte count", first_payload "span_finished"
        (update "byte_count" (fun _ -> `Int (-1))) report
    ] in
  List.iter (fun (label, report) -> expect_invalid label report) malformed;
  let first_finish = List.find (fun event -> kind event = `String "span_finished") (events report) in
  let started_ns = field "started_ns" (field "measurement" (payload first_finish)) in
  let future_origin = match started_ns with
    | `String value -> `String (Int64.to_string (Int64.succ (Int64.of_string value)))
    | _ -> Alcotest.fail "expected canonical monotonic timestamp" in
  expect_invalid "span predates original observer"
    (update "clock_origin_ns" (fun _ -> future_origin) report);
  let measured = Eio_main.run (fun _ ->
    let owner = Observation.create ~mode:Identity_only in
    Observation.within owner (fun () ->
      ignore (Observation.measure ~site:Worker_work (fun () -> 1)));
    report_json owner) in
  expect_valid "original measured operation without schema" measured;
  expect_invalid "measured completion invents schema identity"
    (first_payload "span_finished"
       (update "schema_id" (fun _ -> `String "9223372036854775807")) measured);
  let disabled = report_json (Observation.create ~mode:Disabled) in
  expect_invalid "disabled claims bookkeeping"
    (update "bookkeeping" (update "calls" (fun _ -> `Int 1)) disabled)
;;

let decoded_report json =
  match Observation.report_of_json json with
  | Ok report -> report
  | Error detail -> Alcotest.fail detail
;;

let check_streamed_report report =
  let output = Buffer.create 256 in
  Observation.write_report_json ~write:(Buffer.add_string output) report;
  let bytes = Buffer.contents output in
  check_bool "stream ends with LF" true
    (String.length bytes > 0 && bytes.[String.length bytes - 1] = '\n');
  let expected = Observation.report_to_json report in
  let actual = Yojson.Safe.from_string bytes in
  check_bool "stream preserves exact fields, values and ordered arrays" true (actual = expected);
  check_bool "stream is a strict v1 codec roundtrip" true
    (Observation.report_to_json (decoded_report actual) = expected)
;;

let streaming_fixture mode =
  Eio_main.run (fun _ ->
    let owner = Observation.create ~mode in
    let key = schema () and other = schema () in
    let work () =
      ignore (Observation.measure ~site:Worker_work (fun () -> 1));
      ignore (Observation.measure ~site:Final_attribution_bytes ~schema:key (fun () -> 2));
      ignore (Observation.constructor ~site:Bridge_execution_env_constructor (fun () -> Ok key));
      ignore (Observation.constructor ~site:Bridge_plain_constructor (fun () -> Error "rejected"));
      ignore (Observation.encode ~site:Reserve_encode ~schema:key (fun () -> "UTF-8 관측\n\""));
      List.iter (fun expected -> check_exception expected (fun () ->
        Observation.measure ~site:Worker_work (fun () -> raise expected)))
        [Product_failure (ref 73); Eio.Cancel.Cancelled Exit];
      Observation.surface ~site:Request_surface (fun () -> [other; key; other]);
      List.iter (Observation.cache ~schema:key)
        [ Json_lookup Created_json; Json_lookup Existing_json
        ; Byte_lookup {json = Created_json; count = Missing_byte_count}
        ; Byte_lookup {json = Existing_json; count = Missing_byte_count}
        ; Byte_lookup {json = Existing_json; count = Existing_byte_count}
        ; Byte_publication Published_byte_count
        ; Byte_publication Concurrent_byte_count_won ]
    in
    Observation.within owner (fun () ->
      Observation.with_wake ~keeper:"stream \"관측\"" ~trace_id:"stream\ntrace"
        ~absolute_turn:3 ~execution_scope:(Some "owned scope") ~cause:(Some "explicit fixture") (fun () ->
        Observation.with_attempt ~routing_run_id:"stream-run" ~lane_attempt_index:1
          ~runtime_id:"stream-runtime" (fun () ->
          Observation.with_provider_turn ~ordinal:2 (fun () ->
            match Observation.fresh_object_id (), Observation.fresh_object_id () with
            | Some descriptor_id, Some addon_owner_id ->
              Observation.with_definition ~descriptor_id ~addon_owner_id:(Some addon_owner_id)
                (fun () -> Observation.with_site Phase0_bytes work)
            | None, None -> work ()
            | Some _, None | None, Some _ -> Alcotest.fail "partial fixture identities"))));
    Observation.snapshot owner)
;;

let test_streaming_modes_and_events () =
  List.iter (fun mode ->
    let report = streaming_fixture mode in
    check_streamed_report report;
    let kinds = List.map kind (events (Observation.report_to_json report))
      |> List.sort_uniq Stdlib.compare in
    let expected = match mode with
      | Observation.Disabled -> []
      | Identity_only | Timed ->
        [`String "cache"; `String "span_finished"; `String "span_started"; `String "surface"] in
    check_bool "all applicable event kinds were exercised" true (kinds = expected))
    [Observation.Disabled; Identity_only; Timed]
;;

let test_streaming_incomplete_and_unsigned_clocks () =
  let incomplete = Eio_main.run (fun _ ->
    let owner = Observation.create ~mode:Timed in
    Observation.within owner (fun () ->
      ignore (Observation.observer_work (fun () -> raise (Product_failure (ref 79))));
      Observation.surface ~site:Built_surface (fun () -> []));
    Observation.snapshot owner) in
  check_streamed_report incomplete;
  let open_span = Eio_main.run (fun _ ->
    let owner = Observation.create ~mode:Timed in
    Observation.within owner (fun () ->
      Observation.measure ~site:Worker_work (fun () -> Observation.snapshot owner))) in
  check_bool "fixture retains a genuinely open span snapshot" true
    (field "active_spans" (Observation.report_to_json open_span) = `Int 1);
  check_streamed_report open_span;
  let original = complete_timed_report () in
  let origin = match field "clock_origin_ns" original with
    | `String ns -> Int64.of_string ns
    | _ -> Alcotest.fail "timed report has no origin" in
  let unsigned_ns = function
    | `String ns -> `String (Int64.to_string
        (Int64.add Int64.min_int (Int64.sub (Int64.of_string ns) origin)))
    | _ -> Alcotest.fail "clock is not an int64 string" in
  let unsigned_measurement timing = timing
    |> update "started_ns" unsigned_ns
    |> update "finished_ns" unsigned_ns in
  let unsigned = original
    |> update "clock_origin_ns" unsigned_ns
    |> update "events" (fun values -> `List (List.map (fun event ->
      if kind event = `String "span_finished" then
        update "payload" (update "measurement" unsigned_measurement) event
      else event) (json_list values))) in
  check_streamed_report (decoded_report unsigned)
;;

let test_streaming_writer_failures () =
  let report = decoded_report (complete_timed_report ()) in
  List.iter (fun expected ->
    let calls = ref 0 in
    check_exception expected (fun () ->
      Observation.write_report_json report ~write:(fun _ ->
        incr calls;
        if !calls = 2 then raise expected));
    check_int "failed output callback is never retried" 2 !calls)
    [Product_failure (ref 83); Eio.Cancel.Cancelled Exit]
;;

let test_streaming_caller_owned_channel () =
  let path = Filename.temp_file "schema-observation-stream-" ".json" in
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () ->
    let report = decoded_report (complete_timed_report ()) in
    Out_channel.with_open_bin path (fun channel ->
      Observation.write_report_json ~write:(output_string channel) report;
      output_char channel ' ');
    let actual = In_channel.with_open_bin path In_channel.input_all
      |> Yojson.Safe.from_string in
    check_bool "caller can keep writing and owns channel close" true
      (actual = Observation.report_to_json report);
    let closed = open_out_bin path in
    close_out closed;
    match Observation.write_report_json ~write:(output_string closed) report with
    | () -> Alcotest.fail "closed-channel output error was swallowed"
    | exception Sys_error _ -> ())
;;

let () =
  Alcotest.run "Schema observation"
    [ "passthrough",
      [ Alcotest.test_case "raw non-Eio calls" `Quick test_raw_non_eio
      ; Alcotest.test_case "disabled and restored binding" `Quick test_disabled_and_binding_restoration
      ; Alcotest.test_case "active results and exceptions" `Quick test_active_result_and_exception
      ; Alcotest.test_case "diagnostic failure isolation" `Quick test_observer_failure_isolation ]
    ; "identity and lifetime",
      [ Alcotest.test_case "physical identity and ordered inventory" `Quick test_physical_identity_and_inventory
      ; Alcotest.test_case "capture across actual Eio domain" `Quick test_capture_across_domain
      ; Alcotest.test_case "yielding capture restores sibling fiber scopes" `Quick test_captured_scope_survives_yield_and_sibling
      ; Alcotest.test_case "cancelled yielded capture closes spans" `Quick test_cancelled_yielded_capture_closes_spans
      ; Alcotest.test_case "report does not retain schemas" `Quick test_report_does_not_retain_schema ]
    ; "codec", [Alcotest.test_case "contradictory evidence rejected" `Quick test_strict_decoder]
    ; "streaming",
      [ Alcotest.test_case "all modes and event kinds preserve v1 values" `Quick test_streaming_modes_and_events
      ; Alcotest.test_case "incomplete snapshots and unsigned clocks" `Quick test_streaming_incomplete_and_unsigned_clocks
      ; Alcotest.test_case "output failure and cancellation propagate" `Quick test_streaming_writer_failures
      ; Alcotest.test_case "channel remains owned by caller" `Quick test_streaming_caller_owned_channel ]
    ]
