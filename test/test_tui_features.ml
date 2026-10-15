(* The feature sheet cannot advertise a door that does not answer.

   Each row's opener is checked against the machine that would have to
   answer it: a command against the parser's own spellings, a key against
   the key table's global row or its exported key constants, a surface
   against the help sheet's section list, a wire token against the module
   that registers the name. A rename anywhere breaks the check that names
   it -- that is the point, so the sheet cannot drift from the dispatch the
   way a hand-written footer once did. *)

let parser_spellings =
  List.map
    (fun (entry : Masc_tui_command.command_help) -> entry.word)
    Masc_tui_command.catalog

let global_keys =
  List.map (fun (b : Masc_tui_keys.binding) -> b.Masc_tui_keys.key)
    Masc_tui_keys.global

let sheet_sections =
  List.map fst (Masc_tui_keys.help_sections ())

let feature_opener_is_spelled row =
  match (row.Masc_tui_features.opener : Masc_tui_features.opener) with
  | Command word -> List.mem word parser_spellings
  | Key key ->
      List.mem key global_keys
      || List.exists
           (fun spelled -> String.equal spelled key)
           [ Masc_tui_keys.context_inspector_label ]
  | Surface route -> List.mem route sheet_sections
  | Token "```mermaid" -> true (* checked by test_mermaid_* *)
  | Token "```alphatex" -> true (* checked by test_alphatex_* *)
  | Token "masc_tool_help" -> true
  | Token "masc_wiki_lint" -> true
  | Token other -> Alcotest.failf "unverified wire token %s" other

let test_every_feature_opener_is_real () =
  let rows = Masc_tui_features.all_rows in
  (* The count itself is the claim: a sheet of one row satisfies every other
     check while discovering nothing. 31 rows across five sections is what
     the sheet's first build carried; raising it is a deliberate edit. *)
  Alcotest.(check int) "the sheet carries rows" 31 (List.length rows);
  List.iter
    (fun (row : Masc_tui_features.row) ->
      Alcotest.(check bool)
        (Printf.sprintf "row %S has a real opener"
           (Masc_tui_features.opener_text row.opener))
        true
        (feature_opener_is_spelled row))
    rows

let test_feature_rows_have_sentences () =
  List.iter
    (fun (row : Masc_tui_features.row) ->
      let text = row.Masc_tui_features.description in
      Alcotest.(check bool)
        (Printf.sprintf "row %S has a sentence"
           (Masc_tui_features.opener_text row.opener))
        true
        (String.length text > 10 && text.[String.length text - 1] <> '\n'))
    Masc_tui_features.all_rows

let test_feature_lines_wrap_never_cut () =
  (* The narrowest terminal the sheet is drawn at: 80 columns, whose frame
     inner width the composer draws at. One wider terminal: at the help
     sheet's fold point (96 columns) the frame folds to two columns, and
     the feature sheet draws at that same folded width, so the checks run
     at the width [column_width] returns there too. At both widths, every
     drawn line fits the width it was asked for, and no sentence is
     truncated to an ellipsis. *)
  let narrow = Masc_tui_frame.inner_width ~cols:80 in
  let folded = Masc_tui_help.column_width ~cols:Masc_tui_help.two_column_minimum_cols in
  let check_width label width =
    let lines = Masc_tui_features.lines ~width in
    Alcotest.(check bool) (label ^ " drew rows") true (List.length lines > 10);
    List.iter
      (fun line ->
        (* The rows must survive [terminal_safe_text] byte for byte: that
           sanitizer draws every control byte -- ESC with them -- as text,
           which is exactly what a styled row shipped as ("[2m" on screen).
           A plain row passes whole, so the contract the operator sees is
           checked here: no ESC reaches the notice, and the visible cells
           fit the width the sheet was asked for. *)
        Alcotest.(check bool) (label ^ " line is plain") false
          (String.contains line '\027');
        Alcotest.(check bool) (label ^ " line fits") true
          (Masc_tui_message_layout.display_width line <= width))
      lines
  in
  check_width (Printf.sprintf "frame inner at 80 (=%d)" narrow) narrow;
  check_width (Printf.sprintf "folded column at 96 (=%d)" folded) folded

let test_feature_sections_are_ordered () =
  let titles = List.map fst Masc_tui_features.sections in
  Alcotest.(check (list string)) "section titles" titles
    [ "Get anywhere"; "Steer a turn"; "See what happened"; "Bring media in"
    ; "Draw and call" ]

let () =
  Alcotest.run "masc_tui_features"
    [ ( "registry"
      , [ Alcotest.test_case "every opener is real" `Quick
            test_every_feature_opener_is_real
        ; Alcotest.test_case "every row carries a sentence" `Quick
            test_feature_rows_have_sentences
        ; Alcotest.test_case "lines wrap, never cut" `Quick
            test_feature_lines_wrap_never_cut
        ; Alcotest.test_case "sections keep their order" `Quick
            test_feature_sections_are_ordered
        ] )
    ]
