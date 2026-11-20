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

val render_with_suffix :
  'identity t ->
  theme_revision:int ->
  palette_generation:int ->
  width:int ->
  renderer:(width:int -> string -> Masc_tui_markdown.streaming_render) ->
  identity:'identity ->
  text:string ->
  string list
(** {!render} through a streaming renderer, which also retains where the
    render's open suffix starts, for {!completed_boundary}. Rows retained by
    {!render} for the same key are rendered again once to learn it. *)

val completed_boundary :
  'identity t ->
  theme_revision:int ->
  palette_generation:int ->
  width:int ->
  identity:'identity ->
  text:string ->
  (int * int) option
(** [Some (source_bytes, rows)] when {!render_with_suffix} retained exactly
    [text] for [identity] with these visual fields: the bytes before the
    render's open suffix and the rows they draw. The rows after that are what
    the suffix bytes render to on their own, numbered from [rows]. [None]
    when nothing for [text] is retained, or {!render} retained it. *)

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

val growing_boundary :
  'identity t ->
  theme_revision:int ->
  palette_generation:int ->
  width:int ->
  identity:'identity ->
  text:string ->
  (int * int) option
(** [Some (source_bytes, rows)] when the growing entry [identity] last
    rendered exactly [text] with these visual fields: the bytes of its closed
    blocks and the rows they draw. The rows of [text] after that prefix are
    what [text]'s remaining bytes render to on their own, numbered from
    [rows]. [None] when nothing for [text] is retained. *)

type measurement = { height : int; nonblank_lines : int }

val measure_growing_details :
  'identity t -> theme_revision:int -> palette_generation:int -> width:int ->
  renderer:(width:int -> string -> Masc_tui_markdown.streaming_render) ->
  identity:'identity -> text:string -> measurement
(** [height] is the physical body-row height, dropping trailing blank rows and
    keeping one row for an empty body as Message_layout does. [nonblank_lines]
    is the raw nonblank logical-line count. Closed blocks retain counts instead
    of row lists; after an append only the mutable suffix reaches the renderer
    and the logical count scans only newly arrived bytes, retaining the final
    line's state. The measurement has its own owner store, so rendering a
    folded summary cannot replace the raw source's retained boundary. *)

module For_testing : sig
  val retained_entries : 'identity t -> int
  val retained_growing_entries : 'identity t -> int
end
