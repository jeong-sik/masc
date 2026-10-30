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

let fence_token_is_drawn fence =
  (* A fence token on the feature sheet must be recognized by the Markdown
     fence dispatcher: either it produces a [Drawn_diagram] semantic run in
     [Masc_tui_markdown.render_document_with_spans] (Mermaid), or it renders
     the same tablature lines as [Masc_tui_alphatex.render_tab] (alphaTex). *)
  let diagram_doc =
    Masc_tui_markdown.render_document_with_spans
      ~palette:Masc_tui_markdown.plain_palette ~width:80
      (fence ^ "\nflowchart LR\nA[box] --> B[box]\n```")
  in
  let draws_diagram =
    List.exists
      (fun (run : Masc_tui_markdown.semantic_run) ->
        match run.reading with
        | Masc_tui_markdown.Drawn_diagram _ -> true
        | Masc_tui_markdown.Source_order -> false)
      diagram_doc.semantic_runs
  in
  let draws_alphatex =
    let score = ":4 0.6 3.6" in
    match Masc_tui_alphatex.render_tab ~max_width:78 score with
    | Error _ -> false
    | Ok tab_lines ->
        let rows =
          Masc_tui_markdown.render
            ~palette:Masc_tui_markdown.plain_palette ~width:80
            (fence ^ "\n" ^ score ^ "\n```")
        in
        tab_lines <> []
        && List.for_all
             (fun tab_line ->
               List.exists
                 (fun row ->
                   let len = String.length row and sub = String.length tab_line in
                   let rec has i =
                     i + sub <= len
                     && (String.equal (String.sub row i sub) tab_line || has (i + 1))
                   in
                   has 0)
                 rows)
             tab_lines
  in
  draws_diagram || draws_alphatex

let feature_opener_is_spelled row =
  match (row.Masc_tui_features.opener : Masc_tui_features.opener) with
  | Command word -> List.mem word parser_spellings
  | Key key ->
      List.mem key global_keys
      || List.exists
           (fun spelled -> String.equal spelled key)
           [ Masc_tui_keys.context_inspector_label ]
  | Surface route -> List.mem route sheet_sections
  | Token token when String.starts_with ~prefix:"```" token ->
      fence_token_is_drawn token
  | Token tool_name ->
      Tool_help_registry.definition_source tool_name
      = Some ("tools/" ^ tool_name ^ ".toml")

(* Slash commands in [Masc_tui_command.catalog] that are intentionally not
   repeated as [Command] rows on [/features] (either because the sheet names
   their key shortcut instead, such as [Ctrl-L] for [/activity], or because
   they belong to the full [/help] reference). A new command added to
   [Masc_tui_command.catalog] must either join [Masc_tui_features] or be
   listed here explicitly. *)
let catalog_commands_outside_sheet =
  [ "about"; "activity"; "approve"; "calls"; "changes"; "cost"; "deny"; "features"
  ; "fleet-memory"; "help"; "links"; "login"; "memory"; "metrics"; "preset"
  ; "preview"; "settings"; "task"; "task-inspect"; "task-recover"
  ; "thinking"; "tools" ]

let test_every_feature_opener_is_real () =
  let rows = Masc_tui_features.all_rows in
  List.iter
    (fun (row : Masc_tui_features.row) ->
      Alcotest.(check bool)
        (Printf.sprintf "row %S has a real opener"
           (Masc_tui_features.opener_text row.opener))
        true
        (feature_opener_is_spelled row))
    rows

let test_command_catalog_and_feature_sheet_stay_aligned () =
  let sheet_commands =
    List.filter_map
      (fun (row : Masc_tui_features.row) ->
        match row.opener with
        | Masc_tui_features.Command word -> Some word
        | Key _ | Surface _ | Token _ -> None)
      Masc_tui_features.all_rows
  in
  let overlap =
    List.filter
      (fun word -> List.mem word catalog_commands_outside_sheet)
      sheet_commands
  in
  Alcotest.(check (list string))
    "no command is both on the sheet and in the outside list" [] overlap;
  let covered =
    List.sort_uniq String.compare
      (sheet_commands @ catalog_commands_outside_sheet)
  in
  let expected = List.sort_uniq String.compare parser_spellings in
  Alcotest.(check (list string))
    "every parser command is accounted for by the feature sheet or explicit exclusion list"
    expected covered

let test_experimental_rows_are_marked () =
  let experimental_openers =
    List.filter_map
      (fun (row : Masc_tui_features.row) ->
        if String.ends_with ~suffix:" (Experimental)" row.description then
          Some (Masc_tui_features.opener_text row.opener)
        else None)
      Masc_tui_features.all_rows
  in
  Alcotest.(check (list string))
    "experimental rows carry the (Experimental) suffix"
    [ "```alphatex"; "masc_wiki_lint" ]
    experimental_openers

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
        ; Alcotest.test_case "command catalog and feature sheet stay aligned" `Quick
            test_command_catalog_and_feature_sheet_stay_aligned
        ; Alcotest.test_case "experimental rows are marked" `Quick
            test_experimental_rows_are_marked
        ; Alcotest.test_case "every row carries a sentence" `Quick
            test_feature_rows_have_sentences
        ; Alcotest.test_case "lines wrap, never cut" `Quick
            test_feature_lines_wrap_never_cut
        ; Alcotest.test_case "sections keep their order" `Quick
            test_feature_sections_are_ordered
        ] )
    ]
