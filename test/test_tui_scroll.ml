(* The bound for a scrolled list, and what a keypress does inside it.

   These four lines were written out once per surface, and thirteen of those
   copies lived in the drawing: the key handler moved the scroll with no bound
   and the frame clamped it back on the way past. What that arrangement hid is
   the case below -- a scroll left stale by a list that shrank. *)

let check = Alcotest.check
let int = Alcotest.int

(* The bound is arithmetic on two numbers, and it used to be written out once
   per surface. A scroll left stale by a list that shrank is the case this
   module exists for: reading is safe on a stale value, moving is not. *)
let test_the_bound_holds_a_stale_scroll () =
  check int "a list longer than its window can scroll its overlap" 70
    (Masc_tui_scroll.maximum ~count:80 ~height:10);
  check int "a list shorter than its window cannot scroll" 0
    (Masc_tui_scroll.maximum ~count:5 ~height:10);
  check int "an empty list cannot scroll" 0
    (Masc_tui_scroll.maximum ~count:0 ~height:10);
  check int "a stale scroll reads back at the bound" 70
    (Masc_tui_scroll.normalize ~count:80 ~height:10 90);
  check int "a negative scroll reads back at the top" 0
    (Masc_tui_scroll.normalize ~count:80 ~height:10 (-3));
  check int "down from the middle moves one row" 6
    (Masc_tui_scroll.down ~count:80 ~height:10 5);
  check int "down stops at the bound" 70
    (Masc_tui_scroll.down ~count:80 ~height:10 70);
  check int "down from a stale scroll answers from the bound" 70
    (Masc_tui_scroll.down ~count:80 ~height:10 999);
  check int "up from the middle moves one row" 4
    (Masc_tui_scroll.up ~count:80 ~height:10 5);
  check int "up stops at the top" 0 (Masc_tui_scroll.up ~count:80 ~height:10 0);
  check int "up from a stale scroll answers from the bound" 70
    (Masc_tui_scroll.up ~count:81 ~height:10 999)

(* A page keeps one row from the window it leaves. A full height would put the
   row the reader stopped on just past the new edge, where nothing reports it. *)
let test_a_page_keeps_one_row_of_the_window_it_leaves () =
  check int "a page of a ten-row window" 9 (Masc_tui_scroll.page_step ~height:10);
  check int "a one-row window still moves a row" 1
    (Masc_tui_scroll.page_step ~height:1);
  check int "a window with no rows still moves a row" 1
    (Masc_tui_scroll.page_step ~height:0);
  check int "page down travels a page" 9
    (Masc_tui_scroll.page_down ~count:80 ~height:10 0);
  check int "page down stops at the bound" 70
    (Masc_tui_scroll.page_down ~count:80 ~height:10 65);
  check int "page down from a stale scroll answers from the bound" 70
    (Masc_tui_scroll.page_down ~count:80 ~height:10 999);
  check int "page up travels a page" 56
    (Masc_tui_scroll.page_up ~count:80 ~height:10 65);
  check int "page up stops at the top" 0
    (Masc_tui_scroll.page_up ~count:80 ~height:10 0);
  check int "page up from a stale scroll answers from the bound" 62
    (Masc_tui_scroll.page_up ~count:81 ~height:10 999)

(* A surface no listing counts has no bound below to hold the scroll at, but a
   negative scroll is not a position either: the frame indexes the list with it.
   The Git-changes overlay opened over the Keepers surface was unlisted, and one
   up-key from the top stored -1. *)
let test_an_uncounted_surface_holds_at_the_top () =
  check int "a down move on an uncounted surface travels" 8
    (Masc_tui_scroll.step_uncounted ~delta:3 5);
  check int "an up move from the top stays at the top" 0
    (Masc_tui_scroll.step_uncounted ~delta:(-1) 0)

(* The window follows the row the reader is on, and only as far as it must: a
   surface that snapped the window back would drag a tall item out from under
   the eye. *)
