(* [chat_rows_for] answers from its memo until one of its inputs is
   replaced.

   The renderer asks for one conversation's rows several times per frame and
   on frames where nothing changed; the memo is what makes those asks free.
   What has to hold is narrower than "fast": the same inputs give the very
   same list, and a replaced input -- a loaded page, a new session row, a
   queued request, an inflight turn, another keeper -- gives a fresh answer
   that reflects it. *)

module Tui_types = Masc_tui_types
module Queue = Masc_tui_keeper_chat_queue

let entry_at ?(keeper = "alpha") ?(request_id = "") at : Tui_types.msg_entry =
  { Tui_types.me_keeper_name = keeper
  ; me_role = Tui_types.Message_keeper
  ; me_identity = Tui_types.Persisted_row (Printf.sprintf "msg-%s-%.0f" keeper at)
  ; me_turn_phase = Tui_types.Turn_output
  ; me_turn_sequence = None
  ; me_operation_seq = 0
  ; me_text = Printf.sprintf "row at %.0f" at
  ; me_memory_summary = None
  ; me_gate = None
  ; me_submitted_at = None
  ; me_tool_block = None
  ; me_skill_activity = None
  ; me_timestamp = ""
  ; me_request_id = request_id
  ; me_at = at
  }
;;

let fresh_state () =
  let state =
    Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
  in
  state.Tui_types.msg_target_keeper_name <- Some "alpha";
  state.Tui_types.msg_loaded_keeper <- Some "alpha";
  state.Tui_types.msg_loaded <- [ entry_at 1.0; entry_at 2.0 ];
  state
;;

let texts rows = List.map (fun (row : Tui_types.msg_entry) -> row.me_text) rows

let test_same_inputs_return_the_same_list () =
  let state = fresh_state () in
  let first = Tui_types.chat_rows_for state "alpha" in
  let second = Tui_types.chat_rows_for state "alpha" in
  Alcotest.(check bool) "physically the same list" true (first == second);
  Alcotest.(check (list string)) "two rows" [ "row at 1"; "row at 2" ] (texts first)
;;

let test_replaced_loaded_page_is_seen () =
  let state = fresh_state () in
  let before = Tui_types.chat_rows_for state "alpha" in
  state.Tui_types.msg_loaded <- entry_at 0.5 :: state.Tui_types.msg_loaded;
  let after = Tui_types.chat_rows_for state "alpha" in
  Alcotest.(check bool) "recomputed" false (before == after);
  Alcotest.(check (list string))
    "the older row leads"
    [ "row at 0"; "row at 1"; "row at 2" ]
    (texts after)
;;

let test_replaced_session_rows_are_seen () =
  let state = fresh_state () in
  let before = Tui_types.chat_rows_for state "alpha" in
  state.Tui_types.msg_history <- [ entry_at 3.0 ];
  let after = Tui_types.chat_rows_for state "alpha" in
  Alcotest.(check bool) "recomputed" false (before == after);
  Alcotest.(check int) "three rows" 3 (List.length after)
;;

let test_another_keeper_gets_its_own_rows () =
  let state = fresh_state () in
  let alpha = Tui_types.chat_rows_for state "alpha" in
  let beta = Tui_types.chat_rows_for state "beta" in
  Alcotest.(check (list string)) "beta has no loaded rows" [] (texts beta);
  Alcotest.(check bool) "alpha again is recomputed after beta" false
    (alpha == Tui_types.chat_rows_for state "alpha");
  Alcotest.(check (list string)) "and still right" [ "row at 1"; "row at 2" ]
    (texts (Tui_types.chat_rows_for state "alpha"))
;;

