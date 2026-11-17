(* When a fact block around the chat composer gives a row back.

   A block's height follows what it says, and what it says changes every few
   seconds while a turn runs. Held against the screen's shape, a row the last
   frame drew is kept, so the conversation above it does not move a row up
   and down. The block is measured again when the operator changes that
   shape, when no turn runs, and when the last frame drew something else. *)

open Alcotest
module Tui_types = Masc_tui_types

let fresh () =
  let state = Tui_types.create_state ~workspace:"test" ~port:8935 () in
  state.msg_target_keeper_name <- Some "polisher";
  state
;;

(* The frame of a tall terminal, so nothing but the hold decides the rows.
   [turn] says whether the frame draws a turn's progress row. *)
let frame ?(terminal_cols = 120) ?(turn = true) state ~wanted =
  Tui_types.keeper_message_frame_for_viewport ~status_block_rows:wanted
    ~progress_rows_of:(fun _ -> if turn then 1 else 0)
    state ~now:0. ~terminal_rows:60 ~terminal_cols
;;

(* What a key or a page measures: the frame, not drawn. *)
let measured ?terminal_cols ?turn state ~wanted =
  (frame ?terminal_cols ?turn state ~wanted).Tui_types.kmsf_status_block_rows
;;

(* What the renderer does: begin a frame, measure it, and say it drew it. *)
let drawn ?terminal_cols ?turn state ~wanted =
  Tui_types.keeper_message_rows_begin_frame ();
  let frame = frame ?terminal_cols ?turn state ~wanted in
  Tui_types.keeper_message_note_rows_drawn state frame;
  frame.Tui_types.kmsf_status_block_rows
;;

let test_a_block_keeps_the_rows_it_was_drawn_on () =
  let state = fresh () in
  check int "it takes what it wants" 3 (drawn state ~wanted:3);
  check int "it keeps a row it no longer needs" 3 (drawn state ~wanted:2);
  check int "it grows when it needs more" 4 (drawn state ~wanted:4);
  check int "and keeps that" 4 (drawn state ~wanted:1);
  check int "a key measures the rows on the screen" 4 (measured state ~wanted:1)
;;

let test_only_drawn_rows_are_kept () =
  let state = fresh () in
  ignore (drawn state ~wanted:2);
  check int "a key's frame asks for more" 5 (measured state ~wanted:5);
  check int "the next frame does not keep rows that were never drawn" 2 (drawn state ~wanted:2)
;;

let test_nothing_is_kept_without_a_turn () =
  let state = fresh () in
  ignore (drawn ~turn:false state ~wanted:5);
  check int "between turns" 2 (drawn ~turn:false state ~wanted:2);
  ignore (drawn state ~wanted:5);
  check int "once the turn's row is gone" 2 (drawn ~turn:false state ~wanted:2)
;;

let test_a_frame_that_drew_something_else_ends_the_hold () =
  let state = fresh () in
  ignore (drawn state ~wanted:5);
  (* Another view, or a panel over the chat: a frame that notes no rows. *)
  Tui_types.keeper_message_rows_begin_frame ();
  check int "back on the chat" 2 (drawn state ~wanted:2)
;;

let test_a_changed_screen_is_measured_again () =
  let state = fresh () in
  let reach () = ignore (drawn state ~wanted:5) in
  reach ();
  state.msg_target_keeper_name <- Some "archivist";
  check int "another Keeper" 2 (drawn state ~wanted:2);
  reach ();
  check int "another width" 2 (drawn ~terminal_cols:100 state ~wanted:2);
  reach ();
  state.msg_schedules_expanded <- not state.msg_schedules_expanded;
  check int "another view" 2 (drawn state ~wanted:2);
  reach ();
  (* The same Keeper, size and views on a state of its own. *)
  let other = fresh () in
  other.msg_target_keeper_name <- state.msg_target_keeper_name;
  other.msg_schedules_expanded <- state.msg_schedules_expanded;
  check int "another screen" 2 (drawn other ~wanted:2)
;;

let () =
  run "tui_chat_rows_held"
    [ ( "hold"
      , [ test_case "a block keeps the rows it was drawn on" `Quick
            test_a_block_keeps_the_rows_it_was_drawn_on
        ; test_case "only drawn rows are kept" `Quick test_only_drawn_rows_are_kept
        ; test_case "nothing is kept without a turn" `Quick
            test_nothing_is_kept_without_a_turn
        ; test_case "a frame that drew something else ends the hold" `Quick
            test_a_frame_that_drew_something_else_ends_the_hold
        ; test_case "a changed screen is measured again" `Quick
            test_a_changed_screen_is_measured_again
        ] )
    ]
;;
