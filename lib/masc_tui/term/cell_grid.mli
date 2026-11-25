(** Double-buffer-friendly 2D cell grid with zero-allocation ASCII/Braille cells,
    atomic wide-glyph overwrite partner cleanup, clipping, frame-local OSC 8 link
    table, and immutable spatial hit-map. *)

type glyph =
  | Empty
  | Ascii of char        (** Printable ASCII [0x21..0x7E]: 0 heap allocation *)
  | Braille of int       (** [0x00..0xFF] mask -> static 256-entry LUT [U+2800..U+28FF] *)
  | Utf8 of string       (** Single UAX #29 grapheme cluster, width 1 or 2 *)
  | Continuation         (** Trailing half of a width-2 CJK/wide grapheme *)

type cell = {
  glyph : glyph;
  width : int;           (** [0] for [Continuation], [1] narrow, [2] wide *)
  style : Style.t;
}

val braille_lut : string array
(** Preallocated 256-entry UTF-8 lookup table covering [U+2800..U+28FF]. *)

val braille_utf8 : int -> string
(** [braille_utf8 mask] returns the preallocated UTF-8 string for [mask land 0xFF]. *)

val blank_cell : cell
val glyph_equal : glyph -> glyph -> bool
val cell_equal : cell -> cell -> bool

module Hit_map : sig
  type 'a entry = {
    rect : Masc_tui_core.Rect.t;
    target : 'a;
  }

  type 'a t

  val empty : 'a t
  val add : rect:Masc_tui_core.Rect.t -> target:'a -> 'a t -> 'a t

  val hit_test : 'a t -> x:int -> y:int -> 'a option
  (** Returns the topmost (most recently added) target whose rectangle contains
      [(x, y)], or [None] when outside all registered regions. *)

  val entries : 'a t -> 'a entry list
end

type t

val create : cols:int -> rows:int -> t
val cols : t -> int
val rows : t -> int
val bounds : t -> Masc_tui_core.Rect.t

val clear : ?style:Style.t -> t -> unit
(** Reset all cells to [Empty] with [style] (default {!Style.default}) and clear
    the frame-local OSC 8 link table. *)

val resize : cols:int -> rows:int -> t -> t
val copy_into : src:t -> dst:t -> unit

type document_image = Mermaid of string

type document_image_rows = {
  source : document_image;
  count : int;
}

type document_image_part = {
  rows : document_image_rows;
  index : int;
  left_inset : int;
}

type document_placement = {
  image : document_image;
  rect : Masc_tui_core.Rect.t;
}

val register_document_image_part :
  t -> rect:Masc_tui_core.Rect.t -> document_image_part -> unit
(** A placement is available only after every row of one image occurrence
    has been painted consecutively inside the viewport. *)

val occlude_document_images : t -> rect:Masc_tui_core.Rect.t -> unit
(** Clear placements under a later overlay drawn by individual cell writes. *)

val document_placements : t -> document_placement list
(** Full placements in document order. A later overlapping fill or scrim
    removes the placement. Clearing the grid resets them for each frame. *)

val get : t -> x:int -> y:int -> cell
(** Out-of-bounds reads return {!blank_cell}. *)

val get_linear : t -> int -> cell
(** Direct flat-array read at [y * cols + x]. *)

val intern_hyperlink : t -> string -> int
(** Register a sanitized OSC 8 URI in the grid's frame-local link table and
    return its positive link id ([0] if URI is empty after sanitization). *)

val hyperlink_uri : t -> int -> string option
(** Look up a frame-local OSC 8 URI by id ([0] always returns [None]). *)

val set_cell : ?clip:Masc_tui_core.Rect.t -> t -> x:int -> y:int -> cell -> unit
(** Write one cell with clipping and atomic wide-cell partner cleanup.
    Overwriting either half of an existing width-2 cell automatically blanks the
    orphaned partner half-cell. Writing a width-2 cell at the rightmost clipped
    column writes a width-1 ellipsis instead of overflowing. *)

val put_ascii :
  ?clip:Masc_tui_core.Rect.t -> t -> x:int -> y:int -> style:Style.t -> char -> unit

val put_braille :
  ?clip:Masc_tui_core.Rect.t -> t -> x:int -> y:int -> style:Style.t -> int -> unit

val put_glyph :
  ?clip:Masc_tui_core.Rect.t ->
  t ->
  x:int ->
  y:int ->
  style:Style.t ->
  Masc_tui_core.Glyph.t ->
  unit

val put_text :
  ?clip:Masc_tui_core.Rect.t ->
  t ->
  x:int ->
  y:int ->
  style:Style.t ->
  string ->
  int
(** Draw sanitized UAX #29 text starting at [(x, y)], stopping at the clip/grid
    right edge. Returns total terminal columns advanced. *)

val fill_rect :
  ?clip:Masc_tui_core.Rect.t ->
  t ->
  rect:Masc_tui_core.Rect.t ->
  style:Style.t ->
  ?glyph:glyph ->
  unit ->
  unit

val dim_rect :
  ?clip:Masc_tui_core.Rect.t ->
  t ->
  rect:Masc_tui_core.Rect.t ->
  fg:Color.t ->
  bg:Color.t ->
  unit
(** Recolor existing cells inside [rect] to muted [fg]/[bg] as a backdrop scrim
    before painting a floating modal or popup, preserving cell glyphs without
    bright foreground bleed-through. *)
