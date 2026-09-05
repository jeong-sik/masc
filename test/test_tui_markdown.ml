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

let horizontal cells =
  String.concat "" (List.init cells (fun _ -> "\xe2\x94\x80"))

(* The rule row as the renderer draws it: the columns' dashes joined at the
   boundary rather than by the gutter running through them. Spelled here
   independently of the palette so a change to the joiner fails a test rather
   than agreeing with itself. *)
let rule_row widths =
  "<r>"
  ^ String.concat "\xe2\x94\x80\xe2\x94\xbc\xe2\x94\x80"
      (List.map horizontal widths)
  ^ "</r>"

let tagged_fence ?(width = 40) language body =
  let stem = "\xe2\x94\x8c\xe2\x94\x80 " ^ language ^ " " in
  let header =
    "<ch>" ^ stem
    ^ horizontal (width - Masc_tui_message_layout.display_width stem)
    ^ "</ch>"
  in
  let footer = "<cb>\xe2\x94\x94" ^ horizontal (width - 1) ^ "</cb>" in
  header :: body @ [ footer ]

let tagged_band ~width opening closing content =
  opening ^ content
  ^ String.make
      (max 0 (width - Masc_tui_message_layout.display_width content))
      ' '
  ^ closing

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

let test_inline_closers_restore_the_ambient_row () =
  let restoring : Markdown.palette =
    { tagged with
      strong = ("<b>", "<restore>")
    ; code = ("<c>", "<restore>")
    ; link_text = ("<a>", "<restore>")
    ; link_target = ("<u>", "<restore>")
    }
  in
  check_rows "strong, code, and both link spans restore the row"
    [ "<b>bold<restore> <c>code<restore> \
       <a>docs<restore> <u>(https://x)<restore>"
    ]
    (render ~width:80 ~palette:restoring
       "**bold** `code` [docs](https://x)");
  check_rows "a wrapped strong span restores every physical row"
    [ "<b>abcde<restore>"; "<b>f<restore>" ]
    (render ~width:5 ~palette:restoring "**abcdef**")
;;

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
    [ ("see ", "plain")
    ; ("the PR", "link_text")
    ; (" (https://x/1)", "link_target")
    ]
    (Markdown.inline_segments "see [the PR](https://x/1)")

let test_plain_link_keeps_a_printable_boundary () =
  check_rows "plain link"
    [ "read docs (https://example.invalid/path) next" ]
    (render ~width:80 ~palette:Markdown.plain_palette
       "read [docs](https://example.invalid/path) next");
  check_rows "target wraps with its opening parenthesis"
    [ "docs"; "(https://x)" ]
    (render ~width:11 ~palette:Markdown.plain_palette
       "[docs](https://x)")

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
    ; rule_row [ 5; 5 ]
    ; "bug   |     3"
    ; "spike |    12"
    ]
    (render ~width:40
       "| kind | count |\n| --- | ----: |\n| bug | 3 |\n| spike | 12 |")
;;

(* The rule has to measure the same cells as the gutter it stands in for, or
   the one row whose job is to say where the columns divide draws the divide
   somewhere else. *)
let contains needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  let rec go i =
    i + nl <= hl
    && (String.equal (String.sub haystack i nl) needle || go (i + 1))
  in
  go 0

(* A fenced row too long for the pane used to lose every colour the lexer had
   found: the wrap was done on the plain text and the pieces thrown away. The
   rows that most need reading -- a long added line, a memory claim, a wrapped
   string -- were exactly the ones that lost it. *)
let test_a_wrapped_code_row_keeps_its_colours () =
  let rows =
    render ~width:26 "```diff\n+ aaaa bbbb cccc dddd eeee ffff\n```"
  in
  let marked = List.filter (contains "<+>") rows in
  (* Asserted as more than one: a single marked row is what the old code drew
     for a line that fitted, and this line does not fit. *)
  Alcotest.(check bool) "the line wrapped onto more than one row" true
    (List.length marked > 1)

(* And nothing is lost on the way. A wide grapheme straddling the cut has to
   move to the next row whole -- giving it up and padding its columns holds
   the alignment and drops the letter, which is what a Korean line makes
   visible and an ASCII one hides. *)
