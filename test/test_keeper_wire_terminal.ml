(* Wire-terminal synthesis for keeper chat operations (#28811).

   A cancelled turn kills the AG-UI projection fiber inside the child switch
   before it can emit RUN_ERROR, so the SSE stream used to close with no
   terminal receipt. The server tracks per-operation wire audience — open
   from sink registration, dropped when the last sink leaves — and the Owner
   settle hook records the missing terminal before projecting the execution
   verdict. These tests cover registry transitions, disconnected cancellation
   replay, failed persistence, and the production glue the runner wires. *)

open Alcotest
open Masc
module Stream = Server_routes_http_keeper_stream
module Journal = Keeper_chat_event_log
module Events = Keeper_chat_events

let keeper_name = "wire-test"

let with_workspace f =
  let base_path = Masc_test_deps.setup_test_workspace () in
  Fun.protect ~finally:(fun () -> Masc_test_deps.cleanup_test_workspace base_path)
    (fun () -> f base_path)

let read_journal ~base_path ~keeper_name ~operation_id =
  match Journal.read_journal_path_result
    (Journal.journal_path ~base_dir:base_path ~keeper_name ~operation_id) with
  | Ok entries -> entries
  | Error Journal.Journal_missing -> fail "settled operation has no journal"
  | Error (Journal_unreadable detail | Journal_corrupt detail) -> fail detail

let error_entries entries = List.filter (fun (entry : Journal.journaled_event) ->
  match entry.event with Events.Event_error _ -> true | _ -> false) entries

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
  with_workspace @@ fun base_path ->
  let operation_id = "op-wire-note" in
  Stream.For_testing.note_operation_wire_event ~base_path ~keeper_name ~operation_id (custom_event ());
  (match Stream.For_testing.take_operation_wire_stream ~base_path ~keeper_name ~operation_id with
   | Some Stream.Wire_started -> ()
   | Some Stream.Wire_terminal_sent -> fail "custom event marked terminal"
   | None -> fail "custom event did not open a wire stream");
  Stream.For_testing.note_operation_wire_event ~base_path ~keeper_name ~operation_id (custom_event ());
  Stream.For_testing.note_operation_wire_event ~base_path ~keeper_name ~operation_id (run_error_event ());
  (match Stream.For_testing.take_operation_wire_stream ~base_path ~keeper_name ~operation_id with
   | Some Stream.Wire_terminal_sent -> ()
   | Some Stream.Wire_started -> fail "terminal event left the stream open"
   | None -> fail "terminal event dropped the stream record");
  check bool "take consumes the record" true
    (Option.is_none (Stream.For_testing.take_operation_wire_stream ~base_path ~keeper_name ~operation_id))

let collect_sink () =
  let events = ref [] in
  let sink ~seq:_ event = events := event :: !events in
  (events, sink)

let test_same_request_id_keeps_keeper_wire_audiences_separate () =
  with_workspace @@ fun base_path ->
  let operation_id = "op-shared-request" in
  let alpha, alpha_sink = collect_sink () in
  let beta, beta_sink = collect_sink () in
  let unregister_alpha = Stream.For_testing.register_operation_live_sink ~base_path
      ~keeper_name:"wire-alpha" ~operation_id alpha_sink in
  let unregister_beta = Stream.For_testing.register_operation_live_sink ~base_path
      ~keeper_name:"wire-beta" ~operation_id beta_sink in
  Fun.protect ~finally:(fun () -> unregister_alpha (); unregister_beta ()) @@ fun () ->
  let settle keeper_name =
    Stream.For_testing.synthesize_wire_terminal_on_settle ~base_path ~keeper_name
      ~operation_id ~execution:(failed_execution (keeper_name ^ " stopped")) in
  settle "wire-alpha";
  check int "alpha receives its terminal" 1 (List.length !alpha);
  check int "beta never receives alpha's terminal" 0 (List.length !beta);
  settle "wire-beta";
  check int "beta settlement cannot write to alpha" 1 (List.length !alpha);
  check int "beta independently receives its terminal" 1 (List.length !beta);
  List.iter (fun (keeper_name, observed) ->
    match !observed, error_entries (read_journal ~base_path ~keeper_name ~operation_id) with
    | [event], [{ Journal.seq = 0; event = Events.Event_error { message }; _ }] ->
      check string "durable failure belongs to this Keeper" (keeper_name ^ " stopped") message;
      let expected = Ag_ui.make_event ~timestamp:event.Ag_ui.timestamp
        ~thread_id:("keeper:" ^ keeper_name)
        ~run_id:(Some ("keeper-operation-run-" ^ operation_id))
        ~message:(Some message) ~code:(Some "Turn_cancelled") Ag_ui.Run_error in
      check string "wire carries only its Keeper's payload"
        (Ag_ui.event_to_sse expected) (Ag_ui.event_to_sse event)
    | _ -> fail "each Keeper must own one independent terminal and seq-zero journal")
    ["wire-alpha", alpha; "wire-beta", beta]

let test_same_request_id_keeps_terminal_accounting_and_unsubscribe_separate () =
  with_workspace @@ fun base_path ->
  let operation_id = "op-shared-wire-accounting" in
  let _, sink = collect_sink () in
  let unregister_alpha = Stream.For_testing.register_operation_live_sink ~base_path
      ~keeper_name:"wire-alpha" ~operation_id sink in
  let unregister_beta = Stream.For_testing.register_operation_live_sink ~base_path
      ~keeper_name:"wire-beta" ~operation_id sink in
  Fun.protect ~finally:(fun () -> unregister_alpha (); unregister_beta ()) @@ fun () ->
  Stream.For_testing.note_operation_wire_event ~base_path ~keeper_name:"wire-alpha"
    ~operation_id (run_error_event ());
  check bool "alpha terminal cannot mark beta terminal" true
    (Stream.For_testing.take_operation_wire_stream ~base_path ~keeper_name:"wire-beta"
       ~operation_id = Some Stream.Wire_started);
  check bool "taking beta cannot consume alpha's terminal" true
    (Stream.For_testing.take_operation_wire_stream ~base_path ~keeper_name:"wire-alpha"
       ~operation_id = Some Stream.Wire_terminal_sent);
  Stream.For_testing.note_operation_wire_event ~base_path ~keeper_name:"wire-alpha"
    ~operation_id (custom_event ());
  Stream.For_testing.note_operation_wire_event ~base_path ~keeper_name:"wire-beta"
    ~operation_id (custom_event ());
  unregister_alpha ();
  check bool "alpha's last subscriber removes its record" true
    (Option.is_none (Stream.For_testing.take_operation_wire_stream ~base_path
       ~keeper_name:"wire-alpha" ~operation_id));
  check bool "alpha unsubscribe retains beta's open record" true
    (Stream.For_testing.take_operation_wire_stream ~base_path ~keeper_name:"wire-beta"
       ~operation_id = Some Stream.Wire_started)

let test_same_keeper_and_request_id_keep_runtime_roots_separate () =
  with_workspace @@ fun parent ->
  (* The shared fixture names its root from millisecond time. Allocate both
     simultaneously live runtime roots under one owned fixture directory. *)
  let root_alpha = Filename.concat parent "runtime-alpha" in
  let root_beta = Filename.concat parent "runtime-beta" in
  List.iter (fun root ->
    Unix.mkdir root 0o755;
    Unix.mkdir (Filename.concat root Common.masc_dirname) 0o755)
    [root_alpha; root_beta];
  let operation_id = "op-shared-across-roots" in
  let alpha, alpha_sink = collect_sink () in
  let beta, beta_sink = collect_sink () in
  (* The registry's canonical spelling also has to meet settlement's spelling. *)
  let unregister_alpha = Stream.For_testing.register_operation_live_sink
      ~base_path:(Filename.concat root_alpha ".") ~keeper_name ~operation_id alpha_sink in
  let unregister_beta = Stream.For_testing.register_operation_live_sink
      ~base_path:root_beta ~keeper_name ~operation_id beta_sink in
  Fun.protect ~finally:(fun () -> unregister_alpha (); unregister_beta ()) @@ fun () ->
  let settle base_path detail = Stream.For_testing.synthesize_wire_terminal_on_settle
      ~base_path ~keeper_name ~operation_id ~execution:(failed_execution detail) in
  settle root_alpha "alpha root stopped";
  check int "canonical root reaches its registered alias" 1 (List.length !alpha);
  check int "same Keeper and request in beta root stay isolated" 0 (List.length !beta);
  unregister_alpha ();
  check bool "alpha release drops only alpha's terminal accounting" true
    (Option.is_none (Stream.For_testing.take_operation_wire_stream
       ~base_path:root_alpha ~keeper_name ~operation_id));
  settle root_beta "beta root stopped";
  check int "alpha release cannot unregister beta's audience" 1 (List.length !beta);
  check int "beta's terminal cannot affect alpha's audience" 1 (List.length !alpha);
  List.iter (fun (base_path, message, observed) ->
    (match !observed with
     | [event] -> check (option string) "wire belongs to this runtime root"
         (Some message) event.Ag_ui.message
     | _ -> fail "each runtime root must receive one terminal");
    match error_entries (read_journal ~base_path ~keeper_name ~operation_id) with
    | [{Journal.seq=0; event=Events.Event_error {message=actual}; _}] ->
        check string "each root has its own seq-zero durable failure" message actual
    | _ -> fail "runtime roots shared a journal or cursor")
    [root_alpha, "alpha root stopped", alpha; root_beta, "beta root stopped", beta]

let test_settle_synthesizes_run_error_for_open_stream () =
  with_workspace @@ fun base_path ->
  let operation_id = "op-wire-cancelled" in
  let events, collect = collect_sink () in
  let sink ~seq event =
    let persisted = read_journal ~base_path ~keeper_name:"wire-test" ~operation_id in
    check int "terminal is durable before live delivery" 1 (List.length (error_entries persisted));
    check (option int) "live cursor names the persisted event" (Some 0) seq;
    collect ~seq event in
  let unregister =
    Stream.For_testing.register_operation_live_sink ~base_path ~keeper_name ~operation_id sink
  in
  Fun.protect ~finally:unregister @@ fun () ->
  Stream.For_testing.note_operation_wire_event ~base_path ~keeper_name ~operation_id (custom_event ());
  Stream.For_testing.synthesize_wire_terminal_on_settle
    ~base_path
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
    ~base_path
    ~keeper_name:"wire-test"
    ~operation_id
    ~execution:(failed_execution "second settle");
  check int "second settle synthesizes nothing" 1 (List.length !events)

let test_settle_is_silent_when_terminal_already_sent () =
  with_workspace @@ fun base_path ->
  let operation_id = "op-wire-terminal-sent" in
  let events, sink = collect_sink () in
  let unregister =
    Stream.For_testing.register_operation_live_sink ~base_path ~keeper_name ~operation_id sink
  in
  Fun.protect ~finally:unregister @@ fun () ->
  Stream.For_testing.note_operation_wire_event ~base_path ~keeper_name ~operation_id (custom_event ());
  Stream.For_testing.note_operation_wire_event ~base_path ~keeper_name ~operation_id (run_error_event ());
  let journal = Journal.open_journal ~base_dir:base_path
    ~keeper_name:"wire-test" ~operation_id () in
  Journal.append journal ~seq:0 ~ts:42. (Events.Event_error { message = "already terminal" });
  Stream.For_testing.synthesize_wire_terminal_on_settle
    ~base_path
    ~keeper_name:"wire-test"
    ~operation_id
    ~execution:(failed_execution "already terminal");
  check int "no duplicate terminal" 0 (List.length !events);
  check int "no duplicate durable failure" 1
    (List.length (error_entries (read_journal ~base_path ~keeper_name:"wire-test" ~operation_id)))

let test_settle_synthesizes_for_attached_client_with_no_events () =
  with_workspace @@ fun base_path ->
  (* A turn that fails after claim but before the projection ever runs
     (missing input, payload parse failure) projects no events. The attached
     client still needs a terminal: sink registration alone opens the wire
     stream (#28849 review). *)
  let operation_id = "op-wire-claimed-no-projection" in
  let events, sink = collect_sink () in
  let unregister =
    Stream.For_testing.register_operation_live_sink ~base_path ~keeper_name ~operation_id sink
  in
  Fun.protect ~finally:unregister @@ fun () ->
  Stream.For_testing.synthesize_wire_terminal_on_settle
    ~base_path
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
  with_workspace @@ fun base_path ->
  let operation_id = "op-wire-no-audience" in
  check bool "no record before settle" true
    (Option.is_none (Stream.For_testing.take_operation_wire_stream ~base_path ~keeper_name ~operation_id));
  (* No sink was ever registered: settlement still creates durable failure
     evidence for the journal endpoint and a later reconnect. *)
  Stream.For_testing.synthesize_wire_terminal_on_settle
    ~base_path
    ~keeper_name:"wire-test"
    ~operation_id
    ~execution:(failed_execution "no audience ever attached");
  check bool "still no wire record after settle" true
    (Option.is_none (Stream.For_testing.take_operation_wire_stream ~base_path ~keeper_name ~operation_id));
  check int "failure persists without an audience" 1
    (List.length (error_entries
      (read_journal ~base_path ~keeper_name:"wire-test" ~operation_id)))

let test_unregistering_last_sink_drops_the_record () =
  with_workspace @@ fun base_path ->
  let operation_id = "op-wire-audience-left" in
  let events, sink = collect_sink () in
  let unregister =
    Stream.For_testing.register_operation_live_sink ~base_path ~keeper_name ~operation_id sink
  in
  unregister ();
  Stream.For_testing.synthesize_wire_terminal_on_settle
    ~base_path
    ~keeper_name:"wire-test"
    ~operation_id
    ~execution:(failed_execution "client disconnected before settle");
  check int "no synthesis after the audience left" 0 (List.length !events);
  check bool "record dropped with the last sink" true
    (Option.is_none (Stream.For_testing.take_operation_wire_stream ~base_path ~keeper_name ~operation_id));
  check int "disconnected failure persists" 1
    (List.length (error_entries
      (read_journal ~base_path ~keeper_name:"wire-test" ~operation_id)))

let test_production_glue_settles_claimed_operation () =
  with_workspace @@ fun base_path ->
  let keeper_name = "wire-glue" in
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
    Stream.For_testing.register_operation_live_sink ~base_path ~keeper_name
      ~operation_id:operation_id_string
      sink
  in
  Fun.protect ~finally:unregister @@ fun () ->
  Stream.For_testing.on_operation_execution_settled
    ~base_path
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
    ~base_path
    ~keeper_name:"wire-glue"
    ~claimed_operation_id:None
    ~execution:(failed_execution "never claimed");
  check int "unclaimed settle synthesizes nothing" 1 (List.length !events)

let test_settle_success_without_terminal_emits_nothing () =
  with_workspace @@ fun base_path ->
  let operation_id = "op-wire-success-anomaly" in
  let events, sink = collect_sink () in
  let unregister =
    Stream.For_testing.register_operation_live_sink ~base_path ~keeper_name ~operation_id sink
  in
  Fun.protect ~finally:unregister @@ fun () ->
  Stream.For_testing.note_operation_wire_event ~base_path ~keeper_name ~operation_id (custom_event ());
  Stream.For_testing.synthesize_wire_terminal_on_settle
    ~base_path
    ~keeper_name:"wire-test"
    ~operation_id
    ~execution:(Keeper_owner.Operation_succeeded { outcome_ref = "ref" });
  check int "success anomaly is logged, not synthesized" 0 (List.length !events);
  check bool "success settle still consumes the record" true
    (Option.is_none (Stream.For_testing.take_operation_wire_stream ~base_path ~keeper_name ~operation_id))

let test_interrupted_owner_without_subscriber_replays_failure () =
  with_workspace @@ fun base_path ->
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let module Owner = Keeper_owner in
  let keeper_name = "cancelled-owner" in
  let operation_id_string = "op-interrupted-no-subscriber" in
  let operation_id = match Keeper_chat_operation.Operation_id.of_string operation_id_string with
    | Ok id -> id | Error detail -> fail detail in
  let owner_ok = function Ok value -> value | Error error -> fail (Owner.error_to_string error) in
  let meta = match Masc_test_deps.meta_of_json_fixture
    (`Assoc [ "name", `String keeper_name; "trace_id", `String "trace-cancelled-owner";
      "activation_mode", `String "manual" ]) with
    | Ok meta -> meta | Error detail -> fail detail in
  let started, signal_started = Eio.Promise.create () in
  let parked, _release = Eio.Promise.create () in
  let settled, signal_settled = Eio.Promise.create () in
  let execute ~sw:_ ~keeper_name:_ ~claim =
    ignore (Option.get (owner_ok (claim ())));
    let journal = Journal.open_journal ~base_dir:base_path ~keeper_name
      ~operation_id:operation_id_string () in
    Journal.append journal ~seq:0 ~ts:42.
      (Events.Run_started { run_id = "keeper-operation-run-" ^ operation_id_string;
        thread_id = "keeper:" ^ keeper_name });
    Journal.append journal ~seq:1 ~ts:42.
      (Events.Text_message_start { message_id = "interrupted-message"; role = Events.Assistant });
    Eio.Promise.resolve signal_started ();
    Eio.Promise.await parked;
    Owner.Operation_succeeded { outcome_ref = "unreachable-before-interrupt" } in
  let on_execution_settled ~keeper_name ~claimed_operation_id ~execution =
    Stream.For_testing.on_operation_execution_settled
      ~base_path ~keeper_name ~claimed_operation_id ~execution;
    Eio.Promise.resolve signal_settled execution in
  let owner = owner_ok (Owner.start ~sw
    ~store:{ replace = (fun _ -> Ok ()); remove = (fun _ -> Ok ()) }
    ~operation_store_path:(Filename.concat base_path "operations.sqlite3")
    ~now:(fun () -> 42.)
    ~operation_runner:(Some Owner.{ ready = (fun ~keeper_name:_ -> true);
      execute; on_execution_settled })
    ~on_turn_slot_released:None ~keeper_name ~initial_meta:(Some meta)) in
  ignore (owner_ok (Owner.submit_operation owner ~operation_id
    ~source:(`Assoc [ "kind", `String "dashboard" ])
    ~input:(`Assoc [ "message", `String "answer me" ])));
  Eio.Promise.await started;
  (match owner_ok (Owner.interrupt_running_operation owner operation_id) with
   | Owner.Operation_interrupt_signalled -> ()
   | _ -> fail "running operation did not accept the interrupt");
  (match Eio.Promise.await settled with
   | Owner.Operation_failed { kind = Keeper_chat_operation.Turn_cancelled; _ } -> ()
   | _ -> fail "interrupt did not settle as cancellation");
  let entries = read_journal ~base_path ~keeper_name ~operation_id:operation_id_string in
  check int "cancelled run has one durable error" 1 (List.length (error_entries entries));
  let frames = Stream.For_testing.journal_replay_frames ~base_path ~keeper_name
    ~operation_id:operation_id_string ~since_seq:(Journal.After_seq 1) in
  match frames with
  | [2, event] ->
    check bool "reopening sees RUN_ERROR" true (event.Ag_ui.event_type = Ag_ui.Run_error);
    check string "replay keeps Keeper identity" ("keeper:" ^ keeper_name) event.thread_id;
    check (option string) "replay keeps request identity"
      (Some ("keeper-operation-run-" ^ operation_id_string)) event.run_id
  | _ -> fail "reconnect did not replay the interrupted terminal"

