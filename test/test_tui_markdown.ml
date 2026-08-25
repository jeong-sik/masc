(* Markdown as terminal rows. The palette is spelled with tags rather than
   escapes so a test says which styling was applied, not which bytes. *)

module Markdown = Masc_tui_markdown

let tagged : Markdown.palette =
  { strong = ("<b>", "</b>")
  ; emphasis = ("<i>", "</i>")
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
  ; code_keyword = ("<k>", "</k>")
  ; code_string = ("<s>", "</s>")
  ; code_comment = ("<m>", "</m>")
  ; code_number = ("<n>", "</n>")
  ; code_type = ("<t>", "</t>")
  }

let render ?(width = 40) ?(palette = tagged) text =
  Markdown.render ~palette ~width text

let check_rows label expected actual =
  Alcotest.(check (list string)) label expected actual

let horizontal cells =
  String.concat "" (List.init cells (fun _ -> "\xe2\x94\x80"))

let tagged_fence ?(width = 40) language body =
  let stem = "\xe2\x94\x8c\xe2\x94\x80 " ^ language ^ " " in
  let header =
    "<ch>" ^ stem
    ^ horizontal (width - Masc_tui_message_layout.display_width stem)
    ^ "</ch>"
  in
  let footer = "<cb>\xe2\x94\x94" ^ horizontal (width - 1) ^ "</cb>" in
  header :: body @ [ footer ]

let segments_testable =
  Alcotest.(list (pair string string))

(* {1 Inline markers} *)

(* The marker is the noise: a backticked identifier should read as the
   identifier, styled, not as a quotation with two stray backticks. *)
let test_inline_code_loses_its_backticks () =
  check_rows "code span" [ "run <c>keeper_tasks_list</c> first" ]
    (render "run `keeper_tasks_list` first")

let test_strong_and_emphasis () =
  check_rows "double marker is strong" [ "a <b>bold</b> word" ]
    (render "a **bold** word");
  check_rows "underscore pair is strong" [ "a <b>bold</b> word" ]
    (render "a __bold__ word");
  check_rows "single marker is emphasis" [ "a <i>soft</i> word" ]
    (render "a *soft* word")

(* An unpaired marker is a character a keeper typed. Treating it as an opener
   swallows the rest of the line into a style that never closes. *)
let test_unpaired_marker_stays_literal () =
  check_rows "lone asterisk" [ "2 * 3 = 6" ] (render "2 * 3 = 6");
  check_rows "lone backtick" [ "a ` here" ] (render "a ` here");
  check_rows "trailing marker" [ "ends with *" ] (render "ends with *")

(* Half this workspace's chat is snake_case. Pairing the underscores in
   [keeper_tool_descriptor_registry_integrity] ate them and italicised the
   middle, so an identifier arrived on screen as a different identifier. *)
let test_snake_case_keeps_its_underscores () =
  check_rows "identifier survives"
    [ "run keeper_tool_descriptor_registry_integrity now" ]
    (render ~width:60 "run keeper_tool_descriptor_registry_integrity now");
  check_rows "double underscore inside a word too"
    [ "see masc__internal here" ]
    (render "see masc__internal here")

(* A word boundary is still a boundary: emphasis written the ordinary way
   keeps working. *)
let test_underscore_emphasis_still_works_between_words () =
  check_rows "flanked by spaces" [ "a <i>soft</i> word" ]
    (render "a _soft_ word");
  check_rows "before punctuation" [ "a <i>soft</i>, then" ]
    (render "a _soft_, then");
  check_rows "double marker between words" [ "a <b>bold</b> word" ]
    (render "a __bold__ word")

(* A terminal cannot follow a link, so the target is the half that has to
   survive. *)
let test_link_keeps_both_halves () =
  Alcotest.(check segments_testable)
    "label and target"
    [ ("see ", "plain"); ("the PR", "link_text"); ("https://x/1", "link_target") ]
    (Markdown.inline_segments "see [the PR](https://x/1)")

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

