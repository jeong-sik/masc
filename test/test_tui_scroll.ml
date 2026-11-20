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
  check int "page up from a stale scroll answers from the bound one page back" 62
    (Masc_tui_scroll.page_up ~count:81 ~height:10 999)

let key_move_t =
  Alcotest.testable
    (fun ppf move ->
      Format.pp_print_string ppf
        (match move with
         | Masc_tui_scroll.Line_down -> "Line_down"
         | Masc_tui_scroll.Line_up -> "Line_up"
         | Masc_tui_scroll.Page_down -> "Page_down"
         | Masc_tui_scroll.Page_up -> "Page_up"
         | Masc_tui_scroll.To_top -> "To_top"
         | Masc_tui_scroll.To_end -> "To_end"))
    ( = )

(* The cheat sheet, the agenda and the context reader each matched their own
   key names, and no two agreed on Home, End or the size of a page. One table
   names the keys; Home and g are the same key to a reader, so are End and G. *)
let test_a_key_names_one_move () =
  let key name expected =
    check (Alcotest.option key_move_t) (Printf.sprintf "key %S" name) expected
      (Masc_tui_scroll.move_of_key name)
  in
  key "j" (Some Masc_tui_scroll.Line_down);
  key "down" (Some Masc_tui_scroll.Line_down);
  key "k" (Some Masc_tui_scroll.Line_up);
  key "up" (Some Masc_tui_scroll.Line_up);
  key "pagedown" (Some Masc_tui_scroll.Page_down);
  key "pageup" (Some Masc_tui_scroll.Page_up);
  key "g" (Some Masc_tui_scroll.To_top);
  key "home" (Some Masc_tui_scroll.To_top);
  key "G" (Some Masc_tui_scroll.To_end);
  key "end" (Some Masc_tui_scroll.To_end);
  key "x" None;
  key "enter" None;
  key "" None

let test_a_move_travels_as_far_as_its_mover () =
  let apply ?(count = 80) move scroll =
    Masc_tui_scroll.apply_move ~count ~height:10 move scroll
  in
  check int "a line down" 6 (apply Masc_tui_scroll.Line_down 5);
  check int "a line up" 4 (apply Masc_tui_scroll.Line_up 5);
  check int "a page down keeps one row of the window it leaves" 14
    (apply Masc_tui_scroll.Page_down 5);
  check int "a page up keeps one row of the window it leaves" 11
    (apply Masc_tui_scroll.Page_up 20);
  check int "a page forward and back lands where it started" 20
    (apply Masc_tui_scroll.Page_up (apply Masc_tui_scroll.Page_down 20));
  check int "the top is the first row" 0 (apply Masc_tui_scroll.To_top 40);
  check int "the end is the last scroll that still shows content" 70
    (apply Masc_tui_scroll.To_end 0);
  check int "a list shorter than its window has no end to scroll to" 0
    (apply ~count:5 Masc_tui_scroll.To_end 0);
  check int "a stale scroll answers from the bound" 70
    (apply Masc_tui_scroll.Line_down 999)

(* A surface no listing counts has no bound below to hold the scroll at, but a
   negative scroll is not a position either: the frame indexes the list with it.
   The Git-changes overlay opened over the Keepers surface was unlisted, and one
   up-key from the top stored -1. *)
let test_an_uncounted_surface_holds_at_the_top () =
  check int "a down move on an uncounted surface travels" 8
    (Masc_tui_scroll.step_uncounted ~delta:3 5);
  check int "an up move from the top stays at the top" 0
    (Masc_tui_scroll.step_uncounted ~delta:(-1) 0);
  check int "a page up that overshoots the top stops at it" 0
    (Masc_tui_scroll.step_uncounted ~delta:(-9) 4)

(* A reader's page is the page a list keeps. Each reader used to be handed
   [By height] and add the whole window, so readers and lists disagreed by a
   row. [Position.move] now takes the page itself, and for every scroll, count
   and height it lands where [page_down] and [page_up] land. *)