let test_failed_continuation_after_prior_finished_segment () =
  with_workspace @@ fun base_path ->
  let keeper_name = "continued-owner" and operation_id = "op-continuation-failed" in
  let journal = Journal.open_journal ~base_dir:base_path ~keeper_name ~operation_id () in
  let run_id = "keeper-operation-run-" ^ operation_id in
  Journal.append journal ~seq:0 ~ts:42.
    (Events.Run_started { run_id; thread_id = "keeper:" ^ keeper_name });
  Journal.append journal ~seq:1 ~ts:42. (Events.Run_finished { run_id });
  (* The new segment failed before its Run_started reached the journal. *)
  Stream.For_testing.synthesize_wire_terminal_on_settle ~base_path ~keeper_name
    ~operation_id ~execution:(failed_execution "continuation interrupted before projection");
  let frames = Stream.For_testing.journal_replay_frames ~base_path ~keeper_name
    ~operation_id ~since_seq:(Journal.After_seq 1) in
  match frames with
  | [2, event] -> check bool "old finish did not hide new failure" true
      (event.Ag_ui.event_type = Ag_ui.Run_error)
  | _ -> fail "continuation failure disappeared behind its prior terminal"

(* A rejected terminal append leaves no durable seq, and both reconnect
   replay and the RFC-0412 live dedup key off seq membership. Broadcasting the
   terminal seq-less would close one live client while reconnecting clients
   replay the operation as still running (#41687 recurrence), so settlement
   logs the failure and skips the broadcast rather than projecting a delivery
   the ledger cannot back (constitution failure_keeps_evidence). *)
let test_journal_failure_skips_live_broadcast () =
  with_workspace @@ fun base_path ->
  let keeper_name = "unwritable-journal" and operation_id = "op-journal-failed" in
  ignore (Journal.open_journal ~base_dir:base_path ~keeper_name ~operation_id ());
  Unix.mkdir (Journal.journal_path ~base_dir:base_path ~keeper_name ~operation_id) 0o700;
  let delivered = ref [] in
  let unregister = Stream.For_testing.register_operation_live_sink ~base_path ~keeper_name ~operation_id
    (fun ~seq event -> delivered := (seq, event) :: !delivered) in
  Fun.protect ~finally:unregister @@ fun () ->
  Stream.For_testing.synthesize_wire_terminal_on_settle ~base_path ~keeper_name
    ~operation_id ~execution:(failed_execution "interrupted despite journal failure");
  check int "journal failure broadcasts nothing live" 0 (List.length !delivered);
  check bool "no fabricated wire record or cursor survives" true
    (Option.is_none (Stream.For_testing.take_operation_wire_stream ~base_path ~keeper_name ~operation_id))

(* Every settlement path without a live stream ends the journal through
   [record_terminal_error], so the helper itself carries the guarantees: one
   terminal per failure, never a second one, and a finished earlier segment
   does not stand in for it. *)
let test_record_terminal_error_writes_once () =
  with_workspace @@ fun base_path ->
  let keeper_name = "terminal-once" and operation_id = "op-terminal-once" in
  let journal = Journal.open_journal ~base_dir:base_path ~keeper_name ~operation_id () in
  let append seq event =
    match Journal.append_result journal ~seq ~ts:1.0 event with
    | Ok () -> ()
    | Error detail -> fail detail in
  append 0 (Events.Run_started { run_id = "run-1"; thread_id = "keeper:terminal-once" });
  append 1 (Events.Run_finished { run_id = "run-1" });
  append 2 (Events.Run_started { run_id = "run-2"; thread_id = "keeper:terminal-once" });
  (match Journal.record_terminal_error journal ~ts:2.0 ~message:"first cause" with
   | Ok (Journal.Recorded_terminal_error { seq; _ }) ->
     check int "appended after the unfinished segment" 3 seq
   | Ok (Journal.Existing_terminal_error _) ->
     fail "an earlier Run_finished stood in for this failure"
   | Error detail -> fail detail);
  (match Journal.record_terminal_error journal ~ts:3.0 ~message:"second cause" with
   | Ok (Journal.Existing_terminal_error { seq; message; _ }) ->
     check int "the first terminal is reported" 3 seq;
     check string "with the cause it recorded" "first cause" message
   | Ok (Journal.Recorded_terminal_error _) -> fail "a second terminal was appended"
   | Error detail -> fail detail);
  check int "one terminal in the journal" 1
    (List.length (error_entries (read_journal ~base_path ~keeper_name ~operation_id)))

(* A restart can cut an append between its write and its newline. The terminal
   still has to land: the next sequence comes from the complete rows, and the
   append cuts the fragment before it writes. *)
let test_record_terminal_error_cuts_a_torn_tail () =
  with_workspace @@ fun base_path ->
  let keeper_name = "terminal-torn" and operation_id = "op-terminal-torn" in
  let journal = Journal.open_journal ~base_dir:base_path ~keeper_name ~operation_id () in
  let append seq event =
    match Journal.append_result journal ~seq ~ts:1.0 event with
    | Ok () -> ()
    | Error detail -> fail detail in
  append 0 (Events.Run_started { run_id = "run-torn"; thread_id = "keeper:terminal-torn" });
  append 1 (Events.Text_delta {text="partial"; stream_scope=None});
  let path = Journal.journal_path ~base_dir:base_path ~keeper_name ~operation_id in
  let oc = open_out_gen [ Open_append; Open_wronly; Open_binary ] 0o600 path in
  output_string oc "{\"v\":1,\"seq\":2,\"ts\":1.5,\"event\":{\"type\":\"text_del";
  close_out oc;
  (match Journal.record_terminal_error journal ~ts:2.0 ~message:"cut by restart" with
   | Ok (Journal.Recorded_terminal_error { seq; _ }) ->
     check int "appended after the last complete row" 2 seq
   | Ok (Journal.Existing_terminal_error _) -> fail "a torn fragment stood in for a terminal"
   | Error detail -> fail ("the torn journal refused its terminal: " ^ detail));
  let entries = read_journal ~base_path ~keeper_name ~operation_id in
  check (list int) "the fragment is gone and the rows are in order" [ 0; 1; 2 ]
    (List.map (fun (entry : Journal.journaled_event) -> entry.seq) entries);
  check int "one terminal in the journal" 1 (List.length (error_entries entries))

let test_record_terminal_error_creates_a_missing_journal () =
  with_workspace @@ fun base_path ->
  let keeper_name = "terminal-missing" and operation_id = "op-terminal-missing" in
  let journal = Journal.open_journal ~base_dir:base_path ~keeper_name ~operation_id () in
  (match Journal.record_terminal_error journal ~ts:1.0 ~message:"never started" with
   | Ok (Journal.Recorded_terminal_error { seq; _ }) -> check int "first row" 0 seq
   | Ok (Journal.Existing_terminal_error _) -> fail "nothing existed to report"
   | Error detail -> fail detail);
  check int "the terminal is the journal" 1
    (List.length (read_journal ~base_path ~keeper_name ~operation_id))

let test_restart_settlement_retries_and_replays_past_a_live_cursor () =
  with_workspace @@ fun base_path ->
  let module Store = Keeper_chat_operation_store in
  let keeper_name = "restart-replay" and operation_id = "op-restart-replay" in
  let id = match Keeper_chat_operation.Operation_id.of_string operation_id with
    | Ok id -> id | Error detail -> fail detail in
  let store_ok = function Ok value -> value | Error error -> fail (Store.error_to_string error) in
  let store = store_ok (Store.open_or_create ~path:(Filename.concat base_path "restart-replay.sqlite3")) in
  Fun.protect ~finally:(fun () -> ignore (Store.close store)) (fun () ->
    ignore (store_ok (Store.submit store ~now:1. ~operation_id:id
      ~source:(`Assoc ["kind",`String "dashboard"]) ~input:(`Assoc ["message",`String "work"])));
    ignore (store_ok (Store.claim_next store ~now:2.));
    ignore (store_ok (Store.settle_running_after_restart store ~now:3.));
    let operation = Option.get (store_ok (Store.get store id)) in
    let settlement : Journal.restart_settlement = {operation_id=id;completed_at=3.} in
    let journal = Journal.open_journal ~base_dir:base_path ~keeper_name ~operation_id () in
    let message = Keeper_request_failure.summary {cause=Keeper_request_failure.Server_restarted} in
    Journal.append journal ~seq:0 ~ts:1. (Events.Run_started {run_id="run";thread_id="keeper:restart-replay"});
    (* Identical text from an earlier segment does not identify this settlement. *)
    Journal.append journal ~seq:1 ~ts:2. (Events.Event_error {message});
    (match Journal.record_terminal_error ~segment:(Restart_settlement settlement) journal ~ts:3. ~message with
     | Ok (Recorded_terminal_error {seq=2;_}) -> ()
     | _ -> fail "restart must append its own identified terminal");
    (* Simulate restart after append success without any in-memory receipt. *)
    let reopened = Journal.open_journal ~base_dir:base_path ~keeper_name ~operation_id () in
    (match Journal.record_terminal_error ~segment:(Restart_settlement settlement) reopened ~ts:99. ~message with
     | Ok (Existing_terminal_error {seq=2;ts=3.;_}) -> ()
     | _ -> fail "retry must reuse the durable settlement marker");
    check int "retry appends no duplicate" 3 (List.length (read_journal ~base_path ~keeper_name ~operation_id));
    let replayed = Hashtbl.create 4 in
    let suffix = Stream.For_testing.journal_replay_frames ~base_path ~keeper_name ~operation_id
      ~since_seq:(Journal.After_seq 50) in
    check int "the client's live cursor is ahead of the journal" 0 (List.length suffix);
    let fallback = Stream.For_testing.restart_terminal_after_replay ~base_path ~keeper_name ~operation ~replayed in
    (match fallback with
     | Some event ->
         check bool "the durable failure still yields RUN_ERROR" true (event.Ag_ui.event_type=Ag_ui.Run_error);
         let wire = Ag_ui.event_to_sse event in
         check bool "the supplemental frame does not regress the cursor" false (String.starts_with ~prefix:"id:" wire)
     | None -> fail "a cursor beyond the repaired journal lost the terminal");
    Stream.For_testing.journal_replay_frames ~base_path ~keeper_name ~operation_id ~since_seq:Journal.Whole_turn
    |> List.iter (fun (seq,_) -> Hashtbl.replace replayed seq ());
    check bool "ordinary replay already includes this exact terminal" true
      (Option.is_none (Stream.For_testing.restart_terminal_after_replay ~base_path ~keeper_name ~operation ~replayed));
    let metadata = `Assoc ["operation_id",`String operation_id;"completed_at",`Float 3.] in
    List.iter (fun (event, fields) ->
      let envelope = Journal.journaled_event_to_json {seq=0;ts=3.;event} in
      let envelope = match envelope with `Assoc base -> `Assoc (base @ fields) | _ -> assert false in
      check bool "malformed restart provenance is refused" true (Result.is_error (Journal.journaled_event_of_json envelope)))
      [ Events.Event_error {message}, ["restart_settlement",`String "unknown"]
      ; Events.Event_error {message}, ["restart_settlement",metadata;"restart_settlement",metadata]
      ; Events.Text_delta {text="not terminal"; stream_scope=None}, ["restart_settlement",metadata] ])

