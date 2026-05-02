(** Variable-length integer encoding (unsigned) for Yjs binary protocol *)

val encode_uint : int -> string
val decode_uint : string -> pos:int -> int * int
