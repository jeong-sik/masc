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

type 'identity source =
  | Stable_source of {
      identity : 'identity;
      text : string;
    }
  | Streaming_source of string
      (** A source that can grow between frames. It always bypasses the cache,
          so a partial reply cannot be returned after more text arrived. *)

type 'identity t

val create : capacity:int -> 'identity t
(** Create a cache retaining at most [capacity] completed entries and, in a
    separate bound, at most [capacity] growing entries. Within each kind, an
    identity owns one result, so a new width, source, theme revision, or palette
    generation replaces its previous result. *)

val render :
  'identity t ->
  theme_revision:int ->
  palette_generation:int ->
  width:int ->
  renderer:(width:int -> string -> string list) ->
  source:'identity source ->
  string list
(** Render [source], or return its retained rows when every key field matches.
    Streaming sources are rendered directly and are never retained. *)

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

module For_testing : sig
  val retained_entries : 'identity t -> int
  val retained_growing_entries : 'identity t -> int
end
