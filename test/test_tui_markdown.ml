(* Markdown as terminal rows. The palette is spelled with tags rather than
   escapes so a test says which styling was applied, not which bytes. *)

module Markdown = Masc_tui_markdown

let tagged : Markdown.palette =
  { strong = ("<b>", "</b>")
  ; emphasis = ("<i>", "</i>")
  ; strike = ("<s>", "</s>")
  ; code = ("<c>", "</c>")
    (* The level is in the tag so a test can say which heading it got. *)
  ; heading = (fun level -> (Printf.sprintf "<h%d>" level, Printf.sprintf "</h%d>" level))
  ; quote = ("<q>", "</q>")
  ; link_text = ("<a>", "</a>")
  ; link_target = ("<u>", "</u>")
  ; rule = ("<r>", "</r>")
  ; bullet = "\xe2\x80\xa2"
  ; code_gutter = "\xe2\x94\x82 "
  ; code_header = ("<ch>", "</ch>")
  ; code_border = ("<cb>", "</cb>")
  ; quote_gutter = "\xe2\x96\x8f "
  ; table_header = ("<th>", "</th>")
  ; table_gutter = " | "
  ; table_rule_gutter = "\xe2\x94\x80\xe2\x94\xbc\xe2\x94\x80"
  ; table_frame = false
  ; code_keyword = ("<k>", "</k>")
  ; code_string = ("<s>", "</s>")
  ; code_comment = ("<m>", "</m>")
  ; code_number = ("<n>", "</n>")
  ; code_type = ("<t>", "</t>")
  ; code_diff_added = ("<+>", "</+>")
  ; code_diff_removed = ("<->", "</->")
  }

let render ?(width = 40) ?(palette = tagged) text =
  Markdown.render ~palette ~width text

let check_rows label expected actual =
  Alcotest.(check (list string)) label expected actual

let segments_testable =
  Alcotest.(list (pair string string))

(* {1 Inline markers} *)

let test_link_keeps_both_halves () =
  Alcotest.(check segments_testable)
    "label and target"
    [ ("see ", "plain")
    ; ("the PR", "link_text")
    ; (" (https://x/1)", "link_target")
    ]
    (Markdown.inline_segments "see [the PR](https://x/1)")

let test_plain_segments_keep_exact_spacing () =
  Alcotest.(check segments_testable)
    "plain Board comment"
    [ (" Comment 000  body ", "plain") ]
    (Markdown.inline_segments " Comment 000  body ")

let test_inline_segments_names_each_marker () =
  Alcotest.(check segments_testable)
    "one of each"
    [ ("a ", "plain")
    ; ("b", "strong")
    ; (" ", "plain")
    ; ("c", "emphasis")
    ; (" ", "plain")
    ; ("d", "code")
    ]
    (Markdown.inline_segments "a **b** *c* `d`")

(* {1 Blocks} *)

let check_stream_boundary label ~source_start ~row_start source =
  let streamed = Markdown.render_streaming ~palette:tagged ~width:40 source in
  check_rows (label ^ " rows") (render source) streamed.rows;
  Alcotest.(check int) (label ^ " source boundary") source_start
    streamed.mutable_source_start;
  Alcotest.(check int) (label ^ " row boundary") row_start
    streamed.mutable_row_start

