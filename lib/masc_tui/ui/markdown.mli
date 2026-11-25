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
  ?base_style:Style.t ->
  string ->
  rendered_line list
(** Parse CommonMark with tables, strike-through and task-list extensions.
    Wrap styled rows to [width] columns (minimum eight). Closed [mermaid]
    fences within the inline renderer limits are rendered
    inline via {!Mermaid.render_adaptive}. The [pele] fence uses the same
    text drawing. Fenced [alphatex] and [atex] are drawn as tablature via
    {!Alphatex.render_tab}. Unsupported input keeps its code and, for scores,
    the parse or layout diagnostic. When [osc8] is [true] (default),
    links attach their URI to {!styled_span.hyperlink} for OSC 8 interning;
    when [false], links include a muted italic [" (target)"] preview so the
    destination stays visible. *)

val render_literal :
  width:int -> base_style:Style.t -> string -> rendered_line list
(** Wrap plain text with line breaks preserved and without Markdown parsing. *)

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
