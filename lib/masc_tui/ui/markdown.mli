(** Pure Markdown renderer painting directly onto {!Masc_tui_term.Cell_grid.t}
    with explicit {!Masc_tui_core.Theme.t}, v2.5 4-tier typography (bold bright
    headings with hairline, italic blockquotes with [▎] rail, elevated [surface_2]
    inline code, recessed [surface_0] syntax-highlighted fenced code via
    {!Code_lexer}), CJK-safe wrapping, and frame-local OSC 8 clickable links. *)

module Rect = Masc_tui_core.Rect
module Theme = Masc_tui_core.Theme
module Style = Masc_tui_term.Style
module Cell_grid = Masc_tui_term.Cell_grid

type styled_span = {
  text : string;
  style : Style.t;
  hyperlink : string option;
}

type rendered_line = {
  spans : styled_span list;
}

val render_lines :
  theme:Theme.t ->
  width:int ->
  ?osc8:bool ->
  string ->
  rendered_line list
(** Parse and wrap Markdown into styled terminal lines of at most [width]
    columns. When [osc8] is [true] (default), links attach their URI to
    {!styled_span.hyperlink} for OSC 8 interning; when [false], links include
    a muted italic [" (target)"] preview so the destination stays visible. *)

val draw :
  Cell_grid.t ->
  rect:Rect.t ->
  theme:Theme.t ->
  ?osc8:bool ->
  ?scroll:int ->
  string ->
  int
(** Render Markdown directly onto [Cell_grid.t], interning OSC 8 hyperlinks in
    the grid's frame-local link table when [osc8] is [true]. Returns total
    rendered line count. *)
