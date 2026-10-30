(** MD5 fed in bounded slices, so a stop-the-world request waits for one
    slice at most (RFC-0474 L2). Digests are [Digestif.MD5] digests. *)

type ctx

val empty : ctx
val feed_string : ctx -> string -> ctx
val to_hex : ctx -> string
(** Hex digest of everything fed so far. *)
