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
            test_replaced_settled_logs_are_seen
        ] )
    ]
;;
