(** Tests for [Masc_tui_diff]. *)

open Alcotest

module Diff = Masc_tui_diff

let render rows =
  List.map
    (function
      | Diff.Context line -> " " ^ line
      | Diff.Removed line -> "-" ^ line
      | Diff.Added line -> "+" ^ line)
    rows
;;

let diff ~before ~after = render (Diff.rows ~before ~after)

let test_shared_lines_stay_context () =
  check (list string) "one line changed in the middle"
    [ " let a = 1"; "-let b = 2"; "+let b = 3"; " let c = 4" ]
    (diff ~before:"let a = 1\nlet b = 2\nlet c = 4"
       ~after:"let a = 1\nlet b = 3\nlet c = 4")
;;

let test_pure_insertion_removes_nothing () =
  check (list string) "added between two shared lines"
    [ " a"; "+new"; " b" ]
    (diff ~before:"a\nb" ~after:"a\nnew\nb")
;;

let test_pure_deletion_adds_nothing () =
  check (list string) "removed from the middle" [ " a"; "-gone"; " b" ]
    (diff ~before:"a\ngone\nb" ~after:"a\nb")
;;

(* A trailing newline is not an empty last line. Reading it as one would show
   a change nobody made on every edit that ends a file cleanly. *)
let test_trailing_newline_is_not_a_line () =
  check (list string) "same lines either way" [ " a"; " b" ]
    (diff ~before:"a\nb\n" ~after:"a\nb");
  check (list string) "and the other way" [ " a"; " b" ]
    (diff ~before:"a\nb" ~after:"a\nb\n")
;;

let test_identical_text_is_all_context () =
  check (list string) "nothing changed" [ " a"; " b" ] (diff ~before:"a\nb" ~after:"a\nb")
;;

(* Removals come before additions, so a reader sees what left before what
   arrived rather than the two interleaved by accident of length. *)
let test_removals_precede_additions () =
  check (list string) "two out, one in" [ "-x"; "-y"; "+z" ]
    (diff ~before:"x\ny" ~after:"z")
;;

let test_empty_sides () =
  check (list string) "everything added" [ "+a"; "+b" ] (diff ~before:"" ~after:"a\nb");
  check (list string) "everything removed" [ "-a"; "-b" ] (diff ~before:"a\nb" ~after:"")
;;

let test_counts () =
  let rows = Diff.rows ~before:"a\nx\ny\nb" ~after:"a\nz\nb" in
  let removed, added = Diff.counts rows in
  check int "removed" 2 removed;
  check int "added" 1 added
;;

(* A line that repeats must not let the prefix walk past the change. Both
   halves start with the same two lines; only the third differs. *)
let test_repeated_lines_do_not_swallow_the_change () =
  check (list string) "the repeat is context, the change is not"
    [ " same"; " same"; "-old"; "+new" ]
    (diff ~before:"same\nsame\nold" ~after:"same\nsame\nnew")
;;

(* The column an added line has nothing to put in. A blank would read as an
   alignment slip and a zero as line zero; both claim something the row does
   not say. *)
let test_a_missing_line_number_is_spelled_not_blank () =
  check string "absence is a dash" "    -" (Diff.line_number_cell None);
  check int "and it takes a number's width" 5
    (String.length (Diff.line_number_cell None))
;;

let test_a_line_number_keeps_the_column_width () =
  check int "single digit" 5 (String.length (Diff.line_number_cell (Some 7)));
  check int "five digits" 5 (String.length (Diff.line_number_cell (Some 12345)));
  check string "right aligned" "    7" (Diff.line_number_cell (Some 7));
  (* Wider than the column rather than truncated: a line number cut to its
     last digits is a different line, and a row that slips is visible while a
     wrong number is not. *)
  check string "a six-digit file overflows the column" "123456"
    (Diff.line_number_cell (Some 123456))
;;

let () =
  run "tui_diff"
    [ ( "shape"
      , [ test_case "shared lines stay context" `Quick test_shared_lines_stay_context
        ; test_case "insertion" `Quick test_pure_insertion_removes_nothing
        ; test_case "deletion" `Quick test_pure_deletion_adds_nothing
        ; test_case "identical" `Quick test_identical_text_is_all_context
        ; test_case "removals precede additions" `Quick test_removals_precede_additions
        ; test_case "repeated lines" `Quick test_repeated_lines_do_not_swallow_the_change
        ] )
    ; ( "edges"
      , [ test_case "trailing newline" `Quick test_trailing_newline_is_not_a_line
        ; test_case "empty sides" `Quick test_empty_sides
        ; test_case "counts" `Quick test_counts
        ] )
    ; ( "line numbers"
      , [ test_case "absence is spelled" `Quick
            test_a_missing_line_number_is_spelled_not_blank
        ; test_case "the column width holds" `Quick
            test_a_line_number_keeps_the_column_width
        ] )
    ]
;;