let test_streaming_boundary_keeps_only_closed_blocks () =
  check_stream_boundary "one newline keeps its line mutable" ~source_start:0
    ~row_start:0 "alpha\n";
  check_stream_boundary "the previous line closes when the next one arrives"
    ~source_start:6 ~row_start:1 "alpha\nbeta\n";
  check_stream_boundary "ordinary prose before an incomplete line is closed"
    ~source_start:6 ~row_start:1 "alpha\nbeta";
  check_stream_boundary "a partial delimiter keeps its header mutable"
    ~source_start:0 ~row_start:0 "| h |\n|";
  check_stream_boundary "a growing table stays wholly mutable" ~source_start:7
    ~row_start:1 "before\n| h |\n| - |\n| a |\n";
  check_stream_boundary "an incomplete possible row keeps its table mutable"
    ~source_start:0 ~row_start:0 "| h |\n| - |\nafter";
  check_stream_boundary "an appended pipe row still belongs to its table"
    ~source_start:0 ~row_start:0 "| h |\n| - |\nafter | x |";
  check_stream_boundary "the table closes when following prose arrives"
    ~source_start:25 ~row_start:4
    "before\n| h |\n| - |\n| a |\nafter\n";
  check_stream_boundary "an open tagged fence stays wholly mutable"
    ~source_start:7 ~row_start:1 "before\n```ocaml\nlet x = 1\n";
  check_stream_boundary "a closed final fence is still the mutable final block"
    ~source_start:7 ~row_start:1 "before\n```ocaml\nlet x = 1\n```\n";
  check_stream_boundary "following prose closes the fence block"
    ~source_start:30 ~row_start:4
    "before\n```ocaml\nlet x = 1\n```\nafter\n"

let test_inline_source_spans_survive_reflow () =
  let render width text = Markdown.render_inline_with_spans
    ~palette:tagged ~width ~prefix:"" ~continuation:"" text in
  let narrow = render 4 "foo bar foobar" in
  let wide = render 40 "foo bar foobar" in
  Alcotest.(check string) "canonical spaces survive physical wrapping"
    "foo bar foobar" narrow.semantic_text;
  Alcotest.(check string) "canonical stream is independent of width"
    narrow.semantic_text wide.semantic_text;
  let ranges result = List.map (fun (row : Markdown.mapped_row) ->
    List.map (fun (span : Markdown.source_range) -> span.start_byte, span.end_byte)
      row.source_ranges) result.Markdown.mapped_rows in
  Alcotest.(check (list (list (pair int int)))) "split words retain exact source ranges"
    [[0,3]; [4,7]; [8,12]; [12,14]] (ranges narrow);
  let last_row_for_byte result byte = List.find_index (fun (row : Markdown.mapped_row) ->
    List.exists (fun (span : Markdown.source_range) ->
      span.start_byte <= byte && byte < span.end_byte) row.source_ranges) result.Markdown.mapped_rows in
  Alcotest.(check (option int)) "literal endpoint maps to its narrow row" (Some 3)
    (last_row_for_byte narrow 13);
  Alcotest.(check (option int)) "same endpoint maps to its wide row" (Some 0)
    (last_row_for_byte wide 13);
  List.iter (fun source -> List.iter (fun width ->
    let result = render width source in
    Alcotest.(check (list string)) "span production leaves display bytes unchanged"
      (Markdown.render ~palette:tagged ~width source)
      (List.map (fun (row : Markdown.mapped_row) -> row.text) result.mapped_rows);
    let occurrences = Array.make (String.length result.semantic_text) 0 in
    List.iter (fun (row : Markdown.mapped_row) ->
      List.iter (fun (span : Markdown.source_range) ->
        for byte = span.start_byte to span.end_byte - 1 do
          occurrences.(byte) <- occurrences.(byte) + 1
        done) row.source_ranges) result.mapped_rows;
    String.iteri (fun byte char ->
      if char <> ' ' then Alcotest.(check int) "each semantic byte is mapped once" 1 occurrences.(byte))
      result.semantic_text
  ) [1;4;12;80]) ["**styled** and `code`"; "  indented longwordlongword";
    "한글문장 wrapped text"; "[visible](https://example.test)"];
  let prefixed = Markdown.render_inline_with_spans ~palette:tagged ~width:8
    ~prefix:"│ " ~continuation:"│ " "abcdefghi" in
  Alcotest.(check string) "generated gutters are not semantic source"
    "abcdefghi" prefixed.semantic_text;
  Alcotest.(check bool) "continuation prefix still draws" true
    (List.for_all (fun (row : Markdown.mapped_row) -> String.starts_with ~prefix:"│ " row.text)
      prefixed.mapped_rows)

