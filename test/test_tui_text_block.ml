open Alcotest

let rows ~max_cells text = Masc_tui_text_block.rows ~max_cells text

let test_a_carriage_return_inside_a_line_is_still_spelled () =
  let drawn = rows ~max_cells:80 "a\rb" in
  check int "one row" 1 (List.length drawn);
  check bool
    (Printf.sprintf "%S carries no CR byte" (List.hd drawn))
    false
    (String.contains (List.hd drawn) '\r');
  check bool
    (Printf.sprintf "%S spells it instead" (List.hd drawn))
    true
    (Astring.String.is_infix ~affix:"\\x0D" (List.hd drawn))

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

let preformatted ~max_cells text =
  Masc_tui_text_block.preformatted_rows ~max_cells text

(* Pretty-printed JSON is the case that matters: a Task's history note is one,
   and its nesting is the only structure it has. *)
let nested_json = "{\n  \"a\": {\n    \"b\": 1\n  }\n}"

let test_prose_drops_the_spaces_a_line_opens_with () =
  check (list string) "the words stay and the indent goes" [ "alpha beta" ]
    (rows ~max_cells:80 "    alpha beta")

let test_preformatted_keeps_the_spaces_a_line_opens_with () =
  check (list string) "the nesting stays"
    [ "{"; "  \"a\": {"; "    \"b\": 1"; "  }"; "}" ]
    (preformatted ~max_cells:80 nested_json)

let test_a_wrapped_line_continues_at_its_own_indent () =
  let drawn = preformatted ~max_cells:20 "    alpha beta gamma delta epsilon" in
  check bool "the line wrapped" true (List.length drawn > 1);
  List.iter
    (fun row ->
      check bool
        (Printf.sprintf "%S opens with the four spaces and no more" row)
        true
        (Astring.String.is_prefix ~affix:"    " row
         && not (Astring.String.is_prefix ~affix:"     " row));
      check bool
        (Printf.sprintf "%S fits the width" row)
        true
        (Masc_tui_message_layout.display_width row <= 20))
    drawn

let test_an_indent_takes_at_most_half_the_width () =
  check (list string) "five of ten cells" [ "     word" ]
    (preformatted ~max_cells:10 (String.make 30 ' ' ^ "word"))

let test_blank_rows_and_edges_follow_the_prose_rule () =
  check (list string) "a blank row between lines stays and the edges go"
    [ "a"; ""; "  b" ]
    (preformatted ~max_cells:80 "\n\na\n\n  b\n\n")

let test_preformatted_rows_are_still_neutralised () =
  let drawn = String.concat "|" (preformatted ~max_cells:80 "  \x1b[31mred") in
  check bool
    (Printf.sprintf "%S carries no ESC byte" drawn)
    false
    (String.exists (fun c -> Char.code c = 0x1b) drawn)

let () =
  run "tui text block"
    [ ( "a block keeps the rows its text asks for"
      , [ test_case "an escape sequence is still neutralised" `Quick
            test_an_escape_sequence_is_still_neutralised
        ; test_case "a carriage return inside a line is still spelled" `Quick
            test_a_carriage_return_inside_a_line_is_still_spelled
        ] )
    ; ( "preformatted text keeps its indentation"
      , [ test_case "prose drops the spaces a line opens with" `Quick
            test_prose_drops_the_spaces_a_line_opens_with
        ; test_case "preformatted keeps the spaces a line opens with" `Quick
            test_preformatted_keeps_the_spaces_a_line_opens_with
        ; test_case "a wrapped line continues at its own indent" `Quick
            test_a_wrapped_line_continues_at_its_own_indent
        ; test_case "an indent takes at most half the width" `Quick
            test_an_indent_takes_at_most_half_the_width
        ; test_case "blank rows and edges follow the prose rule" `Quick
            test_blank_rows_and_edges_follow_the_prose_rule
        ; test_case "preformatted rows are still neutralised" `Quick
            test_preformatted_rows_are_still_neutralised
        ] )
    ]