let test_a_reading_page_is_the_page_a_list_keeps () =
  let module Position = Masc_tui_scroll.Position in
  let misses = ref [] in
  for height = 0 to 12 do
    for count = 0 to 30 do
      for start = 0 to 30 do
        let landed movement =
          Position.offset ~count ~height (Position.move ~count ~height movement (Position.at start)) in
        let note name expected got =
          if expected <> got then
            misses := Printf.sprintf "%s count %d height %d from %d: %d, not %d" name count height start got expected :: !misses in
        note "page down" (Masc_tui_scroll.page_down ~count ~height start) (landed Position.Page_down);
        note "page up" (Masc_tui_scroll.page_up ~count ~height start) (landed Position.Page_up)
      done
    done
  done;
  Alcotest.(check (list string)) "a reader's page and a list's page agree" [] !misses;
  check int "a page down from the end anchor stays at the end" 90
    (Position.offset ~count:100 ~height:10
       (Position.move ~count:100 ~height:10 Position.Page_down
          (Position.move ~count:100 ~height:10 Position.Last Position.first)));
  check int "a page up from the end anchor leaves it by a page" 81
    (Position.offset ~count:100 ~height:10
       (Position.move ~count:100 ~height:10 Position.Page_up
          (Position.move ~count:100 ~height:10 Position.Last Position.first)))

(* End stores [max_int] on a reader the frame clamps, and the key that follows
   before the frame has drawn adds a page to it. The sum wrapped negative and
   the [max 0] threw the reader to the top. *)
let test_a_step_forward_from_the_end_value_stays_there () =
  check int "a row from the value End stores" max_int
    (Masc_tui_scroll.step_uncounted ~delta:1 max_int);
  check int "a page from the value End stores" max_int
    (Masc_tui_scroll.step_uncounted ~delta:9 max_int);
  check int "a page from just under it stops at it" max_int
    (Masc_tui_scroll.step_uncounted ~delta:9 (max_int - 3));
  check int "a page that just reaches it lands on it" max_int
    (Masc_tui_scroll.step_uncounted ~delta:9 (max_int - 9));
  check int "a page back from the value End stores leaves it" (max_int - 9)
    (Masc_tui_scroll.step_uncounted ~delta:(-9) max_int)

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
  check int "a run taller than the window ends the window at its first row" 16
    (Masc_tui_scroll.ensure_span_visible ~start:20 ~stop:25 ~height:5 10);
  check int "a run the window already shows leaves the window alone" 10
    (Masc_tui_scroll.ensure_span_visible ~start:12 ~stop:13 ~height:5 10);
  check int "a run that fits and ends under the window ends the window at its last row" 11
    (Masc_tui_scroll.ensure_span_visible ~start:14 ~stop:15 ~height:5 10);
  check int "a run that fits and starts above the window starts the window at it" 9
    (Masc_tui_scroll.ensure_span_visible ~start:9 ~stop:10 ~height:5 10)

(* A row that opens a group brings the group's heading with it. The heading is
   no row the cursor can name, so following the row alone left it above the
   window whenever the cursor stood on the first row of a group. *)
let test_a_row_that_opens_a_group_keeps_its_heading_in_the_window () =
  let follow = Masc_tui_scroll.ensure_visible_with_lead ~lead:1 ~height:4 in
  check int "a row above the window brings its heading up with it" 4
    (follow ~cursor:5 7);
  check int "a window that shows only the row moves up to show the heading" 4
    (follow ~cursor:5 5);
  check int "a window that shows both leaves the window alone" 3
    (follow ~cursor:5 3);
  check int "a row below the window comes down with its heading on screen" 3
    (follow ~cursor:6 0);
  check int "the first group's heading at the top of the list" 0
    (follow ~cursor:1 7);
  check int "no lead moves the window as ensure_visible does"
    (Masc_tui_scroll.ensure_visible ~cursor:30 ~height:10 0)
    (Masc_tui_scroll.ensure_visible_with_lead ~cursor:30 ~lead:0 ~height:10 0);
  check int "a window of one row follows the row alone" 5
    (Masc_tui_scroll.ensure_visible_with_lead ~cursor:5 ~lead:1 ~height:1 9);
  check int "a lead taller than the window keeps the row on screen" 3
    (Masc_tui_scroll.ensure_visible_with_lead ~cursor:6 ~lead:9 ~height:4 0)

