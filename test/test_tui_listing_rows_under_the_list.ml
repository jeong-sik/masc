(* Three lists draw rows under themselves. Verification draws the row naming
   which list it is reading and where in it, the armed approval, the server's
   last refusal, and -- when the join has them -- why the queue could not be
   read, that it came from a snapshot, and which waited-on ids name no record;
   Changes draws a preview and a scroll row; Logs draws the scroll row alone.
   The frame and the keypress read one layout for how many rows the list gets,
   so that layout has to count them; a row it misses is a row the footer is
   pushed out by, and finish_surface drops the last row first.

   Verification's view row carries the window text a cut page used to draw on
   a line of its own, so the two are one row and the surface reserves no
   separate scroll row. It is drawn once a read has answered and not before,
   which is why the count is zero on a state that has not read. *)

open Masc_tui_types

let state () = create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()

(* A read that answered with nothing. Enough to make the view row exist,
   which is what the row budget turns on. *)
let answered : Masc.Tui_decode.verification_snapshot =
  { vs_requests = []
  ; vs_total = 0
  ; vs_view = Masc.Tui_decode.Awaiting_queue
  ; vs_offset = 0
  ; vs_truncated = false
  ; vs_awaiting_unresolved = []
  ; vs_awaiting_unresolved_total = 0
  ; vs_backlog_error = None
  ; vs_backlog_recovery = None
  }

let layout state =
  match scrolled_surface_rows state ~cols:80 Verification with
  | Some layout -> layout
  | None -> Alcotest.fail "the Verification list has no scroll geometry"

let test_an_open_detail_is_not_the_list () =
  let detail = state () in
  detail.verification_detail_request_id <- Some "request-1";
  Alcotest.(check bool) "an open request has no list geometry" true
    (Option.is_none (scrolled_surface_rows detail ~cols:80 Verification))

let () =
  Alcotest.run "tui_listing_rows_under_the_list"
    [ ( "layout"
      , [ Alcotest.test_case "an open detail is not the list" `Quick
            test_an_open_detail_is_not_the_list
        ;] )
    ]
