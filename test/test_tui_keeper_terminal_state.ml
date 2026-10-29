(* What the TUI keeps for the Terminal tab, and when it lets go of it.

   The tab holds a reading still while the reader looks back through it. That
   reading is one Keeper's output, so the hold has to end when the tab is left,
   when another Keeper is chosen, and when the workspace stops being the one
   that was read. Nothing here looks at a screen: these are the values the
   state holds and the answers it gives. *)

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

let reading : Tui_types.keeper_execute_reading =
  Keeper_execute_snapshot
    { kes_lines = []
    ; kes_active = []
    ; kes_lines_omitted = 0
    ; kes_first_seq = 1
    ; kes_active_count = 0
    ; kes_closed = true
    ; kes_status = `Null
    ; kes_observed_at = 0.
    }

let window = 500

(* The Terminal tab open on [analyst], with one reading of its output in hand. *)
let state_with_reading () =
  let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 () in
  state.workspace_identity <- Tui_types.Workspace_identity_match;
  state.local_keepers <- Tui_types.Local_workspace_read;
  state.keepers <- [ keeper "analyst"; keeper "builder" ];
  state.keeper_cursor <- 0;
  state.view <- Tui_types.Keepers Keeper_detail;
  state.detail_tab <- Tui_types.Detail_terminal;
  (match
     Tui_types.begin_keeper_execute_read state ~intent:Tui_types.Snapshot_read.Poll ~limit:window
       (keeper "analyst")
   with
   | None -> Alcotest.fail "the Terminal tab did not start a read"
   | Some request ->
     check Alcotest.bool "the reading was taken" true
       (Tui_types.take_keeper_execute_read state request (Ok (reading, 1.))));
  state

let following = Alcotest.testable (fun ppf hold ->
    Fmt.string ppf (match (hold : Tui_types.keeper_terminal_frozen Terminal.hold) with
      | Following -> "following"
      | Paused { back; _ } -> Printf.sprintf "paused %d" back))
    (fun a b -> Terminal.back a = Terminal.back b
                && (match a, b with
                    | Terminal.Following, Terminal.Following -> true
                    | Paused _, Paused _ -> true
                    | Following, Paused _ | Paused _, Following -> false))

let hold state = Tui_types.keeper_terminal_hold state

let test_only_the_terminal_tab_reads_output_from_the_detail_view () =
  let state = state_with_reading () in
  let target () = Option.map (fun (k : Tui_types.keeper) -> k.k_name) (Tui_types.keeper_execute_target state) in
  check (Alcotest.option Alcotest.string) "the Terminal tab" (Some "analyst") (target ());
  state.detail_tab <- Tui_types.Detail_info;
  check (Alcotest.option Alcotest.string) "another detail tab" None (target ());
  state.detail_tab <- Tui_types.Detail_terminal;
  state.view <- Tui_types.Keepers Keeper_list;
  check (Alcotest.option Alcotest.string) "the Keeper list" None (target ())

(* The reason the view freezes: scrolling must not slide under the reader. *)
let test_scrolling_back_holds_the_reading_that_was_on_screen () =
  let state = state_with_reading () in
  check following "a new view follows" Terminal.Following (hold state);
  Tui_types.move_keeper_terminal state ~by:1;
  check Alcotest.int "one row back" 1 (Terminal.back (hold state));
  (match hold state with
   | Paused { frozen; _ } ->
     check Alcotest.string "the held reading is this Keeper's" "analyst" frozen.ktf_key.klk_keeper
   | Following -> Alcotest.fail "scrolling back did not hold the reading");
  Tui_types.move_keeper_terminal state ~by:(-1);
  check following "back to the bottom follows again" Terminal.Following (hold state)

(* A key that leaves the bottom, a wheel notch and Home all arrive as the
   frame's own report type, so that is where the reading gets held. *)
let test_a_report_past_the_bottom_holds_the_reading_on_screen () =
  let state = state_with_reading () in
  Tui_types.apply_clamped_scroll state (Tui_types.Keeper_terminal_scroll max_int);
  match hold state with
  | Paused { frozen; back } ->
    check Alcotest.int "as far back as asked" max_int back;
    check Alcotest.string "this Keeper's reading" "analyst" frozen.ktf_key.klk_keeper
  | Following -> Alcotest.fail "a report past the bottom did not hold the reading"

let test_the_frame_reports_how_far_back_it_could_go () =
  let state = state_with_reading () in
  Tui_types.move_keeper_terminal state ~by:50;
  Tui_types.apply_clamped_scroll state (Tui_types.Keeper_terminal_scroll 7);
  check Alcotest.int "the count the frame could draw" 7 (Terminal.back (hold state));
  Tui_types.apply_clamped_scroll state (Tui_types.Keeper_terminal_scroll 0);
  check following "a frame that fits everything follows" Terminal.Following (hold state)

let test_a_hold_is_for_the_keeper_it_was_taken_for () =
  let state = state_with_reading () in
  Tui_types.move_keeper_terminal state ~by:3;
  state.keeper_cursor <- 1;
  check following "another Keeper reads from the bottom" Terminal.Following (hold state);
  Tui_types.reconcile_keeper_terminal state;
  state.keeper_cursor <- 0;
  check following "and the first Keeper's hold is not revived by coming back"
    Terminal.Following (hold state)

let test_leaving_the_tab_ends_the_hold () =
  let state = state_with_reading () in
  Tui_types.move_keeper_terminal state ~by:3;
  state.detail_tab <- Tui_types.Detail_info;
  check following "another tab" Terminal.Following (hold state)

(* The logs view reads the same Execute output for the same Keeper, so it is
   the one place a hold could survive the tab by keeping its key. *)
let test_the_logs_view_does_not_keep_the_hold_either () =
  let state = state_with_reading () in
  Tui_types.move_keeper_terminal state ~by:3;
  state.view <- Tui_types.Keepers Keeper_logs;
  check following "the logs view is not the Terminal" Terminal.Following (hold state);
  Tui_types.reconcile_keeper_terminal state;
  state.view <- Tui_types.Keepers Keeper_detail;
  check following "coming back opens at the bottom" Terminal.Following (hold state)

let test_a_hold_does_not_outlive_the_workspace_it_was_read_from () =
  let state = state_with_reading () in
  Tui_types.move_keeper_terminal state ~by:3;
  state.workspace_identity <- Tui_types.Workspace_identity_unread;
  check following "an unread workspace" Terminal.Following (hold state)

let test_scrolling_before_anything_was_read_holds_nothing () =
  let state = Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 () in
  state.workspace_identity <- Tui_types.Workspace_identity_match;
  state.keepers <- [ keeper "analyst" ];
  state.view <- Tui_types.Keepers Keeper_detail;
  state.detail_tab <- Tui_types.Detail_terminal;
  Tui_types.move_keeper_terminal state ~by:3;
  check following "nothing to hold" Terminal.Following (hold state)

let () =
  Alcotest.run "tui_keeper_terminal_state"
    [ ( "terminal tab"
      , [ Alcotest.test_case "only the Terminal tab reads output from the detail view" `Quick
            test_only_the_terminal_tab_reads_output_from_the_detail_view
        ; Alcotest.test_case "scrolling back holds the reading that was on screen" `Quick
            test_scrolling_back_holds_the_reading_that_was_on_screen
        ; Alcotest.test_case "a report past the bottom holds the reading on screen" `Quick
            test_a_report_past_the_bottom_holds_the_reading_on_screen
        ; Alcotest.test_case "the frame reports how far back it could go" `Quick
            test_the_frame_reports_how_far_back_it_could_go
        ; Alcotest.test_case "a hold is for the Keeper it was taken for" `Quick
            test_a_hold_is_for_the_keeper_it_was_taken_for
        ; Alcotest.test_case "leaving the tab ends the hold" `Quick
            test_leaving_the_tab_ends_the_hold
        ; Alcotest.test_case "the logs view does not keep the hold either" `Quick
            test_the_logs_view_does_not_keep_the_hold_either
        ; Alcotest.test_case "a hold does not outlive the workspace it was read from" `Quick
            test_a_hold_does_not_outlive_the_workspace_it_was_read_from
        ; Alcotest.test_case "scrolling before anything was read holds nothing" `Quick
            test_scrolling_before_anything_was_read_holds_nothing
        ] )
    ]