let test_block_and_table_source_spans () =
  List.iter (fun source -> List.iter (fun width ->
    let mapped = Markdown.render_block_with_spans ~palette:tagged ~width source in
    Alcotest.(check (list string)) "block map shares display geometry"
      (Markdown.render ~palette:tagged ~width source) mapped.block_rows;
    match mapped.inline_source with
    | None -> Alcotest.fail "text block must retain its inline source"
    | Some inline ->
        Alcotest.(check string) "block syntax does not become searchable source"
          "foo bar foobar" inline.semantic_text;
        Alcotest.(check int) "inline spans correspond to final block rows"
          (List.length mapped.block_rows) (List.length inline.mapped_rows)
  ) [4;16;80]) ["# foo bar foobar"; "> foo bar foobar";
    "- foo bar foobar"; "1. foo bar foobar"];
  let rule = Markdown.render_block_with_spans ~palette:tagged ~width:20 "---" in
  Alcotest.(check bool) "generated rule has no semantic span" true (Option.is_none rule.inline_source);
  let source = "| Heading | Other |\n| --- | --- |\n| **longwordlongword** | 한글문장 |" in
  List.iter (fun framed ->
    let palette = {Markdown.plain_palette with table_frame=framed} in
    let get width = match Markdown.render_table_with_spans ~palette ~width source with
      | Some mapped -> mapped | None -> Alcotest.fail "table must map" in
    let narrow = get 16 and wide = get 80 in
    let identity (cell : Markdown.table_cell_source) =
      cell.table_row, cell.table_column, cell.cell_text in
    Alcotest.(check bool) "source cell identities survive truncation" true
      (List.map identity narrow.cell_sources = List.map identity wide.cell_sources);
    List.iter (fun (width, mapped) ->
      Alcotest.(check (list string)) "mapped table matches ordinary display rows"
        (Markdown.render ~palette ~width source) mapped.Markdown.table_rows;
      List.iter (fun (cell : Markdown.table_cell_source) ->
        let expected_row = if cell.table_row=0 then (if framed then 1 else 0)
          else cell.table_row + (if framed then 2 else 1) in
        Alcotest.(check int) "cell maps past generated borders" expected_row cell.rendered_row;
        Alcotest.(check int) "source starts at cell byte zero" 0 cell.visible_range.start_byte;
        Alcotest.(check bool) "visible prefix lies inside semantic cell" true
          (cell.visible_range.end_byte <= String.length cell.cell_text)) mapped.cell_sources)
      [16,narrow;80,wide];
    let body_cell table = List.find (fun (cell : Markdown.table_cell_source) ->
      cell.table_row=1 && cell.table_column=0) table.Markdown.cell_sources in
    Alcotest.(check bool) "narrow cell excludes truncated source suffix" true
      ((body_cell narrow).visible_range.end_byte < (body_cell wide).visible_range.end_byte)
  ) [false;true];
  let ansi_palette = {Markdown.plain_palette with strong=("\027[1m", "\027[0m")} in
  (match Markdown.render_table_with_spans ~palette:ansi_palette ~width:8
      "| H |\n| --- |\n| **abcdefghijklmnop** |" with
   | None -> Alcotest.fail "ANSI table must map"
   | Some mapped ->
       let cell = List.find (fun (cell : Markdown.table_cell_source) -> cell.table_row=1)
         mapped.cell_sources in
       Alcotest.(check int) "ANSI bold cut excludes ellipsis from source" 7 cell.visible_range.end_byte;
       Alcotest.(check string) "actual ANSI-styled fitting retains the mapped prefix"
         "abcdefg…" (Masc_tui_theme.strip_sgr (List.nth mapped.table_rows cell.rendered_row)));
  Alcotest.(check bool) "not a table is explicit" true
    (Option.is_none (Markdown.render_table_with_spans ~palette:tagged ~width:80 "ordinary text"))

