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

let () =
  Alcotest.run "tui-markdown"
    [ ( "inline"
      , [ Alcotest.test_case "a link keeps both halves" `Quick
            test_link_keeps_both_halves
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
