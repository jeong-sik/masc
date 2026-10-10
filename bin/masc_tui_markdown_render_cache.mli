(** Bounded cache for completed Markdown and closed streaming blocks.

    A completed chat entry can be laid out twice in one frame: once to clamp
    its scroll position and once to draw the resulting window. It can also be
    laid out again on the next idle frame. This module is the one owner of the
    rendered rows those paths share.

    The exact source participates in a completed entry's key. A growing entry
    retains only blocks the Markdown renderer marked closed. [identity] says
    which entry owns either result, while [theme_revision] and
    [palette_generation] reserve the two visual inputs whose runtime owners can
    change independently of the source.

    Identities are hashed and compared structurally: the store finds an entry
    by its identity in one step rather than by walking what it holds, which is
    what lets the bound be large enough for a scrolled transcript. *)

type 'identity t

val create : capacity:int -> 'identity t
(** Create a cache retaining at most [capacity] completed entries and, in a
    separate bound, at most [capacity] growing entries and [capacity] measured
    heights. Within each kind, an
    identity owns one result, so a new width, source, theme revision, or palette
    generation replaces its previous result. *)

val render :
  'identity t ->
  theme_revision:int ->
  palette_generation:int ->
  width:int ->
  renderer:(width:int -> string -> string list) ->
  identity:'identity ->
  text:string ->
  string list
(** Render the completed entry [identity] with source [text], or return its
    retained rows when every key field matches. *)

val render_growing :
  'identity t ->
  theme_revision:int ->
  palette_generation:int ->
  width:int ->
  renderer:(width:int -> string -> Masc_tui_markdown.streaming_render) ->
  identity:'identity ->
  text:string ->
  string list
(** Render a source snapshot with an append-sensitive suffix.

    Closed blocks are retained for the same identity, width, theme revision,
    and palette generation. An unchanged snapshot reuses all rows. An appended
    snapshot renders from the previous suffix boundary. A non-prefix snapshot
    or any visual-key change starts again from the complete source. *)

type measurement = { height : int; nonblank_lines : int }

val measure_growing_details :
  'identity t -> theme_revision:int -> palette_generation:int -> width:int ->
  renderer:(width:int -> string -> Masc_tui_markdown.streaming_render) ->
  identity:'identity -> text:string -> measurement
(** Height plus raw nonblank logical-line count. Appends scan only newly
    arrived bytes for the logical count, retaining the final line's state. *)

val measure_growing :
  'identity t ->
  theme_revision:int ->
  palette_generation:int ->
  width:int ->
  renderer:(width:int -> string -> Masc_tui_markdown.streaming_render) ->
  identity:'identity ->
  text:string ->
  int
(** Physical body-row height, dropping trailing blank rows and keeping one
    row for an empty body as Message_layout does. Closed blocks retain counts
    instead of row lists; only the mutable suffix reaches the renderer after
    an append. The measurement has its own owner store, so rendering a folded
    summary cannot replace the raw source's retained boundary. *)

module For_testing : sig
  val retained_entries : 'identity t -> int
  val retained_growing_entries : 'identity t -> int
end
