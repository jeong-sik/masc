(* A title's count is a reading, and a pane that has not read has no count.
   The prompt registry and its runtime assets drew "0/0개" and "0개" before the
   registry answered and after a read that failed, the same as for a registry
   with nothing in it. *)

open Masc_tui_types
module Fetched = Masc_tui_fetched

let count_of view =
  title_count_of_view view ~count:(fun rows -> string_of_int (List.length rows))

let started fetched =
  match Fetched.start ~equal:Unit.equal fetched ~key:() with
  | Fetched.Started (next, request) -> (next, request)
  | Fetched.Already_loading -> Alcotest.fail "fixture already loading"

let view fetched = Fetched.view_for ~equal:Unit.equal fetched ~key:()

let test_no_count_before_an_answer () =
  Alcotest.(check string) "never asked" title_unread
    (count_of (view Fetched.initial));
  let loading, _ = started Fetched.initial in
  Alcotest.(check string) "asked, still waiting" title_unread
    (count_of (view loading))

let test_a_failed_read_is_not_a_count () =
  let loading, request = started Fetched.initial in
  let failed =
    Fetched.complete ~equal:Unit.equal loading request (Error "connect failed")
  in
  Alcotest.(check string) "the read failed" title_failed (count_of (view failed))

let test_an_answer_is_counted_even_when_empty () =
  let loading, request = started Fetched.initial in
  let empty = Fetched.complete ~equal:Unit.equal loading request (Ok []) in
  Alcotest.(check string) "an empty answer is zero" "0" (count_of (view empty));
  let loading, request = started Fetched.initial in
  let two = Fetched.complete ~equal:Unit.equal loading request (Ok [ (); () ]) in
  Alcotest.(check string) "and a full one its size" "2" (count_of (view two))

(* A title brackets the words because it has no label to hang them on; a
   labelled field has one. Both spellings say the same words, and the field
   pays no cells for brackets the label already earns -- the keeper chat
   header is one cell short of its runtime id without that saving. *)
let test_the_field_says_the_words_without_the_brackets () =
  Alcotest.(check string) "the field is the words" "not loaded" field_unread;
  Alcotest.(check string) "the title brackets them" "(not loaded)" title_unread

(* The Activity feed's title. With no server on the port the feed never opens,
   and every sibling surface's title in that frame reads "(load failed)" or
   "(not loaded)" while the row under this one reads "the feed is not open". *)
let test_an_unopened_feed_has_no_count () =
  Alcotest.(check string) "never opened" title_unread
    (activity_title_reading ~observer:Observer_off ~shown:0 ~held:0);
  Alcotest.(check string) "asked and still waiting" title_unread
    (activity_title_reading ~observer:Observer_opening ~shown:0 ~held:0)

let test_a_feed_that_answered_is_counted_even_when_empty () =
  Alcotest.(check string) "live with nothing yet"
    "(0 rows \xc2\xb7 0 events held)"
    (activity_title_reading
       ~observer:(Observer_live { session_id = "s"; since = 0.; events = 0 })
       ~shown:0 ~held:0);
  Alcotest.(check string) "and once it has frames"
    "(3 rows \xc2\xb7 120 events held)"
    (activity_title_reading
       ~observer:(Observer_live { session_id = "s"; since = 0.; events = 120 })
       ~shown:3 ~held:120)

(* Held frames outlive the stream that delivered them, so a feed that has
   closed still has a reading to report. *)
let test_frames_in_hand_are_a_reading_after_the_stream_closes () =
  Alcotest.(check string) "closed, frames kept"
    "(2 rows \xc2\xb7 12 events held)"
    (activity_title_reading
       ~observer:(Observer_closed { reason = "eof"; at = 0.; events = 12 })
       ~shown:2 ~held:12);
  Alcotest.(check string) "off again, frames still in hand"
    "(2 rows \xc2\xb7 12 events held)"
    (activity_title_reading ~observer:Observer_off ~shown:2 ~held:12)

let () =
  Alcotest.run "tui_title_counts"
    [ ( "fetched view"
      , [ Alcotest.test_case "no count before an answer" `Quick
            test_no_count_before_an_answer
        ; Alcotest.test_case "a failed read is not a count" `Quick
            test_a_failed_read_is_not_a_count
        ; Alcotest.test_case "the field says the words without the brackets" `Quick
            test_the_field_says_the_words_without_the_brackets
        ; Alcotest.test_case "an answer is counted even when empty" `Quick
            test_an_answer_is_counted_even_when_empty
        ; Alcotest.test_case "an unopened feed has no count" `Quick
            test_an_unopened_feed_has_no_count
        ; Alcotest.test_case
            "a feed that answered is counted even when empty" `Quick
            test_a_feed_that_answered_is_counted_even_when_empty
        ; Alcotest.test_case
            "frames in hand are a reading after the stream closes" `Quick
            test_frames_in_hand_are_a_reading_after_the_stream_closes
        ] )
    ]
