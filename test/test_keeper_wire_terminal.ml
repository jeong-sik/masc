(* Wire-terminal synthesis for keeper chat operations (#28811).

   A cancelled turn kills the AG-UI projection fiber inside the child switch
   before it can emit RUN_ERROR, so the SSE stream used to close with no
   terminal receipt. The server tracks per-operation wire activity and the
   Owner settle hook synthesizes the missing terminal from the execution
   verdict. These tests pin the registry transitions and the synthesis
   decision table. *)

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
  let sink event = events := event :: !events in
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

let test_settle_is_silent_without_wire_activity () =
  let operation_id = "op-wire-never-opened" in
  let events, sink = collect_sink () in
  let unregister =
    Stream.For_testing.register_operation_live_sink ~operation_id sink
  in
  Fun.protect ~finally:unregister @@ fun () ->
  Stream.For_testing.synthesize_wire_terminal_on_settle
    ~keeper_name:"wire-test"
    ~operation_id
    ~execution:(failed_execution "no stream ever opened");
  check int "no synthesis without wire activity" 0 (List.length !events)

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
        ; test_case "settle silent without wire activity" `Quick
            test_settle_is_silent_without_wire_activity
        ; test_case "success without terminal emits nothing" `Quick
            test_settle_success_without_terminal_emits_nothing
        ] )
    ]
