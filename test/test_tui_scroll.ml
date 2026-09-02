(* The bound for a scrolled list, and what a keypress does inside it.

   These four lines were written out once per surface, and thirteen of those
   copies lived in the drawing: the key handler moved the scroll with no bound
   and the frame clamped it back on the way past. What that arrangement hid is
   the case below -- a scroll left stale by a list that shrank. *)

let check = Alcotest.check
let int = Alcotest.int

let test_the_bound_is_what_is_left_below_the_window () =
  check int "a list longer than the window" 6
    (Masc_tui_scroll.maximum ~count:10 ~height:4);
  check int "a list that fits does not scroll" 0
    (Masc_tui_scroll.maximum ~count:3 ~height:10);
  check int "an empty list does not scroll" 0
    (Masc_tui_scroll.maximum ~count:0 ~height:10)

let test_moving_stays_inside_the_bound () =
  check int "down stops at the end" 6
    (Masc_tui_scroll.down ~count:10 ~height:4 6);
  check int "down from the middle" 3 (Masc_tui_scroll.down ~count:10 ~height:4 2);
  check int "up stops at the top" 0 (Masc_tui_scroll.up ~count:10 ~height:4 0);
  check int "up from the middle" 1 (Masc_tui_scroll.up ~count:10 ~height:4 2);
  check int "a list that fits cannot move" 0
    (Masc_tui_scroll.down ~count:3 ~height:10 0)

(* The case the write-back was covering for. A list can shrink under a reader
   -- a filter, a refresh, a keeper that went quiet -- and leave the stored
   scroll past the end. Moving from that position has to start from where the
   reader actually is: stepping from the stale number would answer [up] with
   another number still past the end, and the screen would not move. *)
let test_a_stale_scroll_moves_from_where_the_reader_is () =
  check int "up from past the end lands one above the end" 5
    (Masc_tui_scroll.up ~count:10 ~height:4 40);
  check int "down from past the end stays at the end" 6
    (Masc_tui_scroll.down ~count:10 ~height:4 40);
  check int "a list that emptied goes to the top" 0
    (Masc_tui_scroll.up ~count:0 ~height:4 40);
  check int "reading a stale scroll is safe" 6
    (Masc_tui_scroll.normalize ~count:10 ~height:4 40)

let test_a_window_of_no_rows_still_answers () =
  check int "a zero height leaves the whole list below" 10
    (Masc_tui_scroll.maximum ~count:10 ~height:0);
  check int "and moving still terminates" 1
    (Masc_tui_scroll.down ~count:10 ~height:0 0)


(* The cursor names a row; the window follows. The same shrink rule holds:
   moving normalises first, so a cursor stranded past the end of a list that
   shrank steps from the last row, not from a ghost. *)

let test_the_cursor_stays_inside_the_list () =
  check int "down stops at the last row" 3
    (Masc_tui_scroll.cursor_down ~count:4 3);
  check int "down from the middle" 2 (Masc_tui_scroll.cursor_down ~count:4 1);
  check int "up stops at the first row" 0 (Masc_tui_scroll.cursor_up ~count:4 0);
  check int "an empty list pins the cursor at zero" 0
    (Masc_tui_scroll.cursor_down ~count:0 5);
  check int "a stranded cursor steps from the last row" 2
    (Masc_tui_scroll.cursor_up ~count:4 9)

let test_the_window_follows_the_cursor () =
  check int "a cursor above the window pulls it up" 2
    (Masc_tui_scroll.ensure_visible ~cursor:2 ~height:5 4);
  check int "a cursor below the window pulls it down" 6
    (Masc_tui_scroll.ensure_visible ~cursor:10 ~height:5 0);
  check int "a visible cursor moves nothing" 3
    (Masc_tui_scroll.ensure_visible ~cursor:5 ~height:5 3)


(* The context-inspector tabs draw a detail column that begins on the
   selected row's own line and runs downward. [ensure_visible] answers a row
   that fell below the fold by pinning it to the window's last line, which
   held that whole detail behind the bottom edge: the keys on those tabs move
   the cursor, so every press re-pinned the next row to the same edge and the
   content under it never entered the window. A row that carries content
   below it has to lead the window instead. *)
