(* Verification draws three rows under its list: the armed approval, the
   server's last refusal, and a scroll row while the queue overflows. The frame
   and the keypress read one layout for how many rows the list gets, so that
   layout has to count them; a row it misses is a row the footer is pushed out
   by, and finish_surface drops the last row first. *)

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

let () =
  Alcotest.run "tui_verification_listing"
    [ ( "layout"
      , [ Alcotest.test_case "the rows under the list are counted" `Quick
            test_the_rows_under_the_list_are_counted
        ; Alcotest.test_case "an armed overflowing queue fills the body" `Quick
            test_an_armed_overflowing_queue_fills_the_body_exactly
        ; Alcotest.test_case "an open detail is not the list" `Quick
            test_an_open_detail_is_not_the_list
        ] )
    ]