let test_table_original_source_positions () =
  let fixtures = [
    "  | **Heading** | Other | \n| :--- | ---: |\n| alpha | beta | overflow |\n| short |";
    " First | Centre | Last \n :--- | :---: | ---: \n a | **b** | [link](target) ";
    "| A | B |\n| --- | --- |\n| 한글 | é |";
    "| A | B |\n| --- | --- |\n| | empty |";
  ] in
  List.iter (fun source -> List.iter (fun framed ->
    let palette={Markdown.plain_palette with table_frame=framed; strong=("\027[1m", "\027[0m")} in
    let mapped width = match Markdown.render_table_with_spans ~palette ~width source with
      | Some table -> table | None -> Alcotest.fail "source table must map" in
    let wide=mapped 100 in
    List.iter (fun width ->
      let table=mapped width in
      Alcotest.(check (list string)) "source observer preserves table rows"
        (Markdown.render ~palette ~width source) table.table_rows;
      List.iter2 (fun (cell : Markdown.table_cell_source) (stable : Markdown.table_cell_source) ->
        Alcotest.(check bool) "original source byte map is width independent" true
          (cell.cell_text=stable.cell_text && cell.source_positions=stable.source_positions);
        Alcotest.(check int) "one source position per semantic byte"
          (String.length cell.cell_text) (Array.length cell.source_positions);
        Array.iteri (fun byte -> function None -> () | Some at ->
          Alcotest.(check char) "semantic byte comes from exact original table byte"
            cell.cell_text.[byte] source.[at]) cell.source_positions;
        let row=Masc_tui_theme.strip_sgr (List.nth table.table_rows cell.rendered_row) in
        let _, from_cell=Masc_tui_message_layout.split_at_cells row cell.rendered_start_cell in
        let visible=String.sub cell.cell_text 0 cell.visible_range.end_byte in
        Alcotest.(check bool) "formatter placement selects actual surviving cell prefix" true
          (String.starts_with ~prefix:visible from_cell)) table.cell_sources wide.cell_sources)
      [12;30;100]) [false;true]) fixtures;
  match Markdown.render_table_with_spans ~palette:Markdown.plain_palette ~width:100
      "| A | B |\n| --- | --- |\n| x | y | z |" with
  | None -> Alcotest.fail "overflow table must map"
  | Some table ->
      let joined=List.find (fun (cell : Markdown.table_cell_source) -> cell.table_row=1 && cell.table_column=1) table.cell_sources in
      Alcotest.(check string) "overflow cells retain existing normalization" "y z" joined.cell_text;
      Alcotest.(check bool) "overflow join space is generated" true (joined.source_positions.(1)=None)