(* Rows of different heights: the Keepers views draw a second line under a
   failing Keeper alone. The window is counted in lines, and the scroll and
   the rows drawn are counted in items. *)
let test_a_window_of_uneven_rows_shows_the_cursor_whole () =
  let window = Alcotest.(pair int int) in
  let window_of = Masc_tui_scroll.window_of_heights in
  check window "rows of one line move as ensure_visible moves them" (21, 10)
    (window_of ~heights:(List.init 40 (fun _ -> 1)) ~cursor:30 ~rows:10 0);
  check window "the window comes down until the tall row below it fits whole" (2, 3)
    (window_of ~heights:[ 1; 2; 1; 1; 2; 1 ] ~cursor:4 ~rows:4 0);
  check window "a row already in the window leaves the window alone" (2, 3)
    (window_of ~heights:[ 1; 2; 1; 1; 2; 1 ] ~cursor:3 ~rows:4 2);
  check window "a tall row at the end brings the window down to fit it" (1, 3)
    (window_of ~heights:[ 2; 1; 1; 2 ] ~cursor:3 ~rows:4 0);
  check window "a scroll past the last full window comes back to it" (2, 3)
    (window_of ~heights:[ 1; 1; 1; 1; 1 ] ~cursor:4 ~rows:3 4);
  check window "a row above the window brings the window up to it" (1, 2)
    (window_of ~heights:[ 1; 1; 2; 1 ] ~cursor:1 ~rows:3 3);
  check window "a cursor taller than the window starts it and draws nothing" (1, 0)
    (window_of ~heights:[ 1; 3; 1 ] ~cursor:1 ~rows:2 0);
  check window "a cursor past the end names the last row" (1, 2)
    (window_of ~heights:[ 1; 1; 1 ] ~cursor:7 ~rows:2 0);
  check window "a cursor before the start names the first row" (0, 2)
    (window_of ~heights:[ 1; 1; 1 ] ~cursor:(-3) ~rows:2 1);
  check window "a negative scroll is the top" (0, 2)
    (window_of ~heights:[ 1; 1; 1; 1 ] ~cursor:1 ~rows:2 (-5));
  check window "an empty list" (0, 0) (window_of ~heights:[] ~cursor:0 ~rows:5 3);
  check window "a window of no lines" (0, 0) (window_of ~heights:[ 1; 1 ] ~cursor:1 ~rows:0 0)

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

(* Fixed chrome and an optional preview each take their declared rows before
   the list is handed its height. Every surface that wrote this sum by hand got
   a different answer. A list that hides rows keeps all of them: where it
   stands is on the title row (RFC tui-one-screen-grammar, section 2). *)
let test_the_list_height_is_the_rows_that_are_left () =
  check int "fixed chrome is all that is taken" 20
    (Masc_tui_scroll.content_height ~rows:24 ~chrome:4 ~count:50
       ~preview_keep:None);
  check int "a preview splits what the chrome left" 10
    (Masc_tui_scroll.content_height ~rows:24 ~chrome:4 ~count:50
       ~preview_keep:(Some 6));
  check int "an empty list keeps the preview's rows in the list" 20
    (Masc_tui_scroll.content_height ~rows:24 ~chrome:4 ~count:0
       ~preview_keep:(Some 6));
  check int "a list that fits is handed the same rows" 20
    (Masc_tui_scroll.content_height ~rows:24 ~chrome:4 ~count:5
       ~preview_keep:None);
  check int "chrome taller than the surface leaves one row" 1
    (Masc_tui_scroll.content_height ~rows:3 ~chrome:10 ~count:5
       ~preview_keep:None)

(* Every move key over a cursor, for an empty list, a list of one and a
   list of six, from the first row, a middle row and the last row. The
   expected rows are written out rather than derived, so the table is the
   specification of RFC tui-one-screen-grammar §3.1 for cursors. *)
