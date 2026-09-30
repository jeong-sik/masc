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
  ; me_image = Masc_tui_image_preview.No_image
  ; me_memory_summary = None
  ; me_journal = []
  ; me_memory_pass = Masc_tui_message_layout.No_pass
  ; me_gate = None
  ; me_submitted_at = None
  ; me_tool_block = None
  ; me_skill_block = []
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
  let _ = Tui_types.turn_log_add_journaled log
    [ line 0 3.0 (E.Run_started { run_id = "r"; thread_id = "keeper:alpha" })
    ; line 1 3.1 (E.Text_delta "row at 3")
    ] in
  Masc_tui_keeper_chat_log.commit log.Tui_types.tl_log;
  Tui_types.hold_settled_log state log;
  let partial = Tui_types.chat_rows_for state "alpha" in
  Alcotest.(check bool) "a partial log does not stand for the turn" false
    (Tui_types.turn_log_holds_the_turn log);
  Alcotest.(check (list string)) "so the loaded row is still drawn"
    [ "row at 1"; "row at 2"; "row at 3" ] (texts partial);
  (* The journal read: the rest of the turn joins the same log, which is
     committed and held again, as the reload handler does. *)
  let _ = Tui_types.turn_log_add_journaled log
    [ line 2 3.2
        (E.Reply_details
           { reply = "row at 3"
           ; turn_outcome = Masc.Keeper_turn_outcome.Visible_reply
           ; turn_ref = Ids.Turn_ref.make ~trace_id:"trace-1" ~absolute_turn:1
           })
    ; line 3 3.3 (E.Run_finished { run_id = "r" })
    ] in
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

let test_refresh_preserves_output_until_its_replacement_arrives () =
  let state = fresh_state () in
  let reply =
    { (entry_at ~request_id:"just-finished" 3.) with
      me_identity = Tui_types.Session_row
        { request_id = "just-finished"
        ; turn_phase = Tui_types.Turn_output
        ; operation_seq = 1
        }
    ; me_text = "the reply that finished after GET started"
    }
  in
  state.msg_history <- [reply];
  let apply fresh =
    state.msg_history <-
      List.filter
        (fun row -> not (Tui_types.transcript_replaces_session_output ~fresh row))
        state.msg_history;
    state.msg_loaded <- Tui_types.merge_paged_history ~paged:state.msg_loaded ~fresh
  in
  apply [];
  Alcotest.(check bool) "an empty successful page keeps the reply" true
    (List.exists (fun row -> row.Tui_types.me_text = reply.me_text)
       (Tui_types.chat_rows_for state "alpha"));
  let addressed =
    { (entry_at ~request_id:"just-finished" 2.5) with
      me_role = Tui_types.Message_user (Tui_types.Sent_by_operator {surface = None})
    }
  in
  apply [addressed];
  Alcotest.(check int) "the user row alone cannot replace the reply" 1
    (List.length state.msg_history);
  apply [entry_at ~request_id:"another-turn" 4.];
  Alcotest.(check int) "another completed turn cannot replace the reply" 1
    (List.length state.msg_history);
  apply [{reply with me_identity = Tui_types.Persisted_row "durable-reply"}];
  Alcotest.(check int) "the exact turn's durable reply replaces the session copy" 0
    (List.length state.msg_history);
  Alcotest.(check int) "the reply stays visible once" 1
    (List.length
       (List.filter (fun row -> row.Tui_types.me_text = reply.me_text)
          (Tui_types.chat_rows_for state "alpha")))
;;

let test_unkeyed_output_is_not_replaced_by_a_role_match () =
  let output = entry_at 3. in
  let fresh = [entry_at 4.] in
  Alcotest.(check bool) "unkeyed replies retain their only available record" false
    (Tui_types.transcript_replaces_session_output ~fresh output);
  let memory = {output with me_role = Tui_types.Message_memory} in
  Alcotest.(check bool) "another memory pass cannot replace this pass" false
    (Tui_types.transcript_replaces_session_output
       ~fresh:[{(entry_at 4.) with me_role = Tui_types.Message_memory}] memory);
  Alcotest.(check bool) "an exact row identity proves replacement" true
    (Tui_types.transcript_replaces_session_output ~fresh:[memory] memory)
