open Alcotest

module Layout = Masc_tui_message_layout

let entry style role request_label body : Layout.entry =
  { style; timestamp = "12:34:56"; role_label = role; request_label; body }

let test_keeps_latest_reply () =
  let entries =
    [ entry Layout.User "you" "tui-..aaaaaaaa" (String.make 600 'u')
    ; entry Layout.Keeper "keeper.one" "tui-..bbbbbbbb" "reply"
    ]
  in
  List.iter
    (fun cols ->
      let inner = cols - 4 in
      let rows = Layout.visible_rows ~inner_width:inner ~height:5 entries in
      check bool (Printf.sprintf "%d columns keeps reply metadata" cols) true
        (List.exists
           (fun (row : Layout.row) ->
             row.style = Layout.Keeper
             && String.starts_with ~prefix:"[12:34:56]" row.text)
           rows);
      check bool (Printf.sprintf "%d columns keeps reply body" cols) true
        (List.exists
           (fun (row : Layout.row) -> String.equal row.text "  reply")
           rows);
      check bool (Printf.sprintf "%d columns bounds every plain row" cols) true
        (List.for_all
           (fun (row : Layout.row) ->
             Layout.display_width row.text <= inner)
           rows))
    [ 20; 40; 80 ]

let test_keeps_newest_metadata_and_bytes () =
  let body = String.init 160 (fun index -> Char.chr (97 + (index mod 26))) in
  let newest = entry Layout.Keeper "keeper.one" "tui-..cccccccc" body in
  let all_rows = Layout.visible_rows ~inner_width:20 ~height:100 [ newest ] in
  let reconstructed =
    all_rows
    |> List.filteri (fun index _ -> index > 0)
    |> List.map (fun (row : Layout.row) ->
           String.sub row.text 2 (String.length row.text - 2))
    |> String.concat ""
  in
  check string "full layout loses no body bytes" body reconstructed;
  match Layout.visible_rows ~inner_width:20 ~height:3 [ newest ] with
  | metadata :: _ ->
      check bool "oversized newest entry keeps metadata" true
        (String.starts_with ~prefix:"[12:34:56]" metadata.text)
  | [] -> fail "oversized newest entry rendered no rows"

let test_terminal_cell_width_and_fit () =
  List.iter
    (fun (text, expected) ->
      check int (Printf.sprintf "display width of %S" text) expected
        (Layout.display_width text))
    [ "", 0
    ; "A", 1
    ; "é", 1
    ; "e\xCC\x81", 1
    ; "한", 2
    ; "🙂", 2
    ; "Aé한🙂", 6
    ; "\x1B[31m한\x1B[0m", 2
    ];
  check string "exact-width text is unchanged" "12345"
    (Layout.fit_width "12345" 5);
  let fitted = Layout.fit_width "가나" 5 in
  check string "wide text is padded by cells" "가나 " fitted;
  check int "fitted UTF-8 fills the cell budget" 5
    (Layout.display_width fitted);
  check bool "fitted UTF-8 stays valid" true (String.is_valid_utf_8 fitted);
  check string "wide scalar is never split" "가~"
    (Layout.fit_width "가나" 3);
  check string "truncated ANSI style is reset before the marker"
    "\x1B[31m한\x1B[0m~"
    (Layout.fit_width "\x1B[31m한글\x1B[0m" 3)

let test_utf8_scalar_input_contract () =
  List.iter
    (fun (lead, expected) ->
      check (option int) (Printf.sprintf "lead %02X" (Char.code lead)) expected
        (Layout.utf8_scalar_byte_length lead))
    [ 'A', Some 1
    ; '\xC2', Some 2
    ; '\xDF', Some 2
    ; '\xE0', Some 3
    ; '\xEF', Some 3
    ; '\xF0', Some 4
    ; '\xF4', Some 4
    ; '\x80', None
    ; '\xC0', None
    ; '\xC1', None
    ; '\xF5', None
    ; '\xFF', None
    ];
  List.iter
    (fun scalar ->
      check bool ("printable scalar " ^ scalar) true
        (Layout.is_printable_utf8_scalar scalar))
    [ "A"; "é"; "한"; "🙂"; "\xCC\x81" ];
  List.iter
    (fun value ->
      check bool "invalid or control scalar" false
        (Layout.is_printable_utf8_scalar value))
    [ ""; "AB"; "\x1B"; "\x7F"; "\xC2\x80"; "\x80"; "\xC0\xAF"
    ; "\xED\xA0\x80"; "\xF4\x90\x80\x80"
    ]

let test_backspace_removes_one_utf8_scalar () =
  let rec remove expected current =
    match expected with
    | [] -> ()
    | next :: rest ->
        let actual = Layout.drop_last_utf8_scalar current in
        check string "one scalar removed" next actual;
        check bool "remaining draft is valid UTF-8" true
          (String.is_valid_utf_8 actual);
        remove rest actual
  in
  remove [ "Aé한"; "Aé"; "A"; ""; "" ] "Aé한🙂";
  let invalid = "A\xE2" in
  check string "invalid buffer is preserved" invalid
    (Layout.drop_last_utf8_scalar invalid)

