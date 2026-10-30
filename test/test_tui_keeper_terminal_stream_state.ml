(* What the TUI keeps while the Terminal tab follows a Keeper's Execute output
   over its stream: when a stream is wanted, whose messages are taken, what a
   lost connection leaves on screen, and how the stream and the one-shot read
   of the same output share one cell.

   Nothing here opens a socket. The stream's messages are values the render
   loop is handed, and the state decides what each of them does. *)

module Terminal = Masc_tui_execute_terminal
module Tui_types = Masc_tui_types

let check = Alcotest.check

let keeper name : Tui_types.keeper =
  { k_origin = Masc.Tui_decode.Persisted_keeper
  ; k_name = name
  ; k_paused = false
  ; k_identity =
      Ok
        { k_trace_id = "trace-current"
        ; k_created_at = "2026-08-25T00:00:00Z"
        ; k_updated_at = "2026-08-25T00:00:00Z"
        }
  ; k_activity =
      Some
        { k_current_task_id = None
        ; k_total_turns = 0
        ; k_total_tokens = 0
        ; k_total_cost_usd = Keeper_cost_coverage.empty
        ; k_last_turn_ts = ""
        ; k_last_proactive_outcome = None
        }
  }

let server_identity : Masc.Tui_decode.server_identity =
  let module Decode = Masc.Tui_decode in
  { sid_version = "test"
  ; sid_binary_commit = "test"
  ; sid_binary_commit_age_s = None
  ; sid_base_path = Decode.Canonical_path.of_path "/owned-workspace"
  ; sid_masc_root = Decode.Canonical_path.of_path "/owned-workspace/.masc"
  ; sid_executable_in_worktree = None
  ; sid_state_ready = Some true
  ; sid_uptime = None
  ; sid_sse_clients = None
  ; sid_gc = None
  ; sid_scheduler = None
  }

let line seq text : Tui_types.keeper_execute_line =
  { kel_seq = seq
  ; kel_stream_id = Some 1
  ; kel_task_id = None
  ; kel_stream = "stdout"
  ; kel_text = text
  }