;;

let test_keeper_revisit_restores_read_pages_and_paging_authority () =
  let state = fresh_state () in
  state.msg_loaded <-
    [entry_at ~request_id:"alpha-old" 1.; entry_at ~request_id:"alpha-tail" 2.];
  state.msg_older_cursor <- Some 1.;
  state.msg_older_exist <- true;
  state.msg_loaded_dropped <- 2;
  state.msg_memory_dropped <- 1;
  state.msg_older_error <- Some "older page temporarily unavailable";
  state.msg_older_loading <- true;
  let alpha_rows = state.msg_loaded in
  let old_generation = state.msg_history_load_generation in
  Tui_types.restore_keeper_chat_page state "beta";
  Alcotest.(check int) "first visit has no rows from another Keeper" 0
    (List.length (Tui_types.chat_rows_for state "beta"));
  Alcotest.(check bool) "outgoing pagination request is not still loading" false
    state.msg_older_loading;
  state.msg_loaded_keeper <- Some "beta";
  state.msg_loaded <- [entry_at ~keeper:"beta" 10.];
  state.msg_older_cursor <- Some 10.;
  state.msg_older_exist <- false;
  Tui_types.restore_keeper_chat_page state "alpha";
  Alcotest.(check bool) "revisit restores the entire page reading" true
    (state.msg_loaded == alpha_rows);
  Alcotest.(check (option (float 0.001))) "exact older cursor returns"
    (Some 1.) state.msg_older_cursor;
  Alcotest.(check bool) "previous paging availability returns" true state.msg_older_exist;
  Alcotest.(check int) "unreadable history count stays attached to alpha" 2
    state.msg_loaded_dropped;
  Alcotest.(check int) "unreadable memory count stays attached to alpha" 1
    state.msg_memory_dropped;
  Alcotest.(check (option string)) "older page failure remains visible"
    (Some "older page temporarily unavailable") state.msg_older_error;
  Alcotest.(check bool) "late requests from the first alpha visit are invalid" true
    (state.msg_history_load_generation > old_generation);
  (* A failed refresh updates its failure notice and keeps the restored read.
     Switching away again must preserve that same reading and its notice. *)
  state.msg_loaded_error <- Some "server unavailable on revisit";
  Tui_types.restore_keeper_chat_page state "beta";
  Alcotest.(check (list string)) "beta keeps its own read" ["row at 10"]
    (texts (Tui_types.chat_rows_for state "beta"));
  Alcotest.(check bool) "beta's exhausted older window stays exhausted" false
    state.msg_older_exist;
  Tui_types.restore_keeper_chat_page state "alpha";
  Alcotest.(check (list string)) "outage does not erase previously read older rows"
    ["row at 1"; "row at 2"] (texts (Tui_types.chat_rows_for state "alpha"));
  Alcotest.(check (option string)) "outage remains visible on that Keeper"
    (Some "server unavailable on revisit") state.msg_loaded_error;
  let fresh = [entry_at ~request_id:"alpha-tail" 2.; entry_at ~request_id:"alpha-new" 3.] in
  state.msg_loaded <- Tui_types.merge_paged_history ~paged:state.msg_loaded ~fresh;
  Alcotest.(check (list string)) "recovery merges new rows and retains older pages"
    ["row at 1"; "row at 2"; "row at 3"]
    (texts (Tui_types.chat_rows_for state "alpha"))
;;

let () =
  Alcotest.run
    "tui chat rows memo"
    [ ( "memo",
        [ Alcotest.test_case "same inputs return the same list" `Quick
            test_same_inputs_return_the_same_list;
          Alcotest.test_case "refresh retains output until durable replacement" `Quick
            test_refresh_preserves_output_until_its_replacement_arrives;
          Alcotest.test_case "unkeyed output requires row identity" `Quick
            test_unkeyed_output_is_not_replaced_by_a_role_match;
          Alcotest.test_case "Keeper revisit preserves read pages through outage" `Quick
            test_keeper_revisit_restores_read_pages_and_paging_authority;
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
