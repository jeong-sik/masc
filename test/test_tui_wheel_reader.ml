(* A wheel notch over an open reading moves that reading one row, the way j
   and k do. The frame only says which reading is on screen; the row comes
   from the state, because a trackpad sends several notches between two
   frames and each has to count. Moving from the frame's own reading, three
   notches in one read landed where two did. *)

open Masc_tui_types
open Masc_tui_render_prim

let make_state () = create_state ~workspace:"" ~port:0 ()

let notch state ~drawn direction =
  Option.iter (apply_clamped_scroll state)
    (reader_after_wheel (clamped_scroll_now state drawn)
       direction)

let test_readers_with_a_wheel_of_their_own_are_left_alone () =
  let state = make_state () in
  List.iter
    (fun drawn ->
      Alcotest.(check bool) "no reader step" true
        (Option.is_none
           (reader_after_wheel (clamped_scroll_now state drawn)
              Masc.Tui_mouse_protocol.Wheel_down)))
    [ Message_scroll {scroll=0; pin=None}; Board_read (0, 0); Keeper_detail 0
    ; Keeper_terminal_scroll 0 ]

let test_approval_wheel_moves_from_end_before_a_new_frame () =
  let state = make_state () in
  let viewport = { adv_count = 100; adv_height = 10; adv_presentation = Approval_text } in
  let drawn = Approval_detail_scroll (0, Some viewport) in
  state.approval_detail_scroll <- clamped_scroll_end;
  notch state ~drawn Masc.Tui_mouse_protocol.Wheel_up;
  Alcotest.(check int) "one row before the displayed end" 89 state.approval_detail_scroll;
  notch state ~drawn Masc.Tui_mouse_protocol.Wheel_down;
  notch state ~drawn Masc.Tui_mouse_protocol.Wheel_down;
  Alcotest.(check int) "repeated notches stay at the displayed end" 90 state.approval_detail_scroll

let () =
  Alcotest.run "tui_wheel_reader"
    [ ( "wheel over a reader"
      , [ Alcotest.test_case "readers with a wheel of their own are left alone"
            `Quick test_readers_with_a_wheel_of_their_own_are_left_alone
        ; Alcotest.test_case "approval wheel moves from End" `Quick
            test_approval_wheel_moves_from_end_before_a_new_frame
        ] )
    ]
