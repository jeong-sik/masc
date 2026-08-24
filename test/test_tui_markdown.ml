(* Markdown as terminal rows. The palette is spelled with tags rather than
   escapes so a test says which styling was applied, not which bytes. *)

module Markdown = Masc_tui_markdown

let tagged : Markdown.palette =
  { strong = ("<b>", "</b>")
  ; emphasis = ("<i>", "</i>")
  ; code = ("<c>", "</c>")
  ; heading = ("<h>", "</h>")
  ; quote = ("<q>", "</q>")
  ; link_text = ("<a>", "</a>")
  ; link_target = ("<u>", "</u>")
  ; rule = ("<r>", "</r>")
  ; bullet = "\xe2\x80\xa2"
  ; code_gutter = "\xe2\x94\x82 "
  ; quote_gutter = "\xe2\x96\x8f "
  }

let render ?(width = 40) ?(palette = tagged) text =
  Markdown.render ~palette ~width text

let check_rows label expected actual =
  Alcotest.(check (list string)) label expected actual

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

let test_heading_drops_its_hashes () =
  check_rows "atx heading" [ "<h>Findings</h>" ] (render "## Findings");
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
   fencing, so fenced lines keep their own breaks. *)
let test_fenced_code_keeps_its_line_breaks () =
  check_rows "fence"
    [ "<c>\xe2\x94\x82 let x = 1</c>"; "<c>\xe2\x94\x82 let y = 2</c>" ]
    (render "```ocaml\nlet x = 1\nlet y = 2\n```")

let test_fence_markers_are_not_drawn () =
  Alcotest.(check bool)
    "no backtick rows" false
    (List.exists
       (fun row -> String.length row > 0 && String.contains row '`')
       (render "```\ncode\n```"))

let test_unclosed_fence_still_renders_its_body () =
  check_rows "runs to the end"
    [ "<c>\xe2\x94\x82 orphan</c>" ]
    (render "```\norphan")

let test_tilde_fence_is_a_fence () =
  check_rows "tilde"
    [ "<c>\xe2\x94\x82 body</c>" ]
    (render "~~~\nbody\n~~~")

(* Inside a fence, a line that looks like a heading or a bullet is code. *)
let test_fenced_content_is_not_reparsed () =
  check_rows "markers are code"
    [ "<c>\xe2\x94\x82 # not a heading</c>"; "<c>\xe2\x94\x82 - not a bullet</c>" ]
    (render "```\n# not a heading\n- not a bullet\n```")

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
      , [ Alcotest.test_case "a heading drops its hashes" `Quick
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