(* Which heading is inside which is the only thing a level says, and it used
   to be parsed and thrown away: every heading in a keeper's answer came out
   drawn the same, so a document arrived with no shape. *)
let test_a_heading_carries_its_level () =
  check_rows "top level" [ "<h1>Findings</h1>" ] (render "# Findings");
  check_rows "third level" [ "<h3>Findings</h3>" ] (render "### Findings");
  check_rows "sixth level" [ "<h6>Findings</h6>" ] (render "###### Findings");
  check_rows "seven hashes is not a heading" [ "####### Findings" ]
    (render "####### Findings")
;;

(* Keepers answer in tables. Without this the source arrived as its own
   pipes, one row per line, each one fitted and marked truncated -- the
   least readable form of the most structured thing they write. *)
let test_a_table_becomes_columns () =
  check_rows "header, rule, and body"
    [ "<th>kind  | count</th>"
    ; "<r>\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80 | \xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80</r>"
    ; "bug   |     3"
    ; "spike |    12"
    ]
    (render ~width:40
       "| kind | count |\n| --- | ----: |\n| bug | 3 |\n| spike | 12 |")
;;

let test_a_table_needs_its_delimiter_row () =
  (* An OCaml match arm pasted outside a fence is not a table. *)
  check_rows "pipes alone are not a table" [ "| Some x -> y" ]
    (render "| Some x -> y")
;;

let test_a_table_column_gives_up_cells_to_fit () =
  (* The widest column shrinks first: taking it evenly would cut a column
     that costs nothing to keep. *)
  check_rows "the wide column is the one that loses"
    [ "<th>id | what           </th>"
    ; "<r>\xe2\x94\x80\xe2\x94\x80 | \xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80</r>"
    ; "a1 | a very long ce~"
    ]
    (render ~width:20 "| id | what |\n| -- | ---- |\n| a1 | a very long cell |")
;;


let test_heading_drops_its_hashes () =
  check_rows "atx heading" [ "<h2>Findings</h2>" ] (render "## Findings");
  check_rows "a hash without a space is not a heading" [ "#29655 is open" ]
    (render "#29655 is open")

let test_bullets_are_normalised_and_hang () =
  check_rows "bullet and hanging indent"
    [ "\xe2\x80\xa2 one two three four five six"; "  seven" ]
    (render ~width:30 "- one two three four five six seven")

let test_ordered_items_keep_their_number () =
  check_rows "ordered marker survives"
    [ "1. first"; "2. second" ]
    (render "1. first\n2. second")

let test_quote_gets_a_gutter () =
  check_rows "blockquote"
    [ "<q>\xe2\x96\x8f quoted</q>" ]
    (render "> quoted")

let test_rule_fills_the_width () =
  match render ~width:6 "---" with
  | [ row ] ->
      Alcotest.(check string) "rule row" "<r>\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80</r>" row
  | rows -> Alcotest.fail (Printf.sprintf "expected one row, got %d" (List.length rows))

(* {1 Fenced code} *)

(* Wrapping a diff at a word boundary destroys the alignment that made it worth
   fencing, so fenced lines keep their own breaks. An [ocaml] tag also
   colours: reserved words as keywords, literals as numbers. *)
let test_fenced_code_keeps_its_line_breaks () =
  check_rows "fence"
    (tagged_fence "ocaml"
       [ "\xe2\x94\x82 <k>let</k><c> x = </c><n>1</n>"
       ; "\xe2\x94\x82 <k>let</k><c> y = </c><n>2</n>"
       ])
    (render "```ocaml\nlet x = 1\nlet y = 2\n```")

(* {1 Fenced-code highlighting} *)

(* The tag decides: the same body, untagged, stays the single code span --
(* colouring a grammar nobody lexed is decoration pretending to be
   syntax. *) *)
let test_untagged_fence_stays_single_span () =
  check_rows "no tag, no colour" [ "<c>\xe2\x94\x82 let x = 1</c>" ]
    (render "```\nlet x = 1\n```")