let test_the_window_follows_the_row_that_left_it () =
  check int "a row below the window brings the window down to it" 21
    (Masc_tui_scroll.ensure_visible ~cursor:30 ~height:10 0);
  check int "a row above the window brings the window up to it" 5
    (Masc_tui_scroll.ensure_visible ~cursor:5 ~height:10 21);
  check int "a row already in the window leaves the window alone" 21
    (Masc_tui_scroll.ensure_visible ~cursor:25 ~height:10 21);
  check int "the first row of a fresh window" 0
    (Masc_tui_scroll.ensure_visible ~cursor:0 ~height:10 0);
  check int "a run that left above the window starts the window at it" 3
    (Masc_tui_scroll.ensure_span_visible ~start:3 ~stop:4 ~height:5 10);
  check int "a run that left below the window ends the window at it" 16
    (Masc_tui_scroll.ensure_span_visible ~start:20 ~stop:25 ~height:5 10);
  check int "a run the window already shows leaves the window alone" 10
    (Masc_tui_scroll.ensure_span_visible ~start:12 ~stop:13 ~height:5 10)

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

(* The list and its preview split the rows a surface has. The split belongs
   here for the same reason the bound does: a renderer that shrank its own list
   while the key handler kept moving against the full height is what this half
   of the module was written to stop -- Changes drew ten rows and the keypress
   stopped at the bound for twenty, so the rows past that could not be reached.
   The list keeps its [keep] rows, and the preview never takes more than half. *)
let test_the_preview_never_takes_the_list_s_floor () =
  check int "the preview takes the smaller half of a tall surface" 10
    (Masc_tui_scroll.preview_height ~total:20 ~keep:6);
  check int "the list keeps its floor when the share would undercut it" 4
    (Masc_tui_scroll.preview_height ~total:10 ~keep:6);
  check int "a surface exactly the list's floor has no preview" 0
    (Masc_tui_scroll.preview_height ~total:6 ~keep:6);
  check int "a surface shorter than the floor has no preview" 0
    (Masc_tui_scroll.preview_height ~total:4 ~keep:6);
  check int "the list's half of a tall surface" 10
    (Masc_tui_scroll.body_height ~total:20 ~keep:6);
  check int "the list keeps its floor when the preview gives way" 6
    (Masc_tui_scroll.body_height ~total:10 ~keep:6);
  check int "a surface shorter than the floor leaves the list one row" 1
    (Masc_tui_scroll.body_height ~total:0 ~keep:0)

(* Fixed chrome, an optional preview and a conditional overflow row each take
   their declared rows before the list is handed its height. Every surface that
   wrote this sum by hand got a different answer. *)
let test_the_list_height_is_the_rows_that_are_left () =
  check int "fixed chrome is all that is taken" 20
    (Masc_tui_scroll.content_height ~rows:24 ~chrome:4 ~count:50
       ~preview_keep:None ~overflow_takes_row:false);
  check int "a preview splits what the chrome left" 10
    (Masc_tui_scroll.content_height ~rows:24 ~chrome:4 ~count:50
       ~preview_keep:(Some 6) ~overflow_takes_row:false);
  check int "an empty list keeps the preview's rows in the list" 20
    (Masc_tui_scroll.content_height ~rows:24 ~chrome:4 ~count:0
       ~preview_keep:(Some 6) ~overflow_takes_row:false);
  check int "an overflow row is taken off a list that overflows" 19
    (Masc_tui_scroll.content_height ~rows:24 ~chrome:4 ~count:50
       ~preview_keep:None ~overflow_takes_row:true);
  check int "an overflow row stays when the list fits" 20
    (Masc_tui_scroll.content_height ~rows:24 ~chrome:4 ~count:5
       ~preview_keep:None ~overflow_takes_row:true);
  check int "chrome taller than the surface leaves one row" 1
    (Masc_tui_scroll.content_height ~rows:3 ~chrome:10 ~count:5
       ~preview_keep:None ~overflow_takes_row:false)

(* Where a window stands in its list. Five surfaces wrote their own reading and
   three of them disagreed: Board and the Keeper call list said "rows 27-52 of
   80", the lane run panes said "27-52/80", and the detail pane showed its
   scroll offset over the offsets it could take -- a number no row on screen
   carried. *)