let test_every_move_key_lands_inside_the_list () =
  let open Masc_tui_scroll in
  let open Cursor_move in
  let cases =
    (* count, move, from, expected *)
    [ 0, Line_down, 0, 0; 0, Line_up, 0, 0; 0, Page_down 2, 0, 0
    ; 0, Page_up 2, 0, 0; 0, To_top, 0, 0; 0, To_end, 0, 0
    ; 1, Line_down, 0, 0; 1, Line_up, 0, 0; 1, Page_down 2, 0, 0
    ; 1, Page_up 2, 0, 0; 1, To_top, 0, 0; 1, To_end, 0, 0
    ; 6, Line_down, 0, 1; 6, Line_up, 0, 0; 6, Page_down 2, 0, 2
    ; 6, Page_up 2, 0, 0; 6, To_top, 0, 0; 6, To_end, 0, 5
    ; 6, Line_down, 3, 4; 6, Line_up, 3, 2; 6, Page_down 2, 3, 5
    ; 6, Page_up 2, 3, 1; 6, To_top, 3, 0; 6, To_end, 3, 5
    ; 6, Line_down, 5, 5; 6, Line_up, 5, 4; 6, Page_down 2, 5, 5
    ; 6, Page_up 2, 5, 3; 6, To_top, 5, 0; 6, To_end, 5, 5
    (* A page longer than the list holds at the ends. *)
    ; 6, Page_down 9, 1, 5; 6, Page_up 9, 4, 0
    (* A page of zero rows still moves one row. *)
    ; 6, Page_down 0, 1, 2; 6, Page_up 0, 1, 0
    (* A cursor left past the end by a list that shrank answers from the
       last row. *)
    ; 3, Line_up, 7, 1; 3, Line_down, 7, 2
    ]
  in
  List.iter
    (fun (count, move, from, expected) ->
      Alcotest.(check int)
        (Printf.sprintf "count %d from %d" count from)
        expected (cursor_apply ~count move from))
    cases

(* A list of items of different heights pages by the fewest items any
   window holds whole. From every cursor in every window the list can stand
   in, after PgDn the item that was last whole on screen is still whole on
   it, and after PgUp the item that was first. The window follows the cursor
   the way the Keeper list's does ([window_of_heights]). A page of the items
   this window holds passes one when the next window holds fewer: two short
   items and then tall ones. *)
let test_a_page_of_uneven_items_passes_none () =
  let open Masc_tui_scroll in
  let shows ~heights ~rows ~cursor scroll item =
    let first, count = window_of_heights ~heights ~cursor ~rows scroll in
    item >= first && item < first + count
  in
  List.iter
    (fun (heights, rows) ->
      let count = List.length heights in
      let page = page_step ~height:(items_always_shown ~heights ~rows) in
      for scroll = 0 to count - 1 do
        for cursor = 0 to count - 1 do
          let first, held = window_of_heights ~heights ~cursor ~rows scroll in
          (* Only the windows a reader can stand in: the cursor's item is on
             screen in it. *)
          if held > 0 && first = scroll && cursor >= first && cursor < first + held then begin
            let label key kept =
              Printf.sprintf "%d items in %d rows, cursor %d, window %d: %s keeps item %d"
                count rows cursor scroll key kept
            in
            let down = cursor_apply ~count (Cursor_move.Page_down page) cursor in
            let last = first + held - 1 in
            Alcotest.(check bool) (label "PgDn" last) true
              (shows ~heights ~rows ~cursor:down first last);
            let up = cursor_apply ~count (Cursor_move.Page_up page) cursor in
            Alcotest.(check bool) (label "PgUp" first) true
              (shows ~heights ~rows ~cursor:up first first)
          end
        done
      done)
    [ [ 1; 1; 3; 3; 3; 1; 1; 1 ], 6
    ; [ 1; 2; 1; 2; 1; 2; 1; 2; 1 ], 5
    ; [ 2; 2; 2; 2; 2; 2 ], 7
    ; [ 1; 1; 1; 1; 1; 1; 1; 1; 1; 1 ], 4
    ; [ 0; 1; 1; 2; 1; 1; 2; 2; 1 ], 4 ];
  Alcotest.(check int) "an item taller than the window pages by one" 1
    (items_always_shown ~heights:[ 1; 9; 1 ] ~rows:4);
  Alcotest.(check int) "a list that fits pages by every item" 3
    (items_always_shown ~heights:[ 1; 1; 1 ] ~rows:10);
  Alcotest.(check int) "two short items then tall ones" 1
    (items_always_shown ~heights:[ 1; 1; 3; 3 ] ~rows:4)

