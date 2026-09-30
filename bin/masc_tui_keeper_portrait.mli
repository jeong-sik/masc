(** A Keeper's own portrait at the head of its detail: the candle imp its
    name draws ({!Keeper_portrait_look.body_of_name}), wearing the equipment
    observed by the server, standing still, with the
    Identity facts beside it. How it reaches the terminal -- real pixels, a
    half-block mosaic, or not at all -- is {!Masc_tui_portrait_view}'s. *)

type band_size = private {
  rows : int;  (** the most rows the portrait takes *)
  cols : int;  (** the most cells across it takes *)
}

val band_size : Masc_tui_portrait_view.display -> band_size option
(** The box the portrait fits in on [display]: the smallest one its face
    shows in. A mosaic draws two pixels to a row, so it takes more rows than
    placed pixels do. [None] where no picture is drawn. *)

val min_content_rows : band_size -> int
(** The fewest content rows the detail pane must have for the portrait to
    show: the band's rows and the rows the facts keep below it. Under it the
    facts get every row. *)

val min_content_cols : band_size -> int
(** The fewest cells across the detail pane's content must have for the
    portrait to show: its indent, the band's cells, and the cells the
    Identity facts keep beside it. Under it the facts get the whole width. *)

val cache_capacity : int
(** How many rendered portraits a {!cache} keeps. *)

(** Rendered portraits by Keeper name, complete equipment snapshot, pixel edge and drawing mode. Walking
    the roster reuses a Keeper already seen instead of redrawing it. Holds
    at most {!cache_capacity}; the one used longest ago goes first. *)
type cache

val cache : unit -> cache
(** An empty cache. *)

val cached : cache -> int
(** How many portraits the cache holds. *)

val image :
  ?compact:bool -> cache -> name:string -> equipment:Keeper_portrait_look.equipment
  -> Keeper_portrait_draw.size -> Keeper_portrait_draw.image
(** The Keeper's still portrait at that edge, from the cache when it is
    there, rendered and kept when it is not. [compact] uses the mosaic drawing
    for the bare body and its dish. Face, neck, head and hand equipment uses
    the full drawing so those accessories remain visible. Placed pixel
    portraits always use the full drawing. *)

type band = private {
  display : Masc_tui_portrait_view.display;
  box : Masc_tui_portrait_view.box;
  image : Keeper_portrait_draw.image;
  lines : string list;
      (** [box.rows] rows of [box.cols] cells: the mosaic, or the blank cells
          a placed picture covers *)
}
(** The portrait laid out for one pane. *)

val band :
  cache ->
  display:Masc_tui_portrait_view.display ->
  project:(Masc_tui_terminal_palette.rgb -> Masc_tui_terminal_palette.projected_color option) ->
  name:string ->
  equipment:Keeper_portrait_look.equipment ->
  content_rows:int ->
  content_cols:int ->
  band option
(** The portrait for a pane with [content_rows] rows under its title and
    [content_cols] cells across. [None] when the display draws no picture,
    when the pane is shorter than {!min_content_rows} or narrower than
    {!min_content_cols} for the display's {!band_size}, or when
    {!Masc_tui_portrait_view.fit} finds no picture in that band. *)

val beside : band -> string list -> string list
(** [beside band facts]: the portrait's rows with [facts] to their right,
    one fact to a row. Facts past the portrait's last row keep the same
    column. As many rows as the taller of the two. *)

val placement :
  band ->
  scroll:int ->
  visible_rows:int ->
  origin:int * int ->
  Masc_tui_portrait_view.placement option
(** Where real pixels go, for a band {!beside} opened the pane's content
    with, under {!Masc_tui_graphics.Keeper_portrait}'s image id. [origin] is
    the frame line and cell of the content's first row and first cell. [Some]
    only for a {!Masc_tui_portrait_view.Pixels} display,
    and only when the whole portrait is on screen: the pane is not scrolled
    and shows at least the portrait's rows. A placement cannot draw half a
    picture, and one left standing after a scroll would cover facts. *)

val shown : name:string -> equipment:Keeper_portrait_look.equipment -> content_rows:int -> content_cols:int -> band option
(** {!band} against this process: one cache for the session, the display
    the start-up probe chose, and the stdout colour projection. *)

val preview : name:string -> equipment:Keeper_portrait_look.equipment -> content_rows:int -> content_cols:int -> band option
(** The same cached portrait with room for the Item list beside it. It fits
    the picture within the actual pane and leaves two rows and two columns
    for the screen's text. *)
