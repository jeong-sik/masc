(* The bound for a scrolled list, and what a keypress does inside it.

   These four lines were written out once per surface, and thirteen of those
   copies lived in the drawing: the key handler moved the scroll with no bound
   and the frame clamped it back on the way past. What that arrangement hid is
   the case below -- a scroll left stale by a list that shrank. *)

let check = Alcotest.check
let int = Alcotest.int

let test_the_cursor_stays_inside_the_list () =
  check int "down stops at the last row" 3
    (Masc_tui_scroll.cursor_down ~count:4 3);
  check int "down from the middle" 2 (Masc_tui_scroll.cursor_down ~count:4 1);
  check int "up stops at the first row" 0 (Masc_tui_scroll.cursor_up ~count:4 0);
  check int "an empty list pins the cursor at zero" 0
    (Masc_tui_scroll.cursor_down ~count:0 5);
  check int "a stranded cursor steps from the last row" 2
    (Masc_tui_scroll.cursor_up ~count:4 9)

(* A page key hands the mover its own size. Before [cursor_move] existed the
   movers took a delta and read only its sign, so PageUp and PageDown moved a
   single row on every surface whose page routes through a cursor --
   Verification, Harness, Clients and the Git-changes list all read as j/k
   while their key tables said "page". *)
let test_a_page_sized_move_travels_its_whole_size () =
  check int "a page down travels the page" 20
    (Masc_tui_scroll.cursor_move ~count:100 ~delta:20 0);
  check int "a page up travels the page" 5
    (Masc_tui_scroll.cursor_move ~count:100 ~delta:(-20) 25);
  check int "a page past the end stops on the last row" 99
    (Masc_tui_scroll.cursor_move ~count:100 ~delta:20 90);
  check int "a page past the top stops on the first row" 0
    (Masc_tui_scroll.cursor_move ~count:100 ~delta:(-20) 5);
  check int "the steppers are this move by one" 6
    (Masc_tui_scroll.cursor_move ~count:100 ~delta:1 5);
  check int "a delta of nothing stays put" 5
    (Masc_tui_scroll.cursor_move ~count:100 ~delta:0 5);
  check int "an empty list pins the jump at zero" 0
    (Masc_tui_scroll.cursor_move ~count:0 ~delta:20 0);
  (* Same shrink rule the steppers have: a cursor stranded past the end of a
     list that shrank pages from the last row, not from the ghost. *)
  check int "a stranded cursor pages from the last row" 79
    (Masc_tui_scroll.cursor_move ~count:100 ~delta:(-20) 400)

(* What End lands on, and what Home lands on. A jump big enough to clear any
   list is how both are spelled, so the clamp is the whole contract. *)
let test_the_edges_of_a_list_are_reachable_in_one_move () =
  check int "the last row of a list" 99 (Masc_tui_scroll.cursor_last ~count:100);
  check int "an empty list has no row past zero" 0
    (Masc_tui_scroll.cursor_last ~count:0);
  check int "a one-row list begins and ends on the same row" 0
    (Masc_tui_scroll.cursor_last ~count:1);
  check int "End reaches the end from anywhere" 99
    (Masc_tui_scroll.cursor_move ~count:100 ~delta:100 0);
  check int "Home reaches the top from anywhere" 0
    (Masc_tui_scroll.cursor_move ~count:100 ~delta:(-100) 99)

let () =
  Alcotest.run "tui_scroll"
    [ ( "bound"
      , [] )
    ; ( "moving"
      , [] )
    ; ( "preview"
      , [] )
    ; ( "cursor"
      , [ Alcotest.test_case "the cursor stays inside the list" `Quick
            test_the_cursor_stays_inside_the_list
        ; Alcotest.test_case "a page-sized move travels its whole size" `Quick
            test_a_page_sized_move_travels_its_whole_size
        ; Alcotest.test_case "the edges are reachable in one move" `Quick
            test_the_edges_of_a_list_are_reachable_in_one_move
        ] )
    ; ( "layout"
      , [] )
    ; ( "position"
      , [] )
    ]
