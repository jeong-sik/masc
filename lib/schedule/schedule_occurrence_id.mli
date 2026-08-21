(** Exact identity of one scheduled occurrence.

    The identity is derived only from persisted schedule facts, including the
    durable schedule creation identity. The identity remains stable while an
    occurrence moves through its persisted states. *)

type t = private string

val protocol_tag : string
val make :
  schedule_instance_id:string ->
  schedule_id:string ->
  due_at:float ->
  payload_digest:string ->
  t
val to_string : t -> string