let test_wheel_or_key_move_and_cursor_conversion () =
  let key ?vim_edges name expected =
    check (Alcotest.option key_move_t) (Printf.sprintf "key %S" name) expected
      (Masc_tui_scroll.wheel_or_key_move ?vim_edges name)
  in
  key "wheel-down" (Some Masc_tui_scroll.Line_down);
  key "wheel-up" (Some Masc_tui_scroll.Line_up);
  key "g" (Some Masc_tui_scroll.To_top);
  key "G" (Some Masc_tui_scroll.To_end);
  key ~vim_edges:false "g" None;
  key ~vim_edges:false "G" None;
  key ~vim_edges:false "home" (Some Masc_tui_scroll.To_top);
  key ~vim_edges:false "end" (Some Masc_tui_scroll.To_end);
  key ~vim_edges:false "pagedown" (Some Masc_tui_scroll.Page_down);
  key ~vim_edges:false "pageup" (Some Masc_tui_scroll.Page_up);
  check int "cursor_move_of_key_move uses page" 9
    (Masc_tui_scroll.cursor_apply ~count:30
       (Masc_tui_scroll.cursor_move_of_key_move ~page:9 Masc_tui_scroll.Page_down) 0);
  check int "cursor_move_of_key_move floors page to 1" 1
    (Masc_tui_scroll.cursor_apply ~count:30
       (Masc_tui_scroll.cursor_move_of_key_move ~page:0 Masc_tui_scroll.Page_down) 0)

let test_visible_target_for_scroll () =
  let snap ~targets ~scroll ~height ~current move =
    Masc_tui_scroll.visible_target_for_scroll ~targets ~scroll ~height ~current move
  in
  let dense = List.init 40 Fun.id in
  check (Alcotest.option int) "dense list PgDn from top lands on overlap row"
    (Some 9) (snap ~targets:dense ~scroll:9 ~height:10 ~current:(Some 0) Masc_tui_scroll.Page_down);
  check (Alcotest.option int) "dense list PgDn from middle keeps relative row"
    (Some 14) (snap ~targets:dense ~scroll:9 ~height:10 ~current:(Some 5) Masc_tui_scroll.Page_down);
  check (Alcotest.option int) "dense list PgUp undoes PgDn"
    (Some 5) (snap ~targets:dense ~scroll:0 ~height:10 ~current:(Some 14) Masc_tui_scroll.Page_up);
  (* Short modal where scroll stays at 0: PgDn/PgUp still reach edges. *)
  let short_targets = [ 2; 4; 6 ] in
  check (Alcotest.option int) "short modal PgDn advances to last visible target"
    (Some 6) (snap ~targets:short_targets ~scroll:0 ~height:10 ~current:(Some 2) Masc_tui_scroll.Page_down);
  check (Alcotest.option int) "short modal PgUp returns to first visible target"
    (Some 2) (snap ~targets:short_targets ~scroll:0 ~height:10 ~current:(Some 6) Masc_tui_scroll.Page_up);
  (* Mixed modal with top non-selectable prose: scrolling to top yields None. *)
  let mixed_targets = [ 15; 17; 19; 22; 25 ] in
  check (Alcotest.option int) "top prose window without targets yields None"
    None (snap ~targets:mixed_targets ~scroll:0 ~height:10 ~current:None Masc_tui_scroll.To_top);
  check (Alcotest.option int) "PgDn from prose snaps to first visible target"
    (Some 15) (snap ~targets:mixed_targets ~scroll:9 ~height:10 ~current:None Masc_tui_scroll.Page_down);
  check (Alcotest.option int) "PgDn again advances to visible target near desired"
    (Some 25) (snap ~targets:mixed_targets ~scroll:16 ~height:10 ~current:(Some 15) Masc_tui_scroll.Page_down);
  check (Alcotest.option int) "PgUp back into top prose clears off-screen selection"
    None (snap ~targets:mixed_targets ~scroll:0 ~height:10 ~current:(Some 15) Masc_tui_scroll.Page_up);
  check (Alcotest.option int) "To_end picks last visible target"
    (Some 25) (snap ~targets:mixed_targets ~scroll:16 ~height:10 ~current:None Masc_tui_scroll.To_end);
  check (Alcotest.option int) "To_top with visible targets picks first visible"
    (Some 2) (snap ~targets:short_targets ~scroll:0 ~height:10 ~current:(Some 6) Masc_tui_scroll.To_top);
  check (Alcotest.option int) "zero height yields None"
    None (snap ~targets:short_targets ~scroll:0 ~height:0 ~current:(Some 2) Masc_tui_scroll.Page_down);
  check (Alcotest.option int) "scroll=max_int does not overflow"
    None (snap ~targets:short_targets ~scroll:max_int ~height:10 ~current:None Masc_tui_scroll.To_end);
  check (Alcotest.option int) "negative scroll normalizes to 0"
    (Some 2) (snap ~targets:short_targets ~scroll:(-5) ~height:10 ~current:None Masc_tui_scroll.To_top);
  check (Alcotest.option int) "prev=max_int on Page_down saturates without overflow"
    (Some 6) (snap ~targets:short_targets ~scroll:0 ~height:10 ~current:(Some max_int) Masc_tui_scroll.Page_down)

