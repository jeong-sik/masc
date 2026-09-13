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

let () =
  Alcotest.run "tui_title_counts"
    [ ( "fetched view"
      , [ Alcotest.test_case "no count before an answer" `Quick
            test_no_count_before_an_answer
        ; Alcotest.test_case "a failed read is not a count" `Quick
            test_a_failed_read_is_not_a_count
        ; Alcotest.test_case "an answer is counted even when empty" `Quick
            test_an_answer_is_counted_even_when_empty
        ] )
    ]
