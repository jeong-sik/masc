(* Three lists draw rows under themselves. Verification draws the armed
   approval, the server's last refusal, and a scroll row while the queue
   overflows; Changes draws a preview and the same scroll row; Logs draws the
   scroll row alone. The frame and the keypress read one layout for how many
   rows the list gets, so that layout has to count them; a row it misses is a
   row the footer is pushed out by, and finish_surface drops the last row
   first. *)

open Masc_tui_types

let state () = create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()

let layout state =
  match scrolled_surface_rows state Verification with
  | Some layout -> layout
  | None -> Alcotest.fail "the Verification list has no scroll geometry"

let test_the_rows_under_the_list_are_counted () =
  let frame = listing_chrome ~error:None in
  Alcotest.(check int) "a quiet list has the listing frame" frame
    (layout (state ())).sc_chrome;
  let armed = state () in
  armed.verification_verdict_armed <- Some "task-armed";
  Alcotest.(check int) "an armed approval takes a row" (frame + 1)
    (layout armed).sc_chrome;
  armed.verification_verdict_error <- Some "refused";
  Alcotest.(check int) "and the server's refusal another" (frame + 2)
    (layout armed).sc_chrome;
  Alcotest.(check bool) "an overflowing queue reserves its scroll row" true
    (layout (state ())).sc_overflow_takes_row

(* The sum the frame actually draws: its fixed rows, the list, and the scroll
   row once the queue is longer than the list. It has to come out at the body
   height exactly, armed or not, for the footer to stay on the frame. *)
let test_an_armed_overflowing_queue_fills_the_body_exactly () =
  let body_rows = 24 in
  let armed = state () in
  armed.verification_verdict_armed <- Some "task-armed";
  let shape = layout armed in
  let count = 40 in
  let list_rows =
    Masc_tui_scroll.content_height ~rows:body_rows ~chrome:shape.sc_chrome
      ~count ~preview_keep:shape.sc_preview_keep
      ~overflow_takes_row:shape.sc_overflow_takes_row
  in
  let scroll_row = if count > list_rows then 1 else 0 in
  Alcotest.(check int) "frame + list + scroll row is the body" body_rows
    (shape.sc_chrome + list_rows + scroll_row)

let test_an_open_detail_is_not_the_list () =
  let detail = state () in
  detail.verification_detail_request_id <- Some "request-1";
  Alcotest.(check bool) "an open request has no list geometry" true
    (Option.is_none (scrolled_surface_rows detail Verification))

(* Changes: the preview takes what the list leaves over its keep, and the scroll
   row comes out of the list while the list overflows. *)
let test_an_overflowing_changes_list_fills_the_body_exactly () =
  let changes = state () in
  let shape =
    match scrolled_surface_rows changes Changes with
    | Some layout -> layout
    | None -> Alcotest.fail "the Changes list has no scroll geometry"
  in
  Alcotest.(check bool) "an overflowing Changes list reserves its scroll row" true
    shape.sc_overflow_takes_row;
  let body_rows = 30 and count = 50 in
  let total = max 1 (body_rows - shape.sc_chrome) in
  let preview =
    match shape.sc_preview_keep with
    | Some keep -> Masc_tui_scroll.preview_height ~total ~keep
    | None -> 0
  in
  let list_rows =
    Masc_tui_scroll.content_height ~rows:body_rows ~chrome:shape.sc_chrome
      ~count ~preview_keep:shape.sc_preview_keep
      ~overflow_takes_row:shape.sc_overflow_takes_row
  in
  Alcotest.(check int) "frame + list + preview + scroll row is the body" body_rows
    (shape.sc_chrome + list_rows + preview + 1)

(* Logs reserved its scroll row whether or not the page overflowed, so a page
   that fit -- an empty one included -- ended a row short and the footer sat a
   row above the composer. The row is counted only while it is drawn. *)
let test_the_logs_scroll_row_is_counted_only_while_drawn () =
  let logs = state () in
  logs.view <- System_logs;
  let shape =
    match scrolled_surface_rows logs System_logs with
    | Some layout -> layout
    | None -> Alcotest.fail "the Logs list has no scroll geometry"
  in
  Alcotest.(check int) "the frame is the listing frame" (listing_chrome ~error:None)
    shape.sc_chrome;
  let body_rows = 30 in
  let drawn ~count =
    let list_rows =
      Masc_tui_scroll.content_height ~rows:body_rows ~chrome:shape.sc_chrome
        ~count ~preview_keep:shape.sc_preview_keep
        ~overflow_takes_row:shape.sc_overflow_takes_row
    in
    shape.sc_chrome + list_rows + (if count > list_rows then 1 else 0)
  in
  Alcotest.(check int) "an empty page fills the body" body_rows (drawn ~count:0);
  Alcotest.(check int) "a page that fits fills the body" body_rows (drawn ~count:5);
  Alcotest.(check int) "an overflowing page fills the body" body_rows (drawn ~count:200)

let () =
  Alcotest.run "tui_listing_rows_under_the_list"
    [ ( "layout"
      , [ Alcotest.test_case "the rows under the list are counted" `Quick
            test_the_rows_under_the_list_are_counted
        ; Alcotest.test_case "an armed overflowing queue fills the body" `Quick
            test_an_armed_overflowing_queue_fills_the_body_exactly
        ; Alcotest.test_case "an open detail is not the list" `Quick
            test_an_open_detail_is_not_the_list
        ; Alcotest.test_case "an overflowing Changes list fills the body" `Quick
            test_an_overflowing_changes_list_fills_the_body_exactly
        ; Alcotest.test_case "the Logs scroll row is counted only while drawn" `Quick
            test_the_logs_scroll_row_is_counted_only_while_drawn
        ] )
    ]