let () =
  Alcotest.run "tui_scroll"
    [ ( "bound"
      , [ Alcotest.test_case "the bound holds a stale scroll" `Quick
            test_the_bound_holds_a_stale_scroll
        ; Alcotest.test_case "a page keeps one row of the window it leaves"
            `Quick test_a_page_keeps_one_row_of_the_window_it_leaves
        ; Alcotest.test_case "a key names one move" `Quick test_a_key_names_one_move
        ; Alcotest.test_case "wheel and vim-edge opt-out share key moves" `Quick
            test_wheel_or_key_move_and_cursor_conversion
        ; Alcotest.test_case "a move travels as far as its mover" `Quick
            test_a_move_travels_as_far_as_its_mover
        ; Alcotest.test_case "mixed-modal scroll snaps cursor to visible target"
            `Quick test_visible_target_for_scroll
        ] )
    ; ( "moving"
      , [ Alcotest.test_case "an uncounted surface holds at the top" `Quick
            test_an_uncounted_surface_holds_at_the_top
        ; Alcotest.test_case "a step forward from the End value stays there"
            `Quick test_a_step_forward_from_the_end_value_stays_there
        ; Alcotest.test_case "the window follows the row that left it" `Quick
            test_the_window_follows_the_row_that_left_it
        ; Alcotest.test_case "a row that opens a group keeps its heading in the window"
            `Quick test_a_row_that_opens_a_group_keeps_its_heading_in_the_window
        ; Alcotest.test_case "a page of uneven items passes none" `Quick
            test_a_page_of_uneven_items_passes_none
        ; Alcotest.test_case "a window of uneven rows shows the cursor whole" `Quick
            test_a_window_of_uneven_rows_shows_the_cursor_whole
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
        ; Alcotest.test_case "every move key lands inside the list" `Quick
            test_every_move_key_lands_inside_the_list
        ] )
    ; ( "layout"
      , [ Alcotest.test_case "the list height is the rows that are left" `Quick
            test_the_list_height_is_the_rows_that_are_left
        ] )
    ; ( "position"
      , [ Alcotest.test_case "a reader's page is the page a list keeps" `Quick
            test_a_reading_page_is_the_page_a_list_keeps
        ] )
    ]
