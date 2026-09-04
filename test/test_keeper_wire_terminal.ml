(* Wire-terminal synthesis for keeper chat operations (#28811).

   A cancelled turn kills the AG-UI projection fiber inside the child switch
   before it can emit RUN_ERROR, so the SSE stream used to close with no
   terminal receipt. The server tracks per-operation wire audience — open
   from sink registration, dropped when the last sink leaves — and the Owner
   settle hook synthesizes the missing terminal from the execution verdict.
   These tests pin the registry transitions, the synthesis decision table,
   and the production glue the operation_runner wires. *)

open Alcotest
open Masc
module Stream = Server_routes_http_keeper_stream

let custom_event () =
  Ag_ui.of_custom ~name:"TEST_EVENT" (`Assoc [ ("ok", `Bool true) ])

let run_error_event () =
  Ag_ui.run_error ~thread_id:"keeper:test" ~message:"boom" ()

let failed_execution detail =
  Keeper_owner.Operation_failed
    { kind = Keeper_chat_operation.Turn_cancelled
    ; detail
    ; outcome_ref = None
    }

let test_note_marks_started_then_terminal () =
  let operation_id = "op-wire-note" in
  Stream.For_testing.note_operation_wire_event ~operation_id (custom_event ());
  (match Stream.For_testing.take_operation_wire_stream ~operation_id with
   | Some Stream.Wire_started -> ()
   | Some Stream.Wire_terminal_sent -> fail "custom event marked terminal"
   | None -> fail "custom event did not open a wire stream");
  Stream.For_testing.note_operation_wire_event ~operation_id (custom_event ());
  Stream.For_testing.note_operation_wire_event ~operation_id (run_error_event ());
  (match Stream.For_testing.take_operation_wire_stream ~operation_id with
   | Some Stream.Wire_terminal_sent -> ()
   | Some Stream.Wire_started -> fail "terminal event left the stream open"
   | None -> fail "terminal event dropped the stream record");
  check bool "take consumes the record" true
    (Option.is_none (Stream.For_testing.take_operation_wire_stream ~operation_id))

let collect_sink () =
  let events = ref [] in
  let sink ~seq:_ event = events := event :: !events in
  (events, sink)

let test_settle_synthesizes_run_error_for_open_stream () =
  let operation_id = "op-wire-cancelled" in
  let events, sink = collect_sink () in
  let unregister =
    Stream.For_testing.register_operation_live_sink ~operation_id sink
  in
  Fun.protect ~finally:unregister @@ fun () ->
  Stream.For_testing.note_operation_wire_event ~operation_id (custom_event ());
  Stream.For_testing.synthesize_wire_terminal_on_settle
    ~keeper_name:"wire-test"
    ~operation_id
    ~execution:(failed_execution "Keeper owner stopped the active turn");
  (match !events with
   | [ event ] ->
     (match event.Ag_ui.event_type with
      | Ag_ui.Run_error -> ()
      | _ -> fail "synthesized event is not RUN_ERROR");
     let sse = Ag_ui.event_to_sse event in
     check bool "reason travels on the wire" true
       (Astring.String.is_infix
          ~affix:"Keeper owner stopped the active turn" sse);
     check bool "failure kind travels as code" true
       (Astring.String.is_infix ~affix:"Turn_cancelled" sse)
   | events ->
     fail
       (Printf.sprintf "expected exactly one synthesized event, got %d"
          (List.length events)));
  (* Settle consumed the record: a second settle stays silent. *)
  Stream.For_testing.synthesize_wire_terminal_on_settle
    ~keeper_name:"wire-test"
    ~operation_id
    ~execution:(failed_execution "second settle");
  check int "second settle synthesizes nothing" 1 (List.length !events)

let test_settle_is_silent_when_terminal_already_sent () =
  let operation_id = "op-wire-terminal-sent" in
  let events, sink = collect_sink () in
  let unregister =
    Stream.For_testing.register_operation_live_sink ~operation_id sink
  in
  Fun.protect ~finally:unregister @@ fun () ->
  Stream.For_testing.note_operation_wire_event ~operation_id (custom_event ());
  Stream.For_testing.note_operation_wire_event ~operation_id (run_error_event ());
  Stream.For_testing.synthesize_wire_terminal_on_settle
    ~keeper_name:"wire-test"
    ~operation_id
    ~execution:(failed_execution "already terminal");
  check int "no duplicate terminal" 0 (List.length !events)

