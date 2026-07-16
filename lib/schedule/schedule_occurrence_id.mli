(** Exact identity of one scheduled occurrence.

    The identity is derived only from persisted schedule facts. Dispatch
    attempts may fail and retry, but they retain the same occurrence identity. *)

type t = private string

val protocol_tag : string
val make : schedule_id:string -> due_at:float -> payload_digest:string -> t
val equal : t -> t -> bool
val to_string : t -> string
