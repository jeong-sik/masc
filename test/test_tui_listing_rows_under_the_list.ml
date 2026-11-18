(* Lists draw rows under themselves. Verification draws the row naming which
   list it is reading, the armed approval, the server's last refusal, and --
   when the join has them -- why the queue could not be read, that it came
   from a snapshot, and which waited-on ids name no record; Changes draws a
   preview. Where a list stands is on the title row, so none of them keeps a
   row for it. The frame and the keypress read one layout for how many rows
   the list gets, so that layout has to count them; a row it misses is a row
   the footer is pushed out by, and finish_surface drops the last row first.

   Verification's view row is drawn once a read has answered and not before,
   which is why the count is zero on a state that has not read. *)

open Masc_tui_types

let state () = create_state ~workspace:"test" ~port:8935 ()

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
