(** Crisp rounded-border cards ([╭─╮│╰─╯]) with title, status badge,
    hotkey-in-border, focus accent highlight, breathing {!content_rect} padding,
    anti-nested-box structural primitives ({!draw_hairline}, {!draw_v_hairline},
    {!draw_left_rail}, {!draw_section_band}), and an explicit bounded 64-entry
    [Prepared_box] border geometry LRU cache (zero global mutable state). *)

module Glyph = Masc_tui_core.Glyph
module Rect = Masc_tui_core.Rect
module Theme = Masc_tui_core.Theme
module Color = Masc_tui_term.Color
module Cell_grid = Masc_tui_term.Cell_grid

type badge = {
  glyph : Glyph.t option;
  text : string;
  tone : Theme.status_token option;
}

type spec = {
  title : string;
  subtitle : string option;
  badge : badge option;
  hotkey : string option;
  footer_hint : string option;
  focused : bool;
  elevated : bool;
  unicode_borders : bool;
}

val default_spec : title:string -> spec

val inner_rect : Rect.t -> Rect.t
(** Interior content area inset by 1 cell on all four borders, or {!Rect.empty}
    when [rect.w < 2 || rect.h < 2]. Use {!inner_rect} for full-bleed surface
    bands (table headers, selection highlights, section bands). *)

val pad_inner : ?pad_x:int -> ?pad_y:int -> Rect.t -> Rect.t
(** Inset an already-computed {!inner_rect} by [pad_x] (default [2]) and
    [pad_y] (default [0]), clamping gracefully on narrow rectangles so text
    never touches the [│] borders and narrow cards never collapse. *)

val content_rect : ?pad_x:int -> ?pad_y:int -> Rect.t -> Rect.t
(** Returns {!inner_rect} of an outer card [rect] further inset by [pad_x]
    (default [2] on Wide/Standard, pass [1] on Compact) and [pad_y] (default
    [0]). Use for all prose, KPIs, key-value lines, charts, and Markdown. *)

module Cache : sig
  type t

  type stats = {
    capacity : int;
    entries : int;
    hits : int;
    misses : int;
    evictions : int;
  }

  val default_capacity : int
  (** [64]. *)

  val create : ?capacity:int -> unit -> t
  (** Create an explicit bounded LRU border-geometry cache (zero global refs). *)

  val clear : t -> unit
  val stats : t -> stats
end

val draw :
  ?cache:Cache.t ->
  Cell_grid.t ->
  rect:Rect.t ->
  theme:Theme.t ->
  spec ->
  Rect.t
(** Fill the card's surface elevation ([surface_1] or [surface_2] when
    [elevated]), paint rounded (or ASCII fallback) borders with left
    title/subtitle, btop-style right-aligned badge/italic hotkey, and focus
    highlight, and return {!inner_rect} for child rendering. *)

val legacy_rule_label : string -> string option
(** Extract the inner title from a column-0 legacy ["── Label"] or
    ["── Label ──"] section-rule line, stripping leading/trailing box-dash
    delimiters and surrounding whitespace. Indented lines (e.g. ["  ── ..."])
    and ordinary text return [None] so untrusted body content cannot spoof a
    section header. *)

val draw_hairline :
  ?pad_x:int ->
  ?label:string ->
  ?focused:bool ->
  ?unicode:bool ->
  ?bg:Color.t ->
  Cell_grid.t ->
  rect:Rect.t ->
  y:int ->
  theme:Theme.t ->
  unit
(** Paint a 1-row internal hairline divider across [rect] inset by [pad_x]
    (default [0]). Unlabeled dividers paint [─] in [theme.border_subtle];
    when a non-empty [label] is given, paints a left-aligned section header
    ([▸ Label ──────────]) with an accent caret, Tier 1 ([text_bright] Bold)
    title, and trailing rule in [theme.border_inactive] when [focused] is
    [true] (default), or a muted dot, Tier 3 ([text_secondary]) title, and
    [theme.border_subtle] rule when [focused] is [false]. Replaces nested
    boxes-inside-boxes. *)

val draw_v_hairline :
  ?unicode:bool ->
  ?bg:Color.t ->
  Cell_grid.t ->
  x:int ->
  y:int ->
  h:int ->
  theme:Theme.t ->
  unit
(** Paint a 1-column vertical hairline divider ([│] in [theme.border_subtle])
    for 2-pane splits (e.g. Settings tree | inspector, Wiki TOC rail). *)

val draw_left_rail :
  ?unicode:bool ->
  ?bg:Color.t ->
  ?color:Theme.rgb ->
  ?tone:Theme.status_token ->
  Cell_grid.t ->
  x:int ->
  y:int ->
  h:int ->
  theme:Theme.t ->
  unit
(** Paint a 1-cell vertical accent rail ([▎], {!Glyph.Left_rail}) for [h] rows
    in [color], [Theme.status_color theme tone], or [theme.accent] (default). *)

val draw_section_band :
  ?pad_x:int ->
  Cell_grid.t ->
  rect:Rect.t ->
  theme:Theme.t ->
  left_title:string ->
  ?right_meta:string ->
  ?subtitle:string ->
  unit ->
  unit
(** Paint a full-bleed [surface_2] elevated header band (1 row if [subtitle] is
    [None], 2 rows if [Some]) inside [rect] (typically {!inner_rect}) with
    [pad_x] (default [2]) breathing padding. *)
