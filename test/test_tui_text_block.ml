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

let () =
  run "tui text block"
    [ ( "a block keeps the rows its text asks for"
      , [ test_case "an escape sequence is still neutralised" `Quick
            test_an_escape_sequence_is_still_neutralised
        ; test_case "a carriage return inside a line is still spelled" `Quick
            test_a_carriage_return_inside_a_line_is_still_spelled
        ] )
    ]
