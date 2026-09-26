(* A wheel notch over an open reading moves that reading one row, the way j
   and k do. The frame only says which reading is on screen; the row comes
   from the state, because a trackpad sends several notches between two
   frames and each has to count. Moving from the frame's own reading, three
   notches in one read landed where two did. *)

open Masc_tui_types
open Masc_tui_render_prim

let make_state () = create_state ~workspace:"" ~port:0 ~refresh_interval:0. ()

let notch state ~drawn direction =
  Option.iter (apply_clamped_scroll state)
    (reader_after_wheel (clamped_scroll_now state drawn)
       direction)

let test_notches_between_two_frames_add_up () =
  let state = make_state () in
  state.memory_fact_detail_scroll <- 4;
  (* The one frame drawn before the burst reported the reading at row 4. *)
  let drawn = Memory_fact_detail_scroll 4 in
  List.iter (notch state ~drawn) Masc.Tui_decode.[ Wheel_down; Wheel_down; Wheel_down ];
  Alcotest.(check int) "three notches, three rows" 7 state.memory_fact_detail_scroll;
  notch state ~drawn Masc.Tui_decode.Wheel_up;
  Alcotest.(check int) "one back" 6 state.memory_fact_detail_scroll

let test_a_key_between_frames_is_not_undone () =
  let state = make_state () in
  let drawn = Task_detail 0 in
  (* j twice, as its arm does, then a notch before any frame. *)
  state.task_detail_scroll <- state.task_detail_scroll + 2;
  notch state ~drawn Masc.Tui_decode.Wheel_down;
  Alcotest.(check int) "the notch follows the keys" 3 state.task_detail_scroll

let test_the_top_holds () =
  let state = make_state () in
  notch state ~drawn:(Changes_diff_scroll 0) Masc.Tui_decode.Wheel_up;
  Alcotest.(check int) "no row above the first" 0 state.changes_diff_scroll

(* The chat and the Board read keep the wheel they had: the chat counts up
   from the newest message three rows a notch, and the Board read has a
   comment pane beside the post. *)
let test_readers_with_a_wheel_of_their_own_are_left_alone () =
  let state = make_state () in
  List.iter
    (fun drawn ->
      Alcotest.(check bool) "no reader step" true
        (Option.is_none
           (reader_after_wheel (clamped_scroll_now state drawn)
              Masc.Tui_decode.Wheel_down)))
    [ Message_scroll 0; Board_read 0; Keeper_detail 0 ]

let () =
  Alcotest.run "tui_wheel_reader"
    [ ( "wheel over a reader"
      , [ Alcotest.test_case "notches between two frames add up" `Quick
            test_notches_between_two_frames_add_up
        ; Alcotest.test_case "a key between frames is not undone" `Quick
            test_a_key_between_frames_is_not_undone
        ; Alcotest.test_case "the top holds" `Quick test_the_top_holds
        ; Alcotest.test_case "readers with a wheel of their own are left alone"
            `Quick test_readers_with_a_wheel_of_their_own_are_left_alone
        ] )
    ]
