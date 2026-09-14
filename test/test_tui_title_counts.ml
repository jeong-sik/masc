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
        ] )
    ]