let reading_of texts : Tui_types.keeper_execute_reading =
  Keeper_execute_snapshot
    { kes_lines = List.mapi (fun index text -> line (index + 1) text) texts
    ; kes_active = []
    ; kes_lines_omitted = 0
    ; kes_first_seq = 1
    ; kes_active_count = 0
    ; kes_closed = true
    ; kes_status = `Null
    ; kes_observed_at = 0.
    }

(* The Terminal tab open on [analyst], in a workspace this terminal confirmed. *)
let terminal_state () =
  let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 () in
  state.workspace_identity <- Tui_types.Workspace_identity_match;
  state.server_identity <- Some server_identity;
  state.local_keepers <- Tui_types.Local_workspace_read;
  state.keepers <- [ keeper "analyst"; keeper "builder" ];
  state.keeper_cursor <- 0;
  state.view <- Tui_types.Keepers Keeper_detail;
  state.detail_tab <- Tui_types.Detail_terminal;
  state
;;

(* The job [reconcile_keeper_logs] would open for what is on screen. *)
let start_stream state =
  match Tui_types.keeper_terminal_stream_key state with
  | None -> Alcotest.fail "no stream is wanted on the Terminal tab"
  | Some key ->
    let job =
      { Tui_types.kxf_key = key
      ; kxf_reading = state.workspace_read_authority
      ; kxf_owner = ref ()
      }
    in
    let stopped = ref false in
    state.keeper_execute_stream <- Some (job, fun () -> stopped := true);
    job, stopped
;;

let texts_of (reading : Tui_types.keeper_execute_reading) =
  match reading with
  | Keeper_execute_none -> "none"
  | Keeper_execute_snapshot snapshot ->
    String.concat "," (List.map (fun (line : Tui_types.keeper_execute_line) -> line.kel_text) snapshot.kes_lines)
;;

let describe state =
  match Tui_types.keeper_execute_view state with
  | Masc_tui_fetched.Absent -> "absent"
  | Loading -> "loading"
  | Ready (reading, at) -> Printf.sprintf "ready [%s] at %.0f" (texts_of reading) at
  | Stale ((reading, at), detail) ->
    Printf.sprintf "stale [%s] at %.0f: %s" (texts_of reading) at (Tui_types.keeper_execute_failure_detail detail)
  | Failed detail -> "failed: " ^ Tui_types.keeper_execute_failure_detail detail
;;

let reading_message ~at texts = Tui_types.Execute_stream_reading (reading_of texts, at)

let test_a_stream_is_wanted_only_for_the_terminal_tab_of_a_confirmed_workspace () =
  let state = terminal_state () in
  let wanted () =
    Option.map
      (fun (key : Tui_types.keeper_log_key) -> key.klk_keeper, key.klk_limit)
      (Tui_types.keeper_terminal_stream_key state)
  in
  check
    Alcotest.(option (pair string int))
    "the Terminal tab"
    (Some ("analyst", Tui_types.keeper_terminal_window))
    (wanted ());
  state.keeper_cursor <- 1;
  check
    Alcotest.(option (pair string int))
    "the Keeper under the cursor"
    (Some ("builder", Tui_types.keeper_terminal_window))
    (wanted ());
  state.keeper_cursor <- 0;
  state.detail_tab <- Tui_types.Detail_info;
  check Alcotest.(option (pair string int)) "another tab" None (wanted ());
  state.detail_tab <- Tui_types.Detail_terminal;
  state.view <- Tui_types.Keepers Keeper_logs;
  check Alcotest.(option (pair string int)) "the logs view polls" None (wanted ());
  state.view <- Tui_types.Keepers Keeper_detail;
  state.workspace_identity <- Tui_types.Workspace_identity_unread;
  check Alcotest.(option (pair string int)) "a workspace not yet read" None (wanted ());
  state.workspace_identity <- Tui_types.Workspace_identity_match;
  state.server_identity <- None;
  check Alcotest.(option (pair string int)) "no identity to bind the stream to" None (wanted ())
;;

let test_the_current_stream_fills_the_cell () =
  let state = terminal_state () in
  let job, _ = start_stream state in
  check Alcotest.bool "a reading is taken" true
    (Tui_types.take_keeper_execute_stream state job (reading_message ~at:5. [ "a" ]));
  check Alcotest.string "and shown" "ready [a] at 5" (describe state);
  check Alcotest.bool "the next reading is taken" true
    (Tui_types.take_keeper_execute_stream state job (reading_message ~at:6. [ "a"; "b" ]));
  check Alcotest.string "and replaces it" "ready [a,b] at 6" (describe state)
;;

(* Opening the stream marks the cell as being read; the first reading must
   settle that, not be mistaken for the answer to a read already in flight. *)
let test_the_first_reading_settles_the_wait_the_opening_started () =
  let state = terminal_state () in
  let job, _ = start_stream state in
  (match
     Masc_tui_fetched.refresh ~equal:Tui_types.keeper_log_equal_key state.keeper_execute_output
       ~key:job.kxf_key
   with
   | Masc_tui_fetched.Started (next, _) -> state.keeper_execute_output <- next
   | Masc_tui_fetched.Already_loading -> Alcotest.fail "nothing was loading");
  check Alcotest.string "waiting" "loading" (describe state);
  check Alcotest.bool "the reading is taken" true
    (Tui_types.take_keeper_execute_stream state job (reading_message ~at:5. [ "first" ]));
  check Alcotest.string "and ends the wait" "ready [first] at 5" (describe state)
;;

let test_a_message_from_another_job_is_dropped () =
  let state = terminal_state () in
  let job, _ = start_stream state in
  ignore (Tui_types.take_keeper_execute_stream state job (reading_message ~at:5. [ "mine" ]));
  let other = { job with kxf_owner = ref () } in
  check Alcotest.bool "a job that is not the current one" false
    (Tui_types.take_keeper_execute_stream state other (reading_message ~at:9. [ "theirs" ]));
  check Alcotest.string "the cell is unchanged" "ready [mine] at 5" (describe state)
;;

let test_a_message_from_before_the_workspace_changed_is_dropped () =
  let state = terminal_state () in
  let job, _ = start_stream state in
  state.workspace_read_authority <- ref ();
  check Alcotest.bool "the reading it was opened under was left" false
    (Tui_types.take_keeper_execute_stream state job (reading_message ~at:5. [ "old workspace" ]));
  check Alcotest.string "nothing was read" "absent" (describe state)
;;

let test_a_message_for_output_the_tab_no_longer_shows_is_dropped () =
  let state = terminal_state () in
  let job, _ = start_stream state in
  state.keeper_cursor <- 1;
  check Alcotest.bool "another Keeper is under the cursor" false
    (Tui_types.take_keeper_execute_stream state job (reading_message ~at:5. [ "analyst's" ]));
  state.keeper_cursor <- 0;
  state.detail_tab <- Tui_types.Detail_info;
  check Alcotest.bool "the tab was left" false
    (Tui_types.take_keeper_execute_stream state job (reading_message ~at:5. [ "analyst's" ]));
  state.detail_tab <- Tui_types.Detail_terminal;
  state.view <- Tui_types.Keepers Keeper_logs;
  check Alcotest.bool "the logs view reads the same Keeper but is not the Terminal" false
    (Tui_types.take_keeper_execute_stream state job (reading_message ~at:5. [ "analyst's" ]));
  check Alcotest.string "nothing was read" "absent" (describe state)
;;

let test_a_lost_connection_keeps_the_last_reading_and_says_so () =
  let state = terminal_state () in
  let job, _ = start_stream state in
  ignore (Tui_types.take_keeper_execute_stream state job (reading_message ~at:5. [ "a" ]));
  check Alcotest.bool "the loss is taken" true
    (Tui_types.take_keeper_execute_stream state job (Tui_types.Execute_stream_down (Execute_stream_retrying "the server closed it")));
  check Alcotest.string "the reading stays, marked stale"
    "stale [a] at 5: the server closed it" (describe state);
  ignore (Tui_types.take_keeper_execute_stream state job (reading_message ~at:8. [ "a"; "b" ]));
  check Alcotest.string "a new connection's reading clears the mark" "ready [a,b] at 8" (describe state)
;;

let test_a_stream_that_never_connected_is_a_failure_not_an_empty_log () =
  let state = terminal_state () in
  let job, _ = start_stream state in
  ignore (Tui_types.take_keeper_execute_stream state job (Tui_types.Execute_stream_down (Execute_stream_stopped { reason = Http_status 401; detail = "refused (401)" })));
  check Alcotest.string "unavailable, with the reason" "failed: refused (401)" (describe state)
;;

let test_stopped_reasons_survive_with_and_without_a_reading () =
  List.iter (fun reason ->
    let state = terminal_state () in
    let job, _ = start_stream state in
    let stop () =
      ignore (Tui_types.take_keeper_execute_stream state job
        (Tui_types.Execute_stream_down (Execute_stream_stopped { reason; detail = "detail" }))) in
    stop ();
    (match Tui_types.keeper_execute_view state with
     | Masc_tui_fetched.Failed (Execute_stream_stopped { reason = actual; detail = "detail" })
       when actual = reason -> ()
     | _ -> Alcotest.fail "failure lost its typed cause");
    ignore (Tui_types.take_keeper_execute_stream state job (reading_message ~at:5. [ "a" ]));
    stop ();
    (match Tui_types.keeper_execute_view state with
     | Masc_tui_fetched.Stale ((_, 5.), Execute_stream_stopped { reason = actual; detail = "detail" })
       when actual = reason -> ()
     | _ -> Alcotest.fail "stale reading lost its typed cause"))
    [ Masc_tui_execute_stream_job.Http_status 401
    ; Unattested_response 204
    ; Unexpected_error ]
;;

let test_stopped_stream_keeps_its_owner_until_tab_reentry () =
  let state = terminal_state () in
  let job, stopped = start_stream state in
  ignore (Tui_types.take_keeper_execute_stream state job (reading_message ~at:5. [ "a" ]));
  ignore (Tui_types.take_keeper_execute_stream state job
    (Tui_types.Execute_stream_down (Execute_stream_stopped { reason = Http_status 401; detail = "refused" })));
  (match Tui_types.keeper_execute_view state with
   | Masc_tui_fetched.Stale ((_, 5.), Execute_stream_stopped { reason = Http_status 401; detail = "refused" }) -> ()
   | _ -> Alcotest.fail "stopped failure and last reading were not retained");
  (match Tui_types.plan_keeper_execute_stream state with
   | Stream_stays -> ()
   | _ -> Alcotest.fail "a stopped owner must not immediately reconnect");
  state.detail_tab <- Tui_types.Detail_info;
  (match Tui_types.plan_keeper_execute_stream state with
   | Stream_ends -> ()
   | _ -> Alcotest.fail "leaving the tab must retire the owner");
  check Alcotest.bool "the owner stopped" true (Tui_types.stop_keeper_execute_stream state);
  check Alcotest.bool "stop was requested" true !stopped;
  state.detail_tab <- Tui_types.Detail_terminal;
  (match Tui_types.plan_keeper_execute_stream state with
   | Stream_follows _ -> ()
   | _ -> Alcotest.fail "reentering must request a new owner");
  let replacement, _ = start_stream state in
  (match Masc_tui_fetched.refresh ~equal:Tui_types.keeper_log_equal_key
      state.keeper_execute_output ~key:replacement.kxf_key with
   | Started (next, _) -> state.keeper_execute_output <- next
   | Already_loading -> Alcotest.fail "replacement did not mark a new read");
  check Alcotest.bool "the replacement is in flight" true
    (Masc_tui_fetched.in_flight state.keeper_execute_output);
  check Alcotest.bool "old owner cannot update the cell" false
    (Tui_types.take_keeper_execute_stream state job (reading_message ~at:6. [ "old" ]));
  check Alcotest.bool "replacement can update the cell" true
    (Tui_types.take_keeper_execute_stream state replacement (reading_message ~at:7. [ "new" ]));
  check Alcotest.string "replacement clears the stopped state" "ready [new] at 7" (describe state)
;;

(* The cell has two writers: the one-shot read the logs view uses, and the
   stream. A poll that was out when the stream took over answers with what the
   server held earlier, and must not put that back over newer rows. *)
let test_a_poll_still_out_does_not_overwrite_a_newer_stream_reading () =
  let state = terminal_state () in
  let poll =
    match
      Tui_types.begin_keeper_execute_read state ~intent:Tui_types.Snapshot_read.Poll
        ~limit:Tui_types.keeper_terminal_window (keeper "analyst")
    with
    | Some request -> request
    | None -> Alcotest.fail "the poll did not start"
  in
  let job, _ = start_stream state in
  ignore (Tui_types.take_keeper_execute_stream state job (reading_message ~at:7. [ "newer" ]));
  check Alcotest.bool "the late answer is dropped" false
    (Tui_types.take_keeper_execute_read state poll (Ok (reading_of [ "older" ], 3.)));
  check Alcotest.string "the stream's reading stands" "ready [newer] at 7" (describe state)
;;

let test_stopping_the_stream_keeps_what_it_drew_and_retires_what_it_awaited () =
  let state = terminal_state () in
  let job, stopped = start_stream state in
  ignore (Tui_types.take_keeper_execute_stream state job (reading_message ~at:5. [ "a" ]));
  check Alcotest.bool "a stream was running" true (Tui_types.stop_keeper_execute_stream state);
  check Alcotest.bool "its owner was told to stop" true !stopped;
  check Alcotest.bool "none is registered" true (Option.is_none state.keeper_execute_stream);
  check Alcotest.string "the reading stays" "ready [a] at 5" (describe state);
  check Alcotest.bool "stopping again finds none" false (Tui_types.stop_keeper_execute_stream state);
  (* A stream that was opened and has said nothing leaves a read pending. *)
  let state = terminal_state () in
  let _job, _ = start_stream state in
  (match
     Masc_tui_fetched.refresh ~equal:Tui_types.keeper_log_equal_key state.keeper_execute_output
       ~key:(Option.get (Tui_types.keeper_terminal_stream_key state))
   with
   | Masc_tui_fetched.Started (next, _) -> state.keeper_execute_output <- next
   | Masc_tui_fetched.Already_loading -> Alcotest.fail "nothing was loading");
  check Alcotest.string "waiting for the first reading" "loading" (describe state);
  ignore (Tui_types.stop_keeper_execute_stream state);
  check Alcotest.bool "the wait ends with the stream" true
    (match Tui_types.keeper_execute_view state with
     | Masc_tui_fetched.Failed _ -> true
     | Absent | Loading | Ready _ | Stale _ -> false)
;;

(* Leaving the Terminal for the logs view starts the logs read in the key
   handler, and the loop stops the stream on its next pass. The logs read asks
   for another window of the same cell, and stopping the stream must not retire
   it. *)
let test_stopping_the_stream_leaves_a_read_for_another_window_waiting () =
  let state = terminal_state () in
  let _job, stopped = start_stream state in
  state.view <- Tui_types.Keepers Keeper_logs;
  (match
     Tui_types.begin_keeper_execute_read state ~intent:Tui_types.Snapshot_read.Poll ~limit:200
       (keeper "analyst")
   with
   | Some _ -> ()
   | None -> Alcotest.fail "the logs read did not start");
  check Alcotest.string "the logs read is out" "loading" (describe state);
  check Alcotest.bool "the stream was running" true (Tui_types.stop_keeper_execute_stream state);
  check Alcotest.bool "its owner was told to stop" true !stopped;
  check Alcotest.string "the logs read is still waiting" "loading" (describe state)
;;

let test_stopping_the_poll_says_whether_one_was_held () =
  let state = terminal_state () in
  check Alcotest.bool "none yet" false (Tui_types.stop_keeper_execute_poll state);
  ignore
    (Tui_types.begin_keeper_execute_read state ~intent:Tui_types.Snapshot_read.Poll
       ~limit:Tui_types.keeper_terminal_window (keeper "analyst"));
  let cancelled = ref false in
  state.keeper_execute_cancel <- Some (ref (), fun () -> cancelled := true);
  check Alcotest.bool "one was held" true (Tui_types.stop_keeper_execute_poll state);
  check Alcotest.bool "and told to stop" true !cancelled;
  check Alcotest.bool "then none is" false (Tui_types.stop_keeper_execute_poll state)
;;

let plan_name = function
  | Tui_types.Stream_stays -> "stays"
  | Stream_follows key -> "follows " ^ key.klk_keeper
  | Stream_ends -> "ends"

let plan state = plan_name (Tui_types.plan_keeper_execute_stream state)

(* The loop asks this on every pass; it is what turns the state into a stream
   that opens, stays, restarts or ends. *)
let test_the_plan_follows_what_the_tab_shows () =
  let state = terminal_state () in
  check Alcotest.string "a tab with no stream opens one" "follows analyst" (plan state);
  let job, stopped = start_stream state in
  check Alcotest.string "a stream for this Keeper stays" "stays" (plan state);
  check Alcotest.bool "asking does not stop it" false !stopped;
  state.keeper_cursor <- 1;
  check Alcotest.string "another Keeper under the cursor restarts it" "follows builder" (plan state);
  state.keeper_cursor <- 0;
  check Alcotest.string "and back again is the same stream" "stays" (plan state);
  state.workspace_read_authority <- ref ();
  check Alcotest.string "a stream opened before the workspace changed is not this one"
    "follows analyst" (plan state);
  ignore job;
  state.detail_tab <- Tui_types.Detail_info;
  check Alcotest.string "leaving the tab ends it" "ends" (plan state);
  state.keeper_execute_stream <- None;
  check Alcotest.string "nothing wanted and nothing running" "stays" (plan state)
;;

(* The hold freezes the reading on screen; the stream goes on replacing the
   live one under it. *)
let test_a_hold_stands_while_the_stream_goes_on () =
  let state = terminal_state () in
  let job, _ = start_stream state in
  ignore (Tui_types.take_keeper_execute_stream state job (reading_message ~at:5. [ "before" ]));
  Tui_types.move_keeper_terminal state ~by:2;
  ignore (Tui_types.take_keeper_execute_stream state job (reading_message ~at:6. [ "before"; "after" ]));
  let live = Tui_types.keeper_terminal_live state in
  (match Terminal.shown ~live (Tui_types.keeper_terminal_hold state) with
   | Some frozen -> check Alcotest.string "the reader still sees" "before" (texts_of frozen.ktf_reading)
   | None -> Alcotest.fail "nothing is shown");
  match live with
  | Some live -> check Alcotest.string "while the live reading moved on" "before,after" (texts_of live.ktf_reading)
  | None -> Alcotest.fail "there is no live reading"
;;

let () =
  Alcotest.run
    "tui_keeper_terminal_stream_state"
    [ ( "following the stream"
      , [ Alcotest.test_case
            "a stream is wanted only for the Terminal tab of a confirmed workspace"
            `Quick
            test_a_stream_is_wanted_only_for_the_terminal_tab_of_a_confirmed_workspace
        ; Alcotest.test_case "the current stream fills the cell" `Quick
            test_the_current_stream_fills_the_cell
        ; Alcotest.test_case "the first reading settles the wait the opening started" `Quick
            test_the_first_reading_settles_the_wait_the_opening_started
        ; Alcotest.test_case "a message from another job is dropped" `Quick
            test_a_message_from_another_job_is_dropped
        ; Alcotest.test_case "a message from before the workspace changed is dropped" `Quick
            test_a_message_from_before_the_workspace_changed_is_dropped
        ; Alcotest.test_case "a message for output the tab no longer shows is dropped" `Quick
            test_a_message_for_output_the_tab_no_longer_shows_is_dropped
        ; Alcotest.test_case "a lost connection keeps the last reading and says so" `Quick
            test_a_lost_connection_keeps_the_last_reading_and_says_so
        ; Alcotest.test_case "a stream that never connected is a failure, not an empty log" `Quick
            test_a_stream_that_never_connected_is_a_failure_not_an_empty_log
        ; Alcotest.test_case "stopped reasons survive with and without a reading" `Quick
            test_stopped_reasons_survive_with_and_without_a_reading
        ; Alcotest.test_case "a stopped stream is reopened only after tab reentry" `Quick
            test_stopped_stream_keeps_its_owner_until_tab_reentry
        ] )
    ; ( "starting and stopping"
      , [ Alcotest.test_case "the plan follows what the tab shows" `Quick
            test_the_plan_follows_what_the_tab_shows
        ] )
    ; ( "sharing the cell"
      , [ Alcotest.test_case "a poll still out does not overwrite a newer stream reading" `Quick
            test_a_poll_still_out_does_not_overwrite_a_newer_stream_reading
        ; Alcotest.test_case
            "stopping the stream keeps what it drew and retires what it awaited"
            `Quick
            test_stopping_the_stream_keeps_what_it_drew_and_retires_what_it_awaited
        ; Alcotest.test_case
            "stopping the stream leaves a read for another window waiting"
            `Quick
            test_stopping_the_stream_leaves_a_read_for_another_window_waiting
        ; Alcotest.test_case "stopping the poll says whether one was held" `Quick
            test_stopping_the_poll_says_whether_one_was_held
        ; Alcotest.test_case "a hold stands while the stream goes on" `Quick
            test_a_hold_stands_while_the_stream_goes_on
        ] )
    ]
;;