let test_wrapping_a_code_row_loses_no_character () =
  let line = "let x = \xed\x95\x9c\xea\xb8\x80\xec\x9d\x84 \xec\x84\x9e\xec\x9d\x80 \xea\xb8\xb4 \xec\xa4\x84 tail" in
  let gutter = Markdown.plain_palette.Markdown.code_gutter in
  (* Several widths rather than one. Whether a grapheme straddles the cut
     depends on where the cut lands, and a single width that happens to fall
     on a boundary tests nothing -- the first draft of this did exactly that
     and stayed green against a wrap that dropped the letter. *)
  List.iter
    (fun width ->
      let body =
        render ~width ~palette:Markdown.plain_palette
          (* A lexed language, so this takes the piece wrap rather than the
             plain fallback a fence with no lexer takes. *)
          ("```bash\n" ^ line ^ "\n```")
        |> List.filter_map (fun row ->
             let g = String.length gutter in
             if String.length row >= g && String.equal (String.sub row 0 g) gutter
             then Some (String.sub row g (String.length row - g))
             else None)
      in
      Alcotest.(check bool)
        (Printf.sprintf "%d: it did wrap" width) true (List.length body > 1);
      (* Joined as they are, not trimmed: a row that legitimately ends in a
         space is indistinguishable from a padded one once trimmed, and the
         space the wrap fell on is a lost character too. *)
      Alcotest.(check string)
        (Printf.sprintf "%d: every character survived the wrap" width)
        line (String.concat "" body))
    [ 21; 22; 23; 24; 25; 26; 27; 28 ]

let test_the_rule_joint_measures_the_gutter () =
  List.iter
    (fun (name, (palette : Markdown.palette)) ->
       Alcotest.(check int)
         (name ^ ": the rule lines up with the rows it divides")
         (Masc_tui_message_layout.display_width palette.table_gutter)
         (Masc_tui_message_layout.display_width palette.table_rule_gutter))
    [ ("tagged", tagged); ("plain", Markdown.plain_palette) ]

(* The box is paid for out of the columns, not out of the pane. A table that
   drew its own width plus a border would run past the frame it sits in. *)
let test_a_framed_table_stays_inside_its_width () =
  let framed = { Markdown.plain_palette with table_frame = true } in
  let rows =
    render ~width:20 ~palette:framed "| id | what |\n| -- | ---- |\n| a1 | b |"
  in
  (* Columns are sized to what they hold and only shrink when that overruns
     the pane, so the table is 20 cells wide only when it needs to be. What
     the box does have to hold is that every row measures the same: a border
     that disagreed with the row under it would not close. *)
  let width_of = Masc_tui_message_layout.display_width in
  (match rows with
   | first :: rest ->
       List.iteri
         (fun index row ->
            Alcotest.(check int)
              (Printf.sprintf "row %d is as wide as the border above it" (index + 1))
              (width_of first) (width_of row))
         rest;
       Alcotest.(check bool) "and none of them overruns the pane" true
         (width_of first <= 20)
   | [] -> Alcotest.fail "the renderer answered no rows");
  (* Asserted rather than assumed: without a border row the width check above
     would be measuring the table this palette drew before the box existed. *)
  Alcotest.(check int)
    "top, header, separator, the one body row, bottom" 5 (List.length rows)

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
    ; rule_row [ 2; 15 ]
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

(* A mermaid fence is drawn, not lexed: the rows the diagram module lays
   out ride the plain code rows inside the gutter, under the fence header
   the tag already earned. *)
let test_mermaid_fence_is_drawn () =
  check_rows "mermaid"
    (tagged_fence "mermaid"
       [ "<c>\xe2\x94\x82 \xe2\x94\x8c\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x90  \xe2\x94\x8c\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x90</c>"
       ; "<c>\xe2\x94\x82 \xe2\x94\x82 A \xe2\x94\x9c\xe2\x94\x80>\xe2\x94\xa4 B \xe2\x94\x82</c>"
       ; "<c>\xe2\x94\x82 \xe2\x94\x94\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x98  \xe2\x94\x94\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x98</c>"
       ])
    (render "```mermaid\ngraph LR\nA --> B\n```")

(* A diagram the module does not draw keeps its source, under one row that
   says why: a reader sees what the keeper wrote, not a blank. *)
let test_mermaid_fence_of_another_kind_shows_its_source () =
  check_rows "unsupported kind"
    (tagged_fence ~width:70 "mermaid"
       [ "<c>\xe2\x94\x82 mermaid: classDiagram is not drawn here; the source follows</c>"
       ; "<c>\xe2\x94\x82 classDiagram</c>"
       ; "<c>\xe2\x94\x82 Animal <|-- Duck</c>"
       ])
    (render ~width:70 "```mermaid\nclassDiagram\nAnimal <|-- Duck\n```")