let test_unknown_language_stays_single_span () =
  check_rows "unknown tag, no colour"
    (tagged_fence "rust" [ "<c>\xe2\x94\x82 fn main() {}</c>" ])
    (render "```rust\nfn main() {}\n```")

(* Strings, and a capitalised identifier as a constructor or module. *)
let test_ocaml_strings_and_types () =
  check_rows "string and constructor"
    (tagged_fence "ocaml"
       [ "\xe2\x94\x82 <k>let</k><c> name = </c><s>\"polisher\"</s>"
       ; "\xe2\x94\x82 <k>match</k><c> x </c><k>with</k><c> </c><t>Some</t><c> y -> y</c>"
       ])
    (render "```ocaml\nlet name = \"polisher\"\nmatch x with Some y -> y\n```")

(* A comment opened on one row and closed on a later one colours every row it
   covers: the lexer reads the body whole for exactly this. *)
let test_ocaml_comment_spans_rows () =
  check_rows "comment covers its rows"
    (tagged_fence "ocaml"
       [ "\xe2\x94\x82 <m>(* opened here</m>"
       ; "\xe2\x94\x82 <m>   and closed here *)</m>"
       ; "\xe2\x94\x82 <k>let</k><c> x = </c><n>1</n>"
       ])
    (render "```ocaml\n(* opened here\n   and closed here *)\nlet x = 1\n```")

(* JSON: a key reads as a field, a string as a string, a number as a
   number. *)
let test_json_keys_strings_numbers () =
  check_rows "json row"
    (tagged_fence "json"
       [ "\xe2\x94\x82 <c>{</c><t>\"name\"</t><c>: </c><s>\"alpha\"</s><c>, </c><t>\"turns\"</t><c>: </c><n>42</n><c>}</c>"
       ])
    (render "```json\n{\"name\": \"alpha\", \"turns\": 42}\n```")