let test_input_viewport_keeps_latest_complete_scalars () =
  let viewport max_cells input = Layout.input_viewport ~max_cells input in
  check string "short input stays complete" "abc" (viewport 8 "abc");
  check string "exact boundary stays complete" "abcdefgh"
    (viewport 8 "abcdefgh");
  check string "ASCII overflow keeps the newest tail" "~cdefghi"
    (viewport 8 "abcdefghi");
  check string "mixed-width overflow keeps complete scalars" "~한🙂Z"
    (viewport 6 "Aé한🙂Z");
  check string "one-cell viewport keeps omission marker" "~"
    (viewport 1 "한");
  check string "detached combining mark is not rendered" "~"
    (viewport 2 "A한\xCC\x81");
  let before = "abcdefghi" in
  let after = Layout.drop_last_utf8_scalar before in
  check string "overflow before backspace" "~cdefghi" (viewport 8 before);
  check string "backspace immediately reveals the new boundary" "abcdefgh"
    (viewport 8 after);
  let mixed = "abcdef한🙂" in
  check string "mixed tail before backspace" "~f한🙂" (viewport 6 mixed);
  check string "mixed tail after scalar backspace" "~def한"
    (viewport 6 (Layout.drop_last_utf8_scalar mixed))

let test_input_cursor_uses_visible_terminal_cells () =
  let column terminal_cols input =
    Layout.input_cursor_column ~terminal_cols ~input
  in
  check int "empty input starts after the prompt" 7 (column 80 "");
  check int "mixed UTF-8 input advances by cells" 13
    (column 80 "Aé한🙂");
  check int "exact boundary reaches the pre-border spacer" 79
    (column 80 (String.make 72 'a'));
  check int "visible overflow remains in the pre-border spacer" 79
    (column 80 (Layout.input_viewport ~max_cells:72 (String.make 100 'a')));
  check int "tiny terminal cursor stays positive" 3 (column 4 "");
  let row terminal_rows history_height status_rows =
    Layout.input_cursor_row ~terminal_rows ~history_height ~status_rows
  in
  check int "normal input row" 25 (row 30 15 5);
  check int "tiny viewport clamps the row" 4 (row 4 0 0);
  check int "excess status rows clamp to the terminal" 30 (row 30 20 20)

let test_history_wraps_by_cells_without_losing_bytes () =
  let body = "A한🙂B" in
  let rows =
    Layout.visible_rows ~inner_width:6 ~height:10
      [ entry Layout.Keeper "k" "r" body ]
  in
  let body_rows =
    rows
    |> List.filteri (fun index _ -> index > 0)
    |> List.map (fun (row : Layout.row) -> row.text)
  in
  check (list string) "wide scalars wrap at the cell boundary"
    [ "  A한"; "  🙂B" ] body_rows;
  let reconstructed =
    body_rows
    |> List.map (fun text -> String.sub text 2 (String.length text - 2))
    |> String.concat ""
  in
  check string "cell wrapping preserves body bytes" body reconstructed

let test_trailing_newlines_do_not_hide_reply () =
  let entries =
    [ entry Layout.User "you" "tui-..aaaaaaaa" (String.make 300 'u')
    ; entry Layout.Keeper "keeper.one" "tui-..bbbbbbbb"
        "reply\n\n\n\n\n\n"
    ]
  in
  let rows = Layout.visible_rows ~inner_width:16 ~height:3 entries in
  check bool "reply remains visible above trailing blank lines" true
    (List.exists
       (fun (row : Layout.row) -> String.equal row.text "  reply")
       rows)

let test_trailing_whitespace_lines_do_not_hide_reply () =
  let entries =
    [ entry Layout.Keeper "keeper.one" "tui-..bbbbbbbb"
        "reply\n \n\t\n  "
    ]
  in
  let rows = Layout.visible_rows ~inner_width:16 ~height:3 entries in
  check bool "reply remains visible above whitespace-only lines" true
    (List.exists
       (fun (row : Layout.row) -> String.equal row.text "  reply")
       rows)

let () =
  run "tui_message_layout"
    [ ( "message rows"
      , [ test_case "keeps latest reply at 20/40/80 columns" `Quick
            test_keeps_latest_reply
        ; test_case "keeps newest metadata and body bytes" `Quick
            test_keeps_newest_metadata_and_bytes
        ; test_case "terminal cell width and UTF-8 fit" `Quick
            test_terminal_cell_width_and_fit
        ; test_case "UTF-8 scalar input contract" `Quick
            test_utf8_scalar_input_contract
        ; test_case "backspace removes one UTF-8 scalar" `Quick
            test_backspace_removes_one_utf8_scalar
        ; test_case "input viewport keeps latest scalars" `Quick
            test_input_viewport_keeps_latest_complete_scalars
        ; test_case "input cursor uses visible cells" `Quick
            test_input_cursor_uses_visible_terminal_cells
        ; test_case "history wraps by cells without byte loss" `Quick
            test_history_wraps_by_cells_without_losing_bytes
        ; test_case "trailing newlines keep reply visible" `Quick
            test_trailing_newlines_do_not_hide_reply
        ; test_case "trailing whitespace lines keep reply visible" `Quick
            test_trailing_whitespace_lines_do_not_hide_reply
        ] )
    ]
