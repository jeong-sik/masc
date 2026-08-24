(** Bounded cache for source-stable Markdown rows.

    A completed chat entry can be laid out twice in one frame: once to clamp
    its scroll position and once to draw the resulting window. It can also be
    laid out again on the next idle frame. This module is the one owner of the
    rendered rows those paths share.

    The exact source participates in the key. [identity] says which completed
    entry owns the result, while [theme_revision] and [palette_generation]
    reserve the two visual inputs whose runtime owners can change independently
    of the source. *)

type 'identity source =
  | Stable_source of {
      identity : 'identity;
      text : string;
    }
  | Streaming_source of string
      (** A source that can grow between frames. It always bypasses the cache,
          so a partial reply cannot be returned after more text arrived. *)

type 'identity t

val create :
  capacity:int -> equal:('identity -> 'identity -> bool) -> 'identity t
(** Create a cache retaining at most [capacity] completed entries. Each
    identity owns at most one result, so a new width, source, theme revision,
    or palette generation replaces its previous result. *)

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

module For_testing : sig
  val retained_entries : 'identity t -> int
end