(* {1 Fenced-code highlighting} *)

(* The tag decides: the same body, untagged, stays the single code span --
(* colouring a grammar nobody lexed is decoration pretending to be
   syntax. *) *)
(* A [diff] tag colours by line rather than by token: the first cell decides
   the whole line. This is what the Memory journal's change rides, and what a
   keeper's pasted patch rides, so both read as arriving and leaving instead of
   one wall of code. *)
let test_diff_fence_colours_each_line_by_its_first_cell () =
  let band = tagged_band ~width:40 in
  check_rows "diff"
    (tagged_fence "diff"
       [ "\xe2\x94\x82 <m>@@ -1,2 +1,2 @@</m>"
       ; band "<->" "</->" "\xe2\x94\x82 - [constraint] use the old endpoint"
       ; band "<+>" "</+>" "\xe2\x94\x82 + [fact] the probe uses HTTP/2"
       ; "\xe2\x94\x82 <c> unchanged</c>"
       ])
    (render
       "```diff\n@@ -1,2 +1,2 @@\n- [constraint] use the old endpoint\n+ [fact] the probe uses HTTP/2\n unchanged\n```")

(* A source line can become several terminal rows in a narrow pane. The
   lexer still named the whole source line as added, so every chunk keeps the
   same full-width band, including the chunk that no longer carries [+]. *)
let test_diff_fence_keeps_the_band_after_a_hard_split () =
  let width = 10 in
  let band = tagged_band ~width in
  check_rows "split diff band"
    (tagged_fence ~width "diff"
       [ band "<+>" "</+>" "\xe2\x94\x82 +abcdefg"
       ; band "<+>" "</+>" "\xe2\x94\x82 hijk"
       ])
    (render ~width "```diff\n+abcdefghijk\n```")

