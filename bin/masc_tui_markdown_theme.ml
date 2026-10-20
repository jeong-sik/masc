open Masc_tui_ansi
module Markdown = Masc_tui_markdown

(* Whether tables are drawn with an outer box, read once from [tui].table_frame
   at start-up. Held here rather than threaded through every caller of
   [chat_markdown_palette]: the palette is built fresh on each render, so this
   is the one setting projected into it rather than a second copy of it. *)
let table_frame_enabled = ref false


(* Terminal dress for the markdown a keeper writes. The marker is the noise:
   a backticked identifier should read as the identifier, and a fenced diff
   should keep the alignment that made it worth fencing. Colours stay inside
   the palette the renderer already uses, so a chat row is still recognisably
   one of this TUI's rows. *)
let palette ~closing : Markdown.palette =
  { strong = (Ansi.bold, closing)
    (* Slanted, not dimmed. Emphasis that recedes is the opposite of
       emphasis, and dim was standing in for an italic the theme did not
       have. It closes to the slant's own off-code so an emphasised run
       inside a coloured row leaves the row's colour alone. *)
  ; emphasis = (Ansi.italic, Ansi.no_italic)
  ; strike = (Ansi.strike, Ansi.no_strike)
  ; code = (Theme.Syntax.code_span, closing)
  (* Bold alone. [white] is a colour like any other -- on a light background
     it is the background -- so painting a heading with it hid the heading on
     exactly the terminals that read it as text. Bold already says heading. *)
  (* Which heading is inside which, said the way a terminal can: the top
     level is underlined as well as bold, the next is bold, and the rest are
     bold and dim so they still read as headings without competing with the
     two above. One span for every level drew a document with no shape. *)
  ; heading =
      (fun level ->
        if level <= 1 then (Ansi.bold ^ Ansi.underline, closing)
        else if level = 2 then (Ansi.bold, closing)
        else (Ansi.bold ^ Ansi.dim, closing))
  ; quote = (Ansi.dim, closing)
  ; link_text = (Theme.Syntax.link, closing)
  ; link_target = (Ansi.dim, closing)
  ; rule = (Theme.Syntax.rule, closing)
  ; bullet = "\xe2\x80\xa2"
  ; code_gutter = "\xe2\x94\x82 "
  (* Reverse video uses the terminal's own foreground and background, so the
     language banner stays legible on both light and dark themes. *)
  ; code_header = (Ansi.reverse, closing)
  ; code_border = (Theme.Syntax.rule, closing)
  ; quote_gutter = "\xe2\x96\x8f "
  ; table_header = (Ansi.bold, closing)
  ; table_gutter = " \xe2\x94\x82 "
  ; table_rule_gutter = "\xe2\x94\x80\xe2\x94\xbc\xe2\x94\x80"
  ; table_frame = !table_frame_enabled
  (* Fenced-code tokens, inside the cyan the plain code span already uses:
     one hue per role a keeper's eye scans for -- what binds, what is data,
     what the reader can skip. *)
  ; code_keyword = (Theme.Syntax.keyword, closing)
  ; code_string = (Theme.Syntax.string, closing)
  ; code_comment = (Theme.Syntax.code_comment, closing)
  ; code_number = (Theme.Syntax.code_number, closing)
  ; code_type = (Ansi.bold ^ Theme.Syntax.code_type, closing)
  (* Changed rows follow the dedicated diff surfaces: their background runs
     through the code gutter and the unused cells, so lines of different
     lengths still read as one patch. The fixed light foreground is paired
     with the two fixed dark backgrounds by Theme; the +/- source marker and
     the background already say which side of the change this is. *)
  ; code_diff_added =
      (Theme.Syntax.diff_added_bg ^ Theme.Syntax.diff_row_foreground, closing)
  ; code_diff_removed =
      (Theme.Syntax.diff_removed_bg ^ Theme.Syntax.diff_row_foreground, closing)
  }


let render ~closing ~width body =
  Markdown.render
    ~palette:(palette ~closing) ~width body


(* Documents outside a conversation have no ambient role background to
   restore. Keep their former reset boundary explicit instead of inventing a
   synthetic chat role or taking a terminal-palette snapshot. *)
let document ~width body =
  render ~closing:Ansi.reset ~width body


let fenced ~language text =
  match
    Masc_tui_markdown.non_colliding_fence_marker
      (String.split_on_char '\n' text)
  with
  | Some marker -> String.concat "\n" [ marker ^ language; text; marker ]
  | None -> text


