(** Process-local, non-blocking serialization for one lexical entry below a
    pinned parent directory capability. The lease is a coordination boundary
    for cooperative MASC writers; it does not claim exclusion against external
    processes. *)

type t

val try_acquire
  :  parent_dev:int64
  -> parent_ino:int64
  -> leaf:string
  -> t option

val release : t -> unit
