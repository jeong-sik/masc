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
  image_part : Cell_grid.document_image_part option;
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
    the parse or layout diagnostic. Inline code that is exactly one CSS
    [#RRGGBB] literal, and every such literal in a [css] fence, is drawn on
    the color it names. When [osc8] is [true] (default),
    links attach their URI to {!styled_span.hyperlink} for OSC 8 interning;
    when [false], links include a muted italic [" (target)"] preview so the
    destination stays visible. *)

val render_literal :
  width:int -> base_style:Style.t -> string -> rendered_line list
(** Wrap plain text with line breaks preserved and without Markdown parsing. *)

val draw_line :
  Cell_grid.t -> rect:Rect.t -> ?osc8:bool -> rendered_line -> unit
(** Paint a prepared line in a one-row rectangle without clearing its background.
    Registers its document image part and, by default, interns its OSC 8 links. *)

val alphatex_code_blocks : string -> string list
(** Extract the body of every closed fenced CommonMark code block whose info
    language tag is [alphatex] or [atex] (case-insensitive), in document
    reading order. Shares the exact {!Cmarkit} parser and fence classification
    used by {!render_lines}. *)
type heading = {
  level : int;  (** 1 to 6. *)
  text : string;  (** The heading's plain text. *)
}

val headings : string -> heading list
(** The heading blocks of the Markdown text, in reading order, read with the same
    {!Cmarkit} parser options as {!render_lines}. A [#] line inside a code
    block is not a heading. A setext heading and a heading inside a quote or a
    list item are. *)

val link_first_lines : rendered_line list -> (string * int) list
(** Each distinct link target in [lines], with the index of the first line it
    is on, in reading order. *)

val draw :
  Cell_grid.t ->
  rect:Rect.t ->
  theme:Theme.t ->
  ?osc8:bool ->
  ?scroll:int ->
  ?selected_link:string ->
  string ->
  int
(** Render Markdown directly onto [Cell_grid.t], interning OSC 8 hyperlinks in
    the grid's frame-local link table when [osc8] is [true]. Spans linking to
    [selected_link] are drawn in reverse video. Returns total rendered line
    count. *)