(* Bash: strings stay strings, a [#] that starts a word comments to the row's
   end. *)
let test_bash_comment_and_string () =
  check_rows "bash row"
    (tagged_fence ~width:60 "bash"
       [ "\xe2\x94\x82 <c>dune build </c><s>\"--root\"</s><c> . </c><m># from the runbook</m>"
       ])
    (render ~width:60 "```bash\ndune build \"--root\" . # from the runbook\n```")

let test_fence_markers_are_not_drawn () =
  Alcotest.(check bool)
    "no backtick rows" false
    (List.exists
       (fun row -> String.length row > 0 && String.contains row '`')
       (render "```\ncode\n```"))

let test_unclosed_fence_still_renders_its_body () =
  check_rows "runs to the end"
    [ "<c>\xe2\x94\x82 orphan</c>" ]
    (render "```\norphan");
  let framed_without_footer =
    match tagged_fence "bash" [ "\xe2\x94\x82 <c>orphan</c>" ] with
    | [] -> assert false
    | rows -> List.rev (List.tl (List.rev rows))
  in
  check_rows "an open tagged fence has no false closing border"
    framed_without_footer
    (render "```bash\norphan")

let test_tilde_fence_is_a_fence () =
  check_rows "tilde"
    [ "<c>\xe2\x94\x82 body</c>" ]
    (render "~~~\nbody\n~~~")

(* Inside a fence, a line that looks like a heading or a bullet is code. *)
let test_fenced_content_is_not_reparsed () =
  check_rows "markers are code"
    [ "<c>\xe2\x94\x82 # not a heading</c>"; "<c>\xe2\x94\x82 - not a bullet</c>" ]
    (render "```\n# not a heading\n- not a bullet\n```")

(* This line is from a live Keeper reply (message
   [msg-1787516761351436-321]).
   The tagged lexer used to split it and immediately concatenate the chunks
   back into one terminal row. The outer frame then cut off the branch name. *)
let test_a_tagged_live_code_line_keeps_every_chunk () =
  let width = 48 in
  let source =
    "cd <task478 worktree path>   # \xec\xa0\x80\xeb\x8f\x84 \xea\xb2\xbd\xeb\xa1\x9c\xeb\xa5\xbc \xec\x9e\x83\xec\x96\xb4\xeb\xb2\x84\xeb\xa0\xb8\xec\x8a\xb5\xeb\x8b\x88\xeb\x8b\xa4 \xe2\x80\x94 branch: task478-server-unreadable-store"
  in
  let rendered =
    render ~width ~palette:Markdown.plain_palette
      ("```bash\n" ^ source ^ "\n```\nafter the fence")
  in
  let expected_code_rows =
    Masc_tui_message_layout.split_cells
      ~max_cells:(width - Masc_tui_message_layout.display_width "| ")
      source
    |> List.map (fun chunk -> "| " ^ chunk)
  in
  let header =
    let stem = "\xe2\x94\x8c\xe2\x94\x80 bash " in
    stem ^ horizontal (width - Masc_tui_message_layout.display_width stem)
  in
  let footer = "\xe2\x94\x94" ^ horizontal (width - 1) in
  check_rows "every split chunk is its own row"
    (header :: expected_code_rows @ [ footer; "after the fence" ])
    rendered;
  let actual_code_rows =
    List.filter
      (fun row -> String.length row >= 2 && String.sub row 0 2 = "| ")
      rendered
  in
  Alcotest.(check string) "every source scalar survives" source
    (actual_code_rows
     |> List.map (fun row -> String.sub row 2 (String.length row - 2))
     |> String.concat "");
  List.iter
    (fun row ->
       Alcotest.(check bool) "row stays inside the terminal budget" true
         (Masc_tui_message_layout.display_width row <= width))
    rendered;
  Alcotest.(check string) "the next prose row is unstyled" "after the fence"
    (List.hd (List.rev rendered))
;;

(* {1 Width} *)

(* Every row has to fit the frame it is drawn in; one that does not pushes the
   border off the screen. Measured on the plain palette, whose spans are empty:
   real styling is renderer-owned ANSI and costs no cells either, but the
   tagged palette above spells its spans as ordinary text that does. *)
let test_no_row_exceeds_the_width () =
  let body =
    "# A heading long enough to wrap several times over a narrow frame\n\
     Normal **bold** text with `code` and [a link](https://example.invalid/path)\n\
     - a bullet item that also needs to wrap because it is quite long\n\
     > a quoted line that is likewise too long for the frame to hold\n\
     ```\n\
     an unwrappable fenced line that simply runs on and on and on\n\
     ```\n\
     supercalifragilisticexpialidocioussupercalifragilisticexpialidocious"
  in
  List.iter
    (fun width ->
       List.iter
         (fun row ->
            let cells = Masc_tui_message_layout.display_width row in
            Alcotest.(check bool)
              (Printf.sprintf "width %d row %S is %d cells" width row cells)
              true (cells <= width))
         (render ~width ~palette:Markdown.plain_palette body))
    [ 12; 20; 40; 80 ]

(* The tail of a split word stays open, so the next word joins it. Closing the
   row after every chunk left one-character rows with the following word
   stranded below them. *)
let test_a_word_after_a_split_joins_the_tail () =
  check_rows "tail keeps company"
    [ "aaaaaaaaaa"; "aa bb" ]
    (render ~width:10 ~palette:Markdown.plain_palette "aaaaaaaaaaaa bb")

(* A word wider than the row is split rather than allowed to overflow, and no
   part of it is lost. *)
let test_an_overlong_word_is_split_without_loss () =
  let word = String.concat "" (List.init 12 (fun _ -> "abcde")) in
  let rows = render ~width:10 ~palette:Markdown.plain_palette word in
  Alcotest.(check string) "every character survives" word
    (String.concat "" rows)

(* {1 Plain reading} *)

let test_plain_palette_leaves_readable_text () =
  check_rows "no styling, markers still gone"
    [ "a bold word with code" ]
    (render ~palette:Markdown.plain_palette "a **bold** word with `code`")

let test_blank_lines_are_kept () =
  check_rows "paragraph break survives"
    [ "one"; ""; "two" ]
    (render "one\n\ntwo")

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
      , [ Alcotest.test_case "code loses its backticks" `Quick
            test_inline_code_loses_its_backticks
        ; Alcotest.test_case "strong and emphasis" `Quick
            test_strong_and_emphasis
        ; Alcotest.test_case "an unpaired marker stays literal" `Quick
            test_unpaired_marker_stays_literal
        ; Alcotest.test_case "snake_case keeps its underscores" `Quick
            test_snake_case_keeps_its_underscores
        ; Alcotest.test_case "underscore emphasis works between words" `Quick
            test_underscore_emphasis_still_works_between_words
        ; Alcotest.test_case "a link keeps both halves" `Quick
            test_link_keeps_both_halves
        ; Alcotest.test_case "segments name each marker" `Quick
            test_inline_segments_names_each_marker
        ] )
    ; ( "blocks"
      , [ Alcotest.test_case "a heading carries its level" `Quick
            test_a_heading_carries_its_level
        ; Alcotest.test_case "a table becomes columns" `Quick
            test_a_table_becomes_columns
        ; Alcotest.test_case "a table needs its delimiter row" `Quick
            test_a_table_needs_its_delimiter_row
        ; Alcotest.test_case "a table column gives up cells to fit" `Quick
            test_a_table_column_gives_up_cells_to_fit
        ; Alcotest.test_case "a heading drops its hashes" `Quick
            test_heading_drops_its_hashes
        ; Alcotest.test_case "bullets are normalised and hang" `Quick
            test_bullets_are_normalised_and_hang
        ; Alcotest.test_case "ordered items keep their number" `Quick
            test_ordered_items_keep_their_number
        ; Alcotest.test_case "a quote gets a gutter" `Quick
            test_quote_gets_a_gutter
        ; Alcotest.test_case "a rule fills the width" `Quick
            test_rule_fills_the_width
        ; Alcotest.test_case "blank lines are kept" `Quick
            test_blank_lines_are_kept
        ; Alcotest.test_case "streaming keeps only closed blocks" `Quick
            test_streaming_boundary_keeps_only_closed_blocks
        ] )
    ; ( "fenced code"
      , [ Alcotest.test_case "keeps its line breaks" `Quick
            test_fenced_code_keeps_its_line_breaks
        ; Alcotest.test_case "the markers are not drawn" `Quick
            test_fence_markers_are_not_drawn
        ; Alcotest.test_case "an unclosed fence renders its body" `Quick
            test_unclosed_fence_still_renders_its_body
        ; Alcotest.test_case "a tilde fence is a fence" `Quick
            test_tilde_fence_is_a_fence
        ; Alcotest.test_case "fenced content is not reparsed" `Quick
            test_fenced_content_is_not_reparsed
        ; Alcotest.test_case "a tagged live line keeps every chunk" `Quick
            test_a_tagged_live_code_line_keeps_every_chunk
        ] )
    ; ( "fenced highlighting"
      , [ Alcotest.test_case "no tag means no colour" `Quick
            test_untagged_fence_stays_single_span
        ; Alcotest.test_case "an unknown language means no colour" `Quick
            test_unknown_language_stays_single_span
        ; Alcotest.test_case "ocaml strings and constructors" `Quick
            test_ocaml_strings_and_types
        ; Alcotest.test_case "an ocaml comment covers its rows" `Quick
            test_ocaml_comment_spans_rows
        ; Alcotest.test_case "json keys, strings, numbers" `Quick
            test_json_keys_strings_numbers
        ; Alcotest.test_case "bash comment and string" `Quick
            test_bash_comment_and_string
        ] )
    ; ( "width"
      , [ Alcotest.test_case "no row exceeds the width" `Quick
            test_no_row_exceeds_the_width
        ; Alcotest.test_case "an overlong word is split without loss" `Quick
            test_an_overlong_word_is_split_without_loss
        ; Alcotest.test_case "a word after a split joins the tail" `Quick
            test_a_word_after_a_split_joins_the_tail
        ; Alcotest.test_case "the plain palette stays readable" `Quick
            test_plain_palette_leaves_readable_text
        ] )
    ]