(* With every styling span empty, the source markers remain the colourless
   terminal's signal. Padding is layout, not a second semantic cue. *)
let test_plain_diff_keeps_its_markers_without_colour () =
  let width = 12 in
  check_rows "colourless diff markers"
    [ "\xe2\x94\x8c\xe2\x94\x80 diff \xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80"
    ; "| -gone     "
    ; "| +here     "
    ; "\xe2\x94\x94\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80"
    ]
    (render ~width ~palette:Markdown.plain_palette
       "```diff\n-gone\n+here\n```")

(* Bare-link dressing runs after Markdown. Its closer must not reset the row:
   doing so would end this background after the URL and leave both the tail
   and the width-filling spaces outside the band. *)
let test_bare_link_closer_keeps_the_diff_band_open () =
  let width = 48 in
  let background = "\027[48;5;22m" in
  let foreground = "\027[38;5;255m" in
  let reset = "\027[0m" in
  let palette =
    { tagged with
      code_diff_added = (background ^ foreground, reset)
    }
  in
  let changed =
    match
      render ~width ~palette
        "```diff\n+see https://example.test/x then tail\n```"
    with
    | [ _header; changed; _footer ] -> changed
    | rows ->
        Alcotest.failf "expected one diff row between its borders, got %d"
          (List.length rows)
  in
  let link_open = "\027[4m\027[34m" in
  let link_restore = "\027[24m\027[39m" in
  let dressed =
    Masc_tui_message_layout.dress_bare_links ~open_style:link_open
      ~close_style:link_restore changed
  in
  check_rows "link keeps the enclosing band"
    [ tagged_band ~width (background ^ foreground) reset
        ("\xe2\x94\x82 +see " ^ link_open ^ "https://example.test/x"
         ^ link_restore ^ " then tail")
    ]
    [ dressed ]

(* A file header is not the change under it. Left plain, a green [+++] does not
   sit directly above the first added line reading as part of it. *)
let test_diff_fence_leaves_file_headers_plain () =
  let band = tagged_band ~width:40 in
  check_rows "diff headers"
    (tagged_fence "diff"
       [ "\xe2\x94\x82 <c>--- a/one.ml</c>"
       ; "\xe2\x94\x82 <c>+++ b/one.ml</c>"
       ; band "<+>" "</+>" "\xe2\x94\x82 +added"
       ])
    (render "```diff\n--- a/one.ml\n+++ b/one.ml\n+added\n```")

let test_untagged_fence_stays_single_span () =
  check_rows "no tag, no colour" [ "<c>\xe2\x94\x82 let x = 1</c>" ]
    (render "```\nlet x = 1\n```")

let test_unknown_language_stays_single_span () =
  (* cobol has no lexer, so its fence stays one plain span. (rust used to sit
     here; it gained a lexer with the c-family languages, so it is no longer an
     example of an unlexed tag.) *)
  check_rows "unknown tag, no colour"
    (tagged_fence "cobol" [ "<c>\xe2\x94\x82 IDENTIFICATION DIVISION.</c>" ])
    (render "```cobol\nIDENTIFICATION DIVISION.\n```")

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


(* Two tildes, never one. A single [~] is a home directory and an
   approximation sign far more often than it is a marker, and reading one as
   an opening struck text nobody meant to strike. *)
let test_double_tilde_strikes_and_single_tilde_does_not () =
  let rows = Markdown.render ~palette:tagged ~width:60 "a ~~gone~~ and ~7 more" in
  let joined = String.concat "\n" rows in
  let holds needle =
    let n = String.length needle and h = String.length joined in
    let rec scan i =
      i + n <= h
      && (String.equal (String.sub joined i n) needle || scan (i + 1))
    in
    scan 0
  in
  Alcotest.(check bool) "the struck run is marked" true (holds "<s>gone</s>");
  Alcotest.(check bool) "a lone tilde stays text" true (holds "~7 more")

let () =
  Alcotest.run "tui-markdown"
    [ ( "inline"
      , [ Alcotest.test_case "code loses its backticks" `Quick
            test_inline_code_loses_its_backticks
        ; Alcotest.test_case "strong and emphasis" `Quick
            test_strong_and_emphasis
        ; Alcotest.test_case "inline closers restore the ambient row" `Quick
            test_inline_closers_restore_the_ambient_row
        ; Alcotest.test_case "an unpaired marker stays literal" `Quick
            test_unpaired_marker_stays_literal
        ; Alcotest.test_case "snake_case keeps its underscores" `Quick
            test_snake_case_keeps_its_underscores
        ; Alcotest.test_case "underscore emphasis works between words" `Quick
            test_underscore_emphasis_still_works_between_words
        ; Alcotest.test_case "a link keeps both halves" `Quick
            test_link_keeps_both_halves
        ; Alcotest.test_case "a plain link keeps its boundary" `Quick
            test_plain_link_keeps_a_printable_boundary
        ; Alcotest.test_case "segments name each marker" `Quick
            test_inline_segments_names_each_marker
        ] )
    ; ( "blocks"
      , [ Alcotest.test_case "a heading carries its level" `Quick
            test_a_heading_carries_its_level
        ; Alcotest.test_case "a table becomes columns" `Quick
            test_a_table_becomes_columns
        ; Alcotest.test_case "a wrapped code row keeps its colours" `Quick
            test_a_wrapped_code_row_keeps_its_colours
        ; Alcotest.test_case "wrapping a code row loses no character" `Quick
            test_wrapping_a_code_row_loses_no_character
        ; Alcotest.test_case "the rule joint measures the gutter" `Quick
            test_the_rule_joint_measures_the_gutter
        ; Alcotest.test_case "a framed table stays inside its width" `Quick
            test_a_framed_table_stays_inside_its_width
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
        ; Alcotest.test_case "a mermaid fence is drawn" `Quick test_mermaid_fence_is_drawn
        ; Alcotest.test_case "a mermaid fence of another kind shows its source" `Quick
            test_mermaid_fence_of_another_kind_shows_its_source
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
        ; Alcotest.test_case "a diff colours by line" `Quick
            test_diff_fence_colours_each_line_by_its_first_cell
        ; Alcotest.test_case "a split diff keeps its band" `Quick
            test_diff_fence_keeps_the_band_after_a_hard_split
        ; Alcotest.test_case "a colourless diff keeps its markers" `Quick
            test_plain_diff_keeps_its_markers_without_colour
        ; Alcotest.test_case "a bare link keeps the diff band open" `Quick
            test_bare_link_closer_keeps_the_diff_band_open
        ; Alcotest.test_case "a diff leaves file headers plain" `Quick
            test_diff_fence_leaves_file_headers_plain
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
    ; ( "strike"
      , [ Alcotest.test_case "two tildes strike, one does not" `Quick
            test_double_tilde_strikes_and_single_tilde_does_not
        ] )
    ]