let test_a_row_with_content_under_it_leads_the_window () =
  check int "a row below the fold leads from one line above it" 9
    (Masc_tui_scroll.ensure_leading ~cursor:10 ~height:5 0);
  check int "not pinned to the last line as a bare row would be" 6
    (Masc_tui_scroll.ensure_visible ~cursor:10 ~height:5 0);
  check int "a row above the window leads there too" 1
    (Masc_tui_scroll.ensure_leading ~cursor:2 ~height:5 4);
  check int "a visible row moves nothing" 3
    (Masc_tui_scroll.ensure_leading ~cursor:5 ~height:5 3);
  check int "the first row cannot lead from below zero" 0
    (Masc_tui_scroll.ensure_leading ~cursor:0 ~height:5 4)


(* Changes draws a preview under its list. The list keeps five rows and the
   preview takes up to half of what is left, so on a twenty-row body the list
   draws ten. The keypress used to move against the full twenty: with fifteen
   changes the bound came out max 0 (15 - 20) = 0 and the cursor could not
   leave the first row at all. *)
let test_a_preview_leaves_the_list_its_keep () =
  check int "half of twenty, list keeps five" 10
    (Masc_tui_scroll.preview_height ~total:20 ~keep:5);
  check int "the list draws the other half" 10
    (Masc_tui_scroll.body_height ~total:20 ~keep:5);
  check int "a body too short for the keep gives no preview" 0
    (Masc_tui_scroll.preview_height ~total:5 ~keep:5);
  check int "and the list keeps all of it" 5
    (Masc_tui_scroll.body_height ~total:5 ~keep:5);
  check int "one row is still a list" 1
    (Masc_tui_scroll.body_height ~total:1 ~keep:5)

let test_the_bound_follows_the_shortened_list () =
  let height = Masc_tui_scroll.body_height ~total:20 ~keep:5 in
  check int "fifteen rows in a ten-row list can scroll five" 5
    (Masc_tui_scroll.maximum ~count:15 ~height);
  (* The same fifteen rows against the unshortened body: this is the number
     the keypress used, and it is why the last five were unreachable. *)
  check int "against the full body the bound was zero" 0
    (Masc_tui_scroll.maximum ~count:15 ~height:20);
  let rec press n scroll =
    if n = 0 then scroll
    else press (n - 1) (Masc_tui_scroll.down ~count:15 ~height scroll)
  in
  check int "pressing down ten times reaches the last window" 5 (press 10 0)

let test_a_conditional_overflow_row_is_part_of_the_bound () =
  check int "a fitting list keeps the whole body" 23
    (Masc_tui_scroll.content_height ~rows:30 ~chrome:7 ~count:23
       ~preview_keep:None ~overflow_takes_row:true);
  check int "the first overflowing row reserves its indicator" 22
    (Masc_tui_scroll.content_height ~rows:30 ~chrome:7 ~count:24
       ~preview_keep:None ~overflow_takes_row:true);
  check int "an action notice and overflow both spend their rows" 20
    (Masc_tui_scroll.content_height ~rows:30 ~chrome:9 ~count:24
       ~preview_keep:None ~overflow_takes_row:true)

let () =
  Alcotest.run "tui_scroll"
    [ ( "bound"
      , [ Alcotest.test_case "what is left below the window" `Quick
            test_the_bound_is_what_is_left_below_the_window
        ; Alcotest.test_case "a window of no rows" `Quick
            test_a_window_of_no_rows_still_answers
        ] )
    ; ( "moving"
      , [ Alcotest.test_case "stays inside the bound" `Quick
            test_moving_stays_inside_the_bound
        ; Alcotest.test_case "a stale scroll moves from where the reader is"
            `Quick test_a_stale_scroll_moves_from_where_the_reader_is
        ] )
    ; ( "preview"
      , [ Alcotest.test_case "a preview leaves the list its keep" `Quick
            test_a_preview_leaves_the_list_its_keep
        ; Alcotest.test_case "the bound follows the shortened list" `Quick
            test_the_bound_follows_the_shortened_list
        ] )
    ; ( "cursor"
      , [ Alcotest.test_case "the cursor stays inside the list" `Quick
            test_the_cursor_stays_inside_the_list
        ; Alcotest.test_case "the window follows the cursor" `Quick
            test_the_window_follows_the_cursor
        ; Alcotest.test_case "a row with content under it leads the window"
            `Quick test_a_row_with_content_under_it_leads_the_window
        ] )
    ; ( "layout"
      , [ Alcotest.test_case "conditional overflow row" `Quick
            test_a_conditional_overflow_row_is_part_of_the_bound
        ] )
    ]
