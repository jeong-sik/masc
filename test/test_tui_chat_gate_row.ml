(** Effects the Keeper handed to the Gate and is not waiting on.

    A deferral returns successfully -- the call is done, the effect is not --
    so the tool row draws as an ordinary return and the Keeper carries on.
    Measured over 2026-09-01..03: 2,067 of 35,658 recorded calls were deferred,
    and in 872 of them the Keeper made further calls in the same turn. Nothing
    on the chat pane said an effect was still out.

    Two things have to hold together: the pane draws the row, and the row
    budget reserves it. A drawn row that nothing reserved pushes the composer
    past the bottom of the frame; a reserved row nothing draws leaves a blank
    line where history should be. *)

open Alcotest
module Tui_types = Masc_tui_types
(* Through the state module rather than the library: the field's type is what
   this test builds, and one path to it is one answer about what it is. *)
module Decode = Masc_tui_types.Tui_decode

let state () =
  Tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
;;

let pending ?(waiting_s = Some 90.) ?(phase = Decode.Gate_judging) ~keeper ~tool
    id : Decode.gate_pending =
  { gp_id = id
  ; gp_keeper = keeper
  ; gp_operation = "tool_execute"
  ; gp_display_tool = tool
  ; gp_input_preview = None
  ; gp_execution_cwd = None
  ; gp_execution_sandbox = None
  ; gp_waiting_s = waiting_s
  ; gp_phase = phase
  ; gp_auto_judge_detail = None
  ; gp_retry_request = None
  }
;;

(* The queue is the Gate's, not this keeper's. Counting another keeper's row
   would reserve a line the pane never draws, and the composer would sit one
   row below the caret. *)
let test_only_this_keepers_effects_count () =
  let state = state () in
  state.msg_target_keeper_name <- Some "polisher";
  (* Unfolded: the queue has a row of its own. Folded it is a count on the
     progress line, which [test_a_folded_turn_gives_the_queue_no_row] pins. *)
  state.msg_turn_folded <- false;
  let empty = Tui_types.keeper_message_status_rows state in
  state.gate_pending <-
    [ pending ~keeper:"archivist" ~tool:"Execute" "appr-1" ];
  check int "another keeper's effect reserves nothing" empty
    (Tui_types.keeper_message_status_rows state);
  check int "and is not this keeper's" 0
    (List.length
       (Tui_types.keeper_effects_at_the_gate state ~keeper_name:"polisher"));
  state.gate_pending <-
    [ pending ~keeper:"archivist" ~tool:"Execute" "appr-1"
    ; pending ~keeper:"polisher" ~tool:"WebFetch" "appr-2"
    ];
  check int "this keeper's effect reserves one row" (empty + 1)
    (Tui_types.keeper_message_status_rows state);
  check int "and only its own" 1
    (List.length
       (Tui_types.keeper_effects_at_the_gate state ~keeper_name:"polisher"))
;;

(* One row whatever the queue holds. The pane names as many effects as fit and
   truncates the rest, the way every other single-line status row does, so a
   queue that grew would otherwise reserve rows nobody drew. *)
let test_many_effects_still_reserve_one_row () =
  let state = state () in
  state.msg_target_keeper_name <- Some "polisher";
  state.msg_turn_folded <- false;
  let empty = Tui_types.keeper_message_status_rows state in
  state.gate_pending <-
    List.init 7 (fun index ->
      pending ~keeper:"polisher" ~tool:"Execute"
        (Printf.sprintf "appr-%d" index));
  check int "seven effects are still one row" (empty + 1)
    (Tui_types.keeper_message_status_rows state)
;;

(* With no chat target there is no keeper to attribute a row to, and the pane
   draws nothing. *)
let test_no_target_reserves_nothing () =
  let state = state () in
  state.msg_target_keeper_name <- None;
  let empty = Tui_types.keeper_message_status_rows state in
  state.gate_pending <- [ pending ~keeper:"polisher" ~tool:"Execute" "appr-1" ];
  check int "no target, no row" empty
    (Tui_types.keeper_message_status_rows state)
;;

(* The reservation and the drawing must read the same list. Two filters over
   [gate_pending] would be two answers to one question, and the one that
   disagreed would move the composer. *)
let test_the_pane_and_the_budget_read_one_list () =
  let count binding =
    Ast_grep.count_calls_in_value_binding
      ~module_path:"bin/masc_tui_render_chat.ml"
      ~binding_name:binding ~callee:"keeper_effects_at_the_gate"
  in
  check int "the chat pane asks the projection for the rows it draws" 1
    (count "render_keeper_message");
  check int "and the budget asks the same one" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:"bin/masc_tui_types.ml"
       ~binding_name:"keeper_message_status_rows"
       ~callee:"keeper_effects_at_the_gate");
  (* The fold gave the two readings a second way to disagree: the pane could
     draw every status row while the budget counted only the ones folding
     keeps. Both go through the one function that applies the fold, and the
     pane does not reach past it to the raw list. *)
  check int "the pane draws the folded list, not the raw one" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render_chat.ml"
       ~binding_name:"render_keeper_message"
       ~callee:"Masc_tui_types.keeper_message_visible_status_rows");
  check int "and does not read the unfolded list beside it" 0
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render_chat.ml"
       ~binding_name:"render_keeper_message"
       ~callee:"Keeper_chat_transcript.status_rows");
  check int "the budget counts that same folded list" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:"bin/masc_tui_types.ml"
       ~binding_name:"keeper_message_status_rows"
       ~callee:"keeper_message_visible_status_rows")
;;


(* Folded, the queue stops owning a row: the progress line carries "gate N"
   instead. The budget has to agree, or the pane reserves a line it never
   draws and the composer sits one row low -- the same failure the row this
   replaces was written for. *)
let test_a_folded_turn_gives_the_queue_no_row () =
  let state = state () in
  state.msg_target_keeper_name <- Some "polisher";
  state.msg_turn_folded <- true;
  let empty = Tui_types.keeper_message_status_rows state in
  state.gate_pending <-
    [ pending ~keeper:"polisher" ~tool:"WebFetch" "appr-1"
    ; pending ~keeper:"polisher" ~tool:"Execute" "appr-2"
    ];
  check int "a folded turn reserves no queue row" empty
    (Tui_types.keeper_message_status_rows state);
  check int "and the count the line reports is the queue's own" 2
    (List.length
       (Tui_types.keeper_effects_at_the_gate state ~keeper_name:"polisher"));
  state.msg_turn_folded <- false;
  check int "unfolded it takes its row back" (empty + 1)
    (Tui_types.keeper_message_status_rows state)
;;

let () =
  run "tui chat gate row"
    [ ( "attribution"
      , [ test_case "only this keeper's effects count" `Quick
            test_only_this_keepers_effects_count
        ; test_case "no target reserves nothing" `Quick
            test_no_target_reserves_nothing
        ] )
    ; ( "row budget"
      , [ test_case "many effects still reserve one row" `Quick
            test_many_effects_still_reserve_one_row
        ; test_case "the pane and the budget read one list" `Quick
            test_the_pane_and_the_budget_read_one_list
        ; test_case "a folded turn gives the queue no row" `Quick
            test_a_folded_turn_gives_the_queue_no_row
        ] )
    ]
;;
