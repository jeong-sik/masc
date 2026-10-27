(** SHA-256 that answers stop-the-world requests while it hashes.

    Values are [Digestif.SHA256] values, so digests, hex forms and raw forms
    are the same bytes as before. Only feeding changes: a string or bytes
    argument is fed in slices of {!slice_bytes}, and OCaml code runs between
    slices, so a stop-the-world request waits for one slice at most instead of
    the whole argument (RFC-0474 L2). *)

type t = Digestif.SHA256.t
type ctx = Digestif.SHA256.ctx

val digest_size : int

val slice_bytes : int
(** Bytes hashed per digestif call: 64 KiB, about 0.24 ms on 2026-10-27. *)

val empty : ctx
val init : unit -> ctx
val get : ctx -> t

type bigstring = Digestif.bigstring

val feed_bigstring : ctx -> ?off:int -> ?len:int -> bigstring -> ctx
(** [Digestif.SHA256.feed_bigstring] unchanged: digestif releases the runtime
    around the bigstring hash ([caml_enter_blocking_section]), so it does not
    hold a stop-the-world request whatever its length. *)

val feed_string : ctx -> ?off:int -> ?len:int -> string -> ctx
(** Same result as [Digestif.SHA256.feed_string]; raises [Invalid_argument]
    when [off] and [len] do not name a range of the string. *)

val feed_bytes : ctx -> ?off:int -> ?len:int -> bytes -> ctx
(** Same result as [Digestif.SHA256.feed_bytes], with the same range check. *)

val digest_string : ?off:int -> ?len:int -> string -> t
val digesti_string : ((string -> unit) -> unit) -> t
val equal : t -> t -> bool
val to_hex : t -> string
val consistent_of_hex_opt : string -> t option
val to_raw_string : t -> string