let () =
  Alcotest.run "keeper_wire_terminal"
    [ ( "wire-terminal"
      , [ test_case "note marks started then terminal" `Quick
            test_note_marks_started_then_terminal
        ; test_case "same request ID has separate Keeper wire audiences" `Quick
            test_same_request_id_keeps_keeper_wire_audiences_separate
        ; test_case "same request ID has separate terminal and unsubscribe state" `Quick
            test_same_request_id_keeps_terminal_accounting_and_unsubscribe_separate
        ; test_case "same Keeper and request ID have separate runtime roots" `Quick
            test_same_keeper_and_request_id_keep_runtime_roots_separate
        ; test_case "settle synthesizes RUN_ERROR for open stream" `Quick
            test_settle_synthesizes_run_error_for_open_stream
        ; test_case "settle silent when terminal already sent" `Quick
            test_settle_is_silent_when_terminal_already_sent
        ; test_case "settle synthesizes for attached client with no events" `Quick
            test_settle_synthesizes_for_attached_client_with_no_events
        ; test_case "settle persists without audience" `Quick
            test_settle_is_silent_without_audience
        ; test_case "unregistering last sink drops the record" `Quick
            test_unregistering_last_sink_drops_the_record
        ; test_case "production glue settles claimed operation" `Quick
            test_production_glue_settles_claimed_operation
        ; test_case "success without terminal emits nothing" `Quick
            test_settle_success_without_terminal_emits_nothing
        ; test_case "interrupted owner replays failure without subscriber" `Quick
            test_interrupted_owner_without_subscriber_replays_failure
        ; test_case "failed continuation follows prior finished segment" `Quick
            test_failed_continuation_after_prior_finished_segment
        ; test_case "journal failure skips live broadcast without durable seq" `Quick
            test_journal_failure_skips_live_broadcast
        ; test_case "record_terminal_error writes once" `Quick
            test_record_terminal_error_writes_once
        ; test_case "record_terminal_error cuts a torn tail" `Quick
            test_record_terminal_error_cuts_a_torn_tail
        ; test_case "record_terminal_error creates a missing journal" `Quick
            test_record_terminal_error_creates_a_missing_journal
        ; test_case "durable restart settlement retries and survives a newer live cursor" `Quick
            test_restart_settlement_retries_and_replays_past_a_live_cursor
        ] )
    ]
