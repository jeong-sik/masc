(** A bounded store that drops what has been read from for longest.

    Written for the chat pane's rendered rows, where the store was a list and
    every lookup walked it. That is fine at a capacity of a few and wrong at a
    capacity that covers a scrolled transcript: the pane looks up a row for
    every message it walks, so the walk cost the capacity times its own
    length, and raising the bound to stop the thrashing made each lookup
    worse. Here a lookup is a hash, and the bound can be as large as the
    working set needs.

    Keys are hashed and compared structurally, so an identity that carries a
    [nan] never matches itself and simply misses. *)

type ('key, 'value) t

val create : capacity:int -> ('key, 'value) t
(** Retain at most [capacity] values. Raises [Invalid_argument] below one. *)

val find : ('key, 'value) t -> 'key -> 'value option
(** The value for [key], which becomes the most recently used. *)

val set : ('key, 'value) t -> 'key -> 'value -> unit
(** Store [value] under [key] as the most recently used, dropping the least
    recently used value when that puts the store over its capacity. A key
    already present keeps its place in the store and takes the new value. *)

val size : ('key, 'value) t -> int
(** How many values are retained. Never above the capacity. *)

val keys_newest_first : ('key, 'value) t -> 'key list
(** The retained keys, most recently used first. For tests and for reading a
    store in a debugger; the order is the eviction order reversed. *)
