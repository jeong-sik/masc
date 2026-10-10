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

let test_readers_with_a_wheel_of_their_own_are_left_alone () =
  let state = make_state () in
  List.iter
    (fun drawn ->
      Alcotest.(check bool) "no reader step" true
        (Option.is_none
           (reader_after_wheel (clamped_scroll_now state drawn)
              Masc.Tui_mouse_protocol.Wheel_down)))
    [ Message_scroll {scroll=0; pin=None}; Board_read (0, 0); Keeper_detail 0 ]

let () =
  Alcotest.run "tui_wheel_reader"
    [ ( "wheel over a reader"
      , [ Alcotest.test_case "readers with a wheel of their own are left alone"
            `Quick test_readers_with_a_wheel_of_their_own_are_left_alone
        ] )
    ]
