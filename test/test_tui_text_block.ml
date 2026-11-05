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

let styled ~max_cells text =
  Masc_tui_text_block.preformatted_styled_rows ~max_cells text

let reset = Masc_tui_ansi.Ansi.reset

let blue = "\027[34m"

let in_blue text = blue ^ text ^ reset

(* The text of a row without the two escapes [in_blue] writes. *)
let without_blue row =
  row
  |> Astring.String.cuts ~sep:blue
  |> String.concat ""
  |> Astring.String.cuts ~sep:reset
  |> String.concat ""

let has_escape row = String.exists (fun c -> Char.code c = 0x1b) row

let styled_texts =
  [ nested_json
  ; "    alpha beta gamma delta epsilon"
  ; ""
  ; "a\n\n  b"
  ; String.make 30 ' ' ^ "word"
  ; "  some_long_identifier_name:with/parts.and-more"
  ; "{\n  \"key\": \"a value with several words in it\",\n  \"n\": 12\n}"
  ]

let test_text_without_escapes_gives_the_preformatted_rows () =
  List.iter
    (fun text ->
      List.iter
        (fun max_cells ->
          check (list string)
            (Printf.sprintf "%S at %d cells" text max_cells)
            (preformatted ~max_cells text)
            (styled ~max_cells text))
        [ 1; 2; 3; 5; 8; 10; 20; 80 ])
    styled_texts

let test_a_wrapped_row_carries_the_style_it_continues () =
  let words = "alpha beta gamma delta epsilon zeta eta theta iota" in
  let drawn = styled ~max_cells:20 ("    " ^ in_blue words) in
  check bool "the line wrapped" true (List.length drawn > 1);
  List.iter
    (fun row ->
      check bool
        (Printf.sprintf "%S opens the style after the indent" row)
        true
        (Astring.String.is_prefix ~affix:("    " ^ blue) row);
      check bool
        (Printf.sprintf "%S closes the style" row)
        true
        (Astring.String.is_suffix ~affix:reset row))
    drawn;
  check (list string) "the words are the ones the plain rows hold"
    (preformatted ~max_cells:20 ("    " ^ words))
    (List.map without_blue drawn)

let test_a_style_that_ended_is_not_opened_again () =
  let line = "  " ^ in_blue "\"key\"" ^ ": value words that wrap onto more rows" in
  let drawn = styled ~max_cells:16 line in
  check bool "the line wrapped" true (List.length drawn > 2);
  check bool "the first row holds the style" true (has_escape (List.hd drawn));
  List.iter
    (fun row ->
      check bool
        (Printf.sprintf "%S carries no style" row)
        false (has_escape row))
    (List.tl drawn)

let test_styled_rows_keep_the_escapes_their_text_carries () =
  let line = "  " ^ in_blue "word" in
  check (list string) "the escapes stay" [ line ] (styled ~max_cells:80 line);
  check bool "the plain reader spells them out" false
    (List.exists has_escape (preformatted ~max_cells:80 line))

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
    ; ( "styled text keeps the rows the plain text has"
      , [ test_case "text without escapes gives the preformatted rows" `Quick
            test_text_without_escapes_gives_the_preformatted_rows
        ; test_case "a wrapped row carries the style it continues" `Quick
            test_a_wrapped_row_carries_the_style_it_continues
        ; test_case "a style that ended is not opened again" `Quick
            test_a_style_that_ended_is_not_opened_again
        ; test_case "styled rows keep the escapes their text carries" `Quick
            test_styled_rows_keep_the_escapes_their_text_carries
        ] )
    ]
