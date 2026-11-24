(** Structured HTML DOM renderer built directly on {!Markup_document.parse_html}
    and painted onto {!Masc_tui_term.Cell_grid.t} with zero raw ANSI sequences.

    Strips non-content markup ([head], [script], [style], [template], [iframe],
    [object], [embed], [noscript], [hidden], [aria-hidden="true"]), renders
    headings H1-H6, CJK-safe wrapped paragraphs, dimmed preformatted code
    blocks, nested bullets, aligned tables with bold headers, inline link URLs,
    and embedded image badges. *)

module Rect = Masc_tui_core.Rect
module Say = Masc_tui_core.Say
module Theme = Masc_tui_core.Theme
module Style = Masc_tui_term.Style
module Cell_grid = Masc_tui_term.Cell_grid

type image_source =
  | Embedded_data of { mime : string; bytes_len : int }
  | Embedded_svg of string
  | Unavailable of string

type image = {
  label : string;
  source : image_source;
}

type cell = {
  text : string;
  heading : bool;
}

type block =
  | Paragraph of string
  | Heading of int * string
  | Preformatted of string
  | List_item of int * string
  | List_continuation of int * string
  | Table of cell list list
  | Image of image

type document = {
  blocks : block list;
  images : image list;
}

type rendered_line = {
  text : string;
  style : Style.t;
  is_search_match : bool;
}

val project : string -> document
(** Parse HTML source via {!Markup_document.parse_html} into clean structural
    blocks and collected embedded images. *)

val render_lines :
  theme:Theme.t ->
  width:int ->
  lang:Say.lang ->
  ?search_query:string ->
  string ->
  rendered_line list
(** Project HTML source into CJK-safe wrapped terminal lines of at most [width]
    cells, tagging lines matching [search_query] (case-insensitive). *)

val search_match_lines :
  theme:Theme.t -> width:int -> lang:Say.lang -> query:string -> string -> int list
(** 0-based line indices matching [query] in {!render_lines}. *)

val draw :
  Cell_grid.t ->
  rect:Rect.t ->
  theme:Theme.t ->
  lang:Say.lang ->
  ?scroll:int ->
  ?search_query:string ->
  ?active_match_line:int ->
  string ->
  int
(** Paint structured HTML directly onto [Cell_grid.t] and return total rendered
    line count. *)