let test_replaced_queue_recomputes_and_identical_inflight_does_not () =
  let state = fresh_state () in
  let before = Tui_types.chat_rows_for state "alpha" in
  (* Assigning the same empty list is not a change: the memo keys on identity
     and [[]] is one value. *)
  state.Tui_types.msg_inflight <- [];
  Alcotest.(check bool) "identical inflight keeps the memo" true
    (before == Tui_types.chat_rows_for state "alpha");
  let request keeper_name =
    { Queue.Chat.request_id = "req-" ^ keeper_name
    ; keeper_name
    ; message = "hello"
    ; attachments = []
    ; references = []
    }
  in
  let push keeper_name =
    match
      Queue.push state.Tui_types.msg_queued ~submitted_at:1.0 (request keeper_name)
    with
    | Ok (queue, _) -> state.Tui_types.msg_queued <- queue
    | Error detail -> Alcotest.fail detail
  in
  (* Another keeper's line does not touch alpha's rows: the memo reads what
     waits for alpha, not the queue's identity. *)
  push "beta";
  Alcotest.(check bool) "a line for beta keeps alpha's memo" true
    (before == Tui_types.chat_rows_for state "alpha");
  push "alpha";
  let after_queue = Tui_types.chat_rows_for state "alpha" in
  Alcotest.(check bool) "a line for alpha recomputes" false (before == after_queue);
  Alcotest.(check (list string)) "and the rows are unchanged in content"
    (texts before) (texts after_queue);
  Alcotest.(check bool) "then stable again" true
    (after_queue == Tui_types.chat_rows_for state "alpha")
;;

(* A settled log is an input too: replacing the list recomputes, and the
   held turn's loaded rows are gone from the answer; the same list keeps
   the memo. *)
let test_replaced_settled_logs_are_seen () =
  let state = fresh_state () in
  state.Tui_types.msg_loaded <-
    entry_at ~request_id:"held" 3.0 :: state.Tui_types.msg_loaded;
  let before = Tui_types.chat_rows_for state "alpha" in
  Alcotest.(check int) "three rows before" 3 (List.length before);
  let log =
    Tui_types.turn_log_create ~keeper_name:"alpha" ~request_id:"held"
      ~started_at:3.0
  in
  Tui_types.turn_log_add ~now:3.0 log ~seq:(Some 0)
    Masc_tui_keeper_chat_live.Run_started;
  Tui_types.turn_log_add ~now:3.0 log ~seq:(Some 1)
    (Masc_tui_keeper_chat_live.Reply_details
       { reply = "row at 3"
       ; turn_outcome = Masc.Keeper_turn_outcome.Visible_reply
       ; turn_ref = "trace-1#1"
       });
  Tui_types.turn_log_add ~now:3.0 log ~seq:(Some 2)
    Masc_tui_keeper_chat_live.Run_finished;
  Masc_tui_keeper_chat_log.commit log.Tui_types.tl_log;
  state.Tui_types.msg_settled_logs <- [ log ];
  let after = Tui_types.chat_rows_for state "alpha" in
  Alcotest.(check bool) "recomputed" false (before == after);
  Alcotest.(check (list string)) "the held turn's row is the log's now"
    [ "row at 1"; "row at 2" ] (texts after);
  Alcotest.(check bool) "then stable again" true
    (after == Tui_types.chat_rows_for state "alpha")
;;

(* A held log that comes to stand for its turn in place is an input change
   too. A cut stream leaves a partial log among the settled ones; a journal
   read then feeds the rest of the turn into that same log, through the fold
   the reload handler uses, and holds it again. The list the memo keys on
   must be a new value then, or the memo keeps answering with the loaded
   rows the log now draws itself -- the turn on screen twice. *)
let test_a_held_log_completed_in_place_is_seen () =
  let module E = Masc.Keeper_chat_events in
  let module Journal = Masc.Keeper_chat_event_log in
  let line seq ts event : Journal.journaled_event = { Journal.seq; ts; event } in
  let state = fresh_state () in
  state.Tui_types.msg_loaded <-
    entry_at ~request_id:"cut" 3.0 :: state.Tui_types.msg_loaded;
  let log =
    Tui_types.turn_log_create ~keeper_name:"alpha" ~request_id:"cut"
      ~started_at:3.0
  in
  (* The cut: the stream delivered a start and some text, then went away;
     the settle committed what it had. *)
  Tui_types.turn_log_add_journaled log
    [ line 0 3.0 (E.Run_started { run_id = "r"; thread_id = "keeper:alpha" })
    ; line 1 3.1 (E.Text_delta "row at 3")
    ];
  Masc_tui_keeper_chat_log.commit log.Tui_types.tl_log;
  Tui_types.hold_settled_log state log;
  let partial = Tui_types.chat_rows_for state "alpha" in
  Alcotest.(check bool) "a partial log does not stand for the turn" false
    (Tui_types.turn_log_holds_the_turn log);
  Alcotest.(check (list string)) "so the loaded row is still drawn"
    [ "row at 1"; "row at 2"; "row at 3" ] (texts partial);
  (* The journal read: the rest of the turn joins the same log, which is
     committed and held again, as the reload handler does. *)
  Tui_types.turn_log_add_journaled log
    [ line 2 3.2
        (E.Reply_details
           { reply = "row at 3"
           ; turn_outcome = Masc.Keeper_turn_outcome.Visible_reply
           ; turn_ref = Ids.Turn_ref.make ~trace_id:"trace-1" ~absolute_turn:1
           })
    ; line 3 3.3 (E.Run_finished { run_id = "r" })
    ];
  Masc_tui_keeper_chat_log.commit log.Tui_types.tl_log;
  Tui_types.hold_settled_log state log;
  Alcotest.(check bool) "the log now stands for the turn" true
    (Tui_types.turn_log_holds_the_turn log);
  let whole = Tui_types.chat_rows_for state "alpha" in
  Alcotest.(check bool) "recomputed" false (partial == whole);
  Alcotest.(check (list string)) "the loaded row for the turn is the log's now"
    [ "row at 1"; "row at 2" ] (texts whole);
  Alcotest.(check bool) "then stable again" true
    (whole == Tui_types.chat_rows_for state "alpha")
;;

let () =
  Alcotest.run
    "tui chat rows memo"
    [ ( "memo",
        [ Alcotest.test_case "same inputs return the same list" `Quick
            test_same_inputs_return_the_same_list;
          Alcotest.test_case "replaced loaded page is seen" `Quick
            test_replaced_loaded_page_is_seen;
          Alcotest.test_case "replaced session rows are seen" `Quick
            test_replaced_session_rows_are_seen;
          Alcotest.test_case "another keeper gets its own rows" `Quick
            test_another_keeper_gets_its_own_rows;
          Alcotest.test_case "replaced queue recomputes, identical inflight does not" `Quick
            test_replaced_queue_recomputes_and_identical_inflight_does_not;
          Alcotest.test_case "replaced settled logs are seen" `Quick
            test_replaced_settled_logs_are_seen;
          Alcotest.test_case "a held log completed in place is seen" `Quick
            test_a_held_log_completed_in_place_is_seen
        ] )
    ]
;;
