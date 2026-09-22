open Alcotest

let rows ~max_cells text = Masc_tui_text_block.rows ~max_cells text

(* The defect this closes: a description written with line breaks reached the
   block through the single-line reader, which spells a break as the four
   characters "\x0A". They wrapped into the sentence, so "3줄만 반복." and
   "실측:" met in the middle of a line with "\x0A\x0A" between them. *)
let test_a_line_break_takes_a_row () =
  check (list string) "two lines, not one sentence"
    [ "first"; "second" ]
    (rows ~max_cells:40 "first\nsecond")

let test_no_row_spells_the_escape () =
  let drawn = String.concat "|" (rows ~max_cells:40 "a\nb\n\nc") in
  check bool
    (Printf.sprintf "%S spells no break" drawn)
    false
    (Astring.String.is_infix ~affix:"\\x0A" drawn)

(* A break the author wrote in the middle is a paragraph, so it keeps its
   row. The operator ask pane reads the same shape the same way. *)
let test_a_blank_row_between_paragraphs_is_kept () =
  check (list string) "the blank between them"
    [ "one"; ""; "two" ]
    (rows ~max_cells:40 "one\n\ntwo")

(* A break at either end carries nothing, and a leading blank would take the
   row the caller puts its label on. *)
let test_breaks_at_the_edges_are_dropped () =
  check (list string) "no blank at either end"
    [ "body" ]
    (rows ~max_cells:40 "\n\nbody\n\n")

let test_a_blank_text_draws_nothing () =
  check (list string) "nothing to draw" [] (rows ~max_cells:40 "\n\n")

(* Wrapping still happens, per line rather than over the whole text. *)
let test_each_line_wraps_to_the_width () =
  check (list string) "each line folded on its own"
    [ "aaa"; "bbb"; "ccc" ]
    (rows ~max_cells:3 "aaa bbb\nccc")

(* What the single-line reader is for: text someone else wrote must not carry
   an escape sequence to the terminal. Splitting on breaks keeps that. *)
let test_an_escape_sequence_is_still_neutralised () =
  let drawn = String.concat "|" (rows ~max_cells:80 "before\n\x1b[31mred") in
  check bool
    (Printf.sprintf "%S carries no ESC byte" drawn)
    false
    (String.exists (fun c -> Char.code c = 0x1b) drawn);
  check bool
    (Printf.sprintf "%S spells it instead" drawn)
    true
    (Astring.String.is_infix ~affix:"\\x1B" drawn)

(* A carriage return is not a line break: it would move the cursor to the
   start of the row it is on and overwrite what was drawn there. *)
let test_a_carriage_return_is_not_a_break () =
  let drawn = rows ~max_cells:80 "a\rb" in
  check int "one row" 1 (List.length drawn);
  check bool
    (Printf.sprintf "%S carries no CR byte" (List.hd drawn))
    false
    (String.contains (List.hd drawn) '\r')

let () =
  run "tui text block"
    [ ( "a block keeps the rows its text asks for"
      , [ test_case "a line break takes a row" `Quick test_a_line_break_takes_a_row
        ; test_case "no row spells the escape" `Quick test_no_row_spells_the_escape
        ; test_case "a blank row between paragraphs is kept" `Quick
            test_a_blank_row_between_paragraphs_is_kept
        ; test_case "breaks at the edges are dropped" `Quick
            test_breaks_at_the_edges_are_dropped
        ; test_case "a blank text draws nothing" `Quick test_a_blank_text_draws_nothing
        ; test_case "each line wraps to the width" `Quick
            test_each_line_wraps_to_the_width
        ; test_case "an escape sequence is still neutralised" `Quick
            test_an_escape_sequence_is_still_neutralised
        ; test_case "a carriage return is not a break" `Quick
            test_a_carriage_return_is_not_a_break
        ] )
    ]