let test_the_window_reading_is_counted_from_one () =
  Alcotest.check Alcotest.string "a window in the middle of its list" "27-52/80"
    (Masc_tui_scroll.window_text ~scroll:26 ~height:26 80);
  Alcotest.check Alcotest.string "an empty list" "0/0"
    (Masc_tui_scroll.window_text ~scroll:0 ~height:10 0);
  Alcotest.check Alcotest.string "a surface with no rows to show them in" "0/5"
    (Masc_tui_scroll.window_text ~scroll:0 ~height:0 5);
  Alcotest.check Alcotest.string "a window past the end reads its last row"
    "10-10/10" (Masc_tui_scroll.window_text ~scroll:20 ~height:3 10);
  Alcotest.check Alcotest.string "the last window stops at the count" "6-10/10"
    (Masc_tui_scroll.window_text ~scroll:5 ~height:10 10);
  Alcotest.check Alcotest.string "the counted item is named" "rows 27-52/80"
    (Masc_tui_scroll.window_reading ~noun:"rows" ~scroll:26 ~height:26 80)

(* The position row is one builder: three surfaces wrote their own, each beside
   its own height sum, and one missing the overflow row would put the window's
   last row under the reading (#38744). Without a hint the row is drawn only
   when the rows overflow; with one there is always something to say. *)
let test_the_position_row_says_only_what_is_true () =
  let row ?hint ~scroll ~height count =
    Masc_tui_scroll.position_row ~scroll ~height ?hint count
  in
  Alcotest.check (Alcotest.option Alcotest.string)
    "an overflowing window carries its reading" (Some "  [lines 1-10/80]")
    (row ~scroll:0 ~height:10 80);
  Alcotest.check (Alcotest.option Alcotest.string)
    "a list that fits has nothing to say" None (row ~scroll:0 ~height:10 5);
  Alcotest.check (Alcotest.option Alcotest.string)
    "a hint alone is said" (Some "  esc closes")
    (row ~hint:"esc closes" ~scroll:0 ~height:10 5);
  Alcotest.check (Alcotest.option Alcotest.string)
    "the reading goes before the hint" (Some "  [lines 1-10/80]  esc closes")
    (row ~hint:"esc closes" ~scroll:0 ~height:10 80)

let () =
  Alcotest.run "tui_scroll"
    [ ( "bound"
      , [ Alcotest.test_case "the bound holds a stale scroll" `Quick
            test_the_bound_holds_a_stale_scroll
        ; Alcotest.test_case "a page keeps one row of the window it leaves"
            `Quick test_a_page_keeps_one_row_of_the_window_it_leaves
        ] )
    ; ( "moving"
      , [ Alcotest.test_case "an uncounted surface holds at the top" `Quick
            test_an_uncounted_surface_holds_at_the_top
        ; Alcotest.test_case "the window follows the row that left it" `Quick
            test_the_window_follows_the_row_that_left_it
        ] )
    ; ( "preview"
      , [ Alcotest.test_case "the preview never takes the list's floor" `Quick
            test_the_preview_never_takes_the_list_s_floor
        ] )
    ; ( "cursor"
      , [ Alcotest.test_case "the cursor stays inside the list" `Quick
            test_the_cursor_stays_inside_the_list
        ; Alcotest.test_case "a page-sized move travels its whole size" `Quick
            test_a_page_sized_move_travels_its_whole_size
        ; Alcotest.test_case "the edges are reachable in one move" `Quick
            test_the_edges_of_a_list_are_reachable_in_one_move
        ] )
    ; ( "layout"
      , [ Alcotest.test_case "the list height is the rows that are left" `Quick
            test_the_list_height_is_the_rows_that_are_left
        ; Alcotest.test_case "the window reading is counted from one" `Quick
            test_the_window_reading_is_counted_from_one
        ; Alcotest.test_case "the position row says only what is true" `Quick
            test_the_position_row_says_only_what_is_true
        ] )
    ; ( "position"
      , [] )
    ]