let test_settle_synthesizes_for_attached_client_with_no_events () =
  (* A turn that fails after claim but before the projection ever runs
     (missing input, payload parse failure) projects no events. The attached
     client still needs a terminal: sink registration alone opens the wire
     stream (#28849 review). *)
  let operation_id = "op-wire-claimed-no-projection" in
  let events, sink = collect_sink () in
  let unregister =
    Stream.For_testing.register_operation_live_sink ~operation_id sink
  in
  Fun.protect ~finally:unregister @@ fun () ->
  Stream.For_testing.synthesize_wire_terminal_on_settle
    ~keeper_name:"wire-test"
    ~operation_id
    ~execution:(failed_execution "operation input missing");
  match !events with
  | [ event ] ->
    (match event.Ag_ui.event_type with
     | Ag_ui.Run_error -> ()
     | _ -> fail "synthesized event is not RUN_ERROR")
  | events ->
    fail
      (Printf.sprintf "expected one synthesized event, got %d"
         (List.length events))

let test_settle_is_silent_without_audience () =
  let operation_id = "op-wire-no-audience" in
  check bool "no record before settle" true
    (Option.is_none (Stream.For_testing.take_operation_wire_stream ~operation_id));
  (* No sink was ever registered (connector channels): settle must not raise
     and must stay silent — durable operation state is the authority. *)
  Stream.For_testing.synthesize_wire_terminal_on_settle
    ~keeper_name:"wire-test"
    ~operation_id
    ~execution:(failed_execution "no audience ever attached");
  check bool "still no record after settle" true
    (Option.is_none (Stream.For_testing.take_operation_wire_stream ~operation_id))

let test_unregistering_last_sink_drops_the_record () =
  let operation_id = "op-wire-audience-left" in
  let events, sink = collect_sink () in
  let unregister =
    Stream.For_testing.register_operation_live_sink ~operation_id sink
  in
  unregister ();
  Stream.For_testing.synthesize_wire_terminal_on_settle
    ~keeper_name:"wire-test"
    ~operation_id
    ~execution:(failed_execution "client disconnected before settle");
  check int "no synthesis after the audience left" 0 (List.length !events);
  check bool "record dropped with the last sink" true
    (Option.is_none (Stream.For_testing.take_operation_wire_stream ~operation_id))

let test_production_glue_settles_claimed_operation () =
  (* Executes the exact function the operation_runner wires. Both identifiers
     are plain strings past this boundary, so a swapped argument would
     typecheck — the content assertions below are the guard (#28849 review). *)
  let operation_id_string = "op-wire-glue" in
  let operation_id =
    match
      Keeper_owner.Chat_operation.Operation_id.of_string operation_id_string
    with
    | Ok id -> id
    | Error detail -> fail detail
  in
  let events, sink = collect_sink () in
  let unregister =
    Stream.For_testing.register_operation_live_sink
      ~operation_id:operation_id_string
      sink
  in
  Fun.protect ~finally:unregister @@ fun () ->
  Stream.For_testing.on_operation_execution_settled
    ~keeper_name:"wire-glue"
    ~claimed_operation_id:(Some operation_id)
    ~execution:(failed_execution "glue path verdict");
  (match !events with
   | [ event ] ->
     let sse = Ag_ui.event_to_sse event in
     check bool "keeper name lands in thread_id position" true
       (Astring.String.is_infix ~affix:"keeper:wire-glue" sse);
     check bool "operation id lands in run_id position" true
       (Astring.String.is_infix
          ~affix:("keeper-operation-run-" ^ operation_id_string)
          sse)
   | events ->
     fail
       (Printf.sprintf "expected one glue-synthesized event, got %d"
          (List.length events)));
  (* Unclaimed settle is a no-op through the same glue. *)
  Stream.For_testing.on_operation_execution_settled
    ~keeper_name:"wire-glue"
    ~claimed_operation_id:None
    ~execution:(failed_execution "never claimed");
  check int "unclaimed settle synthesizes nothing" 1 (List.length !events)

let test_settle_success_without_terminal_emits_nothing () =
  let operation_id = "op-wire-success-anomaly" in
  let events, sink = collect_sink () in
  let unregister =
    Stream.For_testing.register_operation_live_sink ~operation_id sink
  in
  Fun.protect ~finally:unregister @@ fun () ->
  Stream.For_testing.note_operation_wire_event ~operation_id (custom_event ());
  Stream.For_testing.synthesize_wire_terminal_on_settle
    ~keeper_name:"wire-test"
    ~operation_id
    ~execution:(Keeper_owner.Operation_succeeded { outcome_ref = "ref" });
  check int "success anomaly is logged, not synthesized" 0 (List.length !events);
  check bool "success settle still consumes the record" true
    (Option.is_none (Stream.For_testing.take_operation_wire_stream ~operation_id))

let () =
  Alcotest.run "keeper_wire_terminal"
    [ ( "wire-terminal"
      , [ test_case "note marks started then terminal" `Quick
            test_note_marks_started_then_terminal
        ; test_case "settle synthesizes RUN_ERROR for open stream" `Quick
            test_settle_synthesizes_run_error_for_open_stream
        ; test_case "settle silent when terminal already sent" `Quick
            test_settle_is_silent_when_terminal_already_sent
        ; test_case "settle synthesizes for attached client with no events" `Quick
            test_settle_synthesizes_for_attached_client_with_no_events
        ; test_case "settle silent without audience" `Quick
            test_settle_is_silent_without_audience
        ; test_case "unregistering last sink drops the record" `Quick
            test_unregistering_last_sink_drops_the_record
        ; test_case "production glue settles claimed operation" `Quick
            test_production_glue_settles_claimed_operation
        ; test_case "success without terminal emits nothing" `Quick
            test_settle_success_without_terminal_emits_nothing
        ] )
    ]