let test_document_semantic_visibility () =
  let fixtures = [
    "# Title\n- foo bar foobar\n> quoted **text**\n\n| A | B |\n| --- | ---: |\n| longwordlongword | value |\nend";
    "before\n```ocaml\nlet value = \"a string\"\n(* comment\ncontinued *)\n```\nafter";
    "```diff\n-old text\n+new text\n unchanged\n```";
    "```plain\n  long literal text with spaces\n\nend\n```";
    "```mermaid\nflowchart LR\nA[repeat] -->|edge| B[repeat]\n```";
    "```mermaid\nsequenceDiagram\nparticipant A as Alice\nparticipant B as Bob\nalt chosen\nA->>B: hello\nelse other\nB->>A: bye\nend\n```";
    "```mermaid\nclassDiagram\nA <|-- B\n```";
    "```ocaml\nlet unfinished =";
    "one line";
  ] in
  List.iter (fun source -> List.iter (fun width ->
    let palette=Markdown.plain_palette in
    let mapped=Markdown.render_document_with_spans ~palette ~width source in
    Alcotest.(check (list string)) "document observation leaves display unchanged"
      (Markdown.render ~palette ~width source) mapped.document_rows;
    Alcotest.(check bool) "supported provenance is complete" true (mapped.mapping=Complete_document);
    List.iter (fun (run : Markdown.semantic_run) ->
      Alcotest.(check int) "origin per semantic byte" (String.length run.semantic_text) (Array.length run.origins);
      Array.iteri (fun byte -> function
        | None -> ()
        | Some (Markdown.Generated _) -> ()
        | Some (Markdown.Original range) ->
            Alcotest.(check bool) "original range is in complete document" true
              (range.start_byte>=0 && range.end_byte<=String.length source && range.start_byte<range.end_byte);
            if range.end_byte=range.start_byte+1 then
              Alcotest.(check char) "semantic byte indexes original document" run.semantic_text.[byte] source.[range.start_byte]) run.origins;
      List.iter (fun (row,ranges) ->
        Alcotest.(check bool) "visibility points to a real display row" true
          (row>=0 && row<List.length mapped.document_rows);
        List.iter (fun (range : Markdown.source_range) ->
          Alcotest.(check bool) "visible range lies in semantic text" true
            (range.start_byte>=0 && range.end_byte<=String.length run.semantic_text && range.start_byte<=range.end_byte);
          let visible=String.sub run.semantic_text range.start_byte (range.end_byte-range.start_byte) in
          let actual=Masc_tui_theme.strip_sgr (List.nth mapped.document_rows row) in
          let rec contains at =
            at+String.length visible<=String.length actual
            && (String.sub actual at (String.length visible)=visible || contains (at+1)) in
          Alcotest.(check bool) "mapped visible bytes occur on the actual output row" true (contains 0)) ranges) run.visible_rows) mapped.semantic_runs
  ) [8;30;120]) fixtures;
  let source="```mermaid\nflowchart LR\nA[repeat] --> B[repeat]\n```" in
  let mapped width=Markdown.render_document_with_spans ~palette:Markdown.plain_palette ~width source in
  let wide=mapped 120 and narrow=mapped 8 in
  let drawn=List.find (fun (run : Markdown.semantic_run) -> run.semantic_text="repeat") wide.semantic_runs in
  Array.iter (function Some (Markdown.Original origin) ->
    Alcotest.(check bool) "diagram label origin remains in source fallback" true
      (List.exists (fun (run : Markdown.semantic_run) -> Array.exists (function
        | Some (Markdown.Original fallback) -> fallback=origin | _ -> false) run.origins) narrow.semantic_runs)
    | _ -> Alcotest.fail "diagram label must have original range") drawn.origins;
  Alcotest.(check bool) "fallback explanation keeps searchable typed identity" true
    (List.exists (fun (run : Markdown.semantic_run) -> Array.exists (function
      | Some (Markdown.Generated {field=Mermaid_diagnostic;_}) -> true | _ -> false) run.origins) narrow.semantic_runs)

let test_lexed_code_source_spans () =
  let module Lexer = Masc_tui_code_lexer in
  List.iter (fun pieces -> List.iter (fun width ->
    let mapped = Markdown.render_lexed_line_with_spans ~palette:Markdown.plain_palette ~width pieces in
    let source = String.concat "" (List.map fst pieces) in
    Alcotest.(check string) "code semantic bytes preserve indentation and spaces"
      source mapped.semantic_text;
    let cursor = ref 0 in
    List.iter (fun (row : Markdown.mapped_row) ->
      List.iter (fun (span : Markdown.source_range) ->
        Alcotest.(check int) "code slices remain contiguous through wraps" !cursor span.start_byte;
        cursor := span.end_byte) row.source_ranges) mapped.mapped_rows;
    Alcotest.(check int) "all code bytes mapped exactly once" (String.length source) !cursor;
    Alcotest.(check bool) "repeated code gutters remain display only" true
      (List.for_all (fun (row : Markdown.mapped_row) ->
         String.starts_with ~prefix:Markdown.plain_palette.code_gutter row.text) mapped.mapped_rows)
  ) [4;12;80]) [
    ["  let ",Lexer.kind_code; "가나다",Lexer.kind_string; " = 42",Lexer.kind_number];
    ["+ long added line",Lexer.kind_diff_added];
    ["+",Lexer.kind_diff_added; "let ",Lexer.kind_keyword; "name = 42",Lexer.kind_code]]

let test_inline_raw_source_positions () =
  let render text = Markdown.render_inline_with_spans
    ~palette:Markdown.plain_palette ~width:4 ~prefix:"" ~continuation:"" text in
  let bold = render "**foo** bar" in
  Alcotest.(check (array (option int))) "inline markup maps to original bytes"
    [|Some 2;Some 3;Some 4;Some 7;Some 8;Some 9;Some 10|] bold.source_positions;
  let link = render "[x](url)" in
  Alcotest.(check (array (option int))) "generated link separator has no source byte"
    [|Some 1;None;Some 3;Some 4;Some 5;Some 6;Some 7|] link.source_positions;
  List.iter (fun (line, expected_start) ->
    let block = Markdown.render_block_with_spans ~palette:Markdown.plain_palette ~width:8 line in
    match block.inline_source with
    | None -> Alcotest.fail "source-bearing block expected"
    | Some inline ->
        Alcotest.(check (option int)) "block grammar retains original line byte offset"
          (Some expected_start) inline.source_positions.(0);
        Array.iteri (fun byte -> function None -> () | Some source ->
          Alcotest.(check char) "block mapping composes syntax and inline offsets"
            line.[source] inline.semantic_text.[byte]) inline.source_positions
  ) ["#  **foo**",5; ">foo",1; "  >   **foo** ",8;
     "- **foo**",4; "  12) **foo**",8; "# \011foo\012",2];
  let cut = render "**foo" in
  Alcotest.(check (option int)) "closing marker disappearing does not move foo's source start"
    bold.source_positions.(0) cut.source_positions.(2);
  List.iter (fun text ->
    let mapped = render text in
    Alcotest.(check int) "every semantic byte has a mapping slot"
      (String.length mapped.semantic_text) (Array.length mapped.source_positions);
    Array.iteri (fun byte -> function
      | None -> ()
      | Some source -> Alcotest.(check char) "mapped bytes come from exact source"
          text.[source] mapped.semantic_text.[byte]) mapped.source_positions)
    ["plain text"; "**strong** and _emphasis_"; "[한글](https://example.test)";
     "unpaired **marker"; "__styled__ snake_case"; "~~old~~ `code`"]

let () =
  Alcotest.run "tui-markdown"
    [ ( "inline"
      , [ Alcotest.test_case "a link keeps both halves" `Quick
            test_link_keeps_both_halves
        ; Alcotest.test_case "inline original byte positions" `Quick test_inline_raw_source_positions
        ; Alcotest.test_case "lexed code source spans" `Quick test_lexed_code_source_spans
        ; Alcotest.test_case "document semantic visibility" `Quick test_document_semantic_visibility
        ; Alcotest.test_case "table original source positions" `Quick test_table_original_source_positions
        ; Alcotest.test_case "block and table source spans" `Quick test_block_and_table_source_spans
        ; Alcotest.test_case "inline source spans survive reflow" `Quick test_inline_source_spans_survive_reflow
        ; Alcotest.test_case "plain segments keep exact spacing" `Quick
            test_plain_segments_keep_exact_spacing
        ; Alcotest.test_case "segments name each marker" `Quick
            test_inline_segments_names_each_marker
        ] )
    ; ( "blocks"
      , [ Alcotest.test_case "streaming keeps only closed blocks" `Quick
            test_streaming_boundary_keeps_only_closed_blocks
        ] )
    ; ( "fenced code"
      , [] )
    ; ( "fenced highlighting"
      , [] )
    ; ( "width"
      , [] )
    ; ( "strike"
      , [] )
    ]
