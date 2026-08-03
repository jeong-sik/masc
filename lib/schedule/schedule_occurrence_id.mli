(** Exact identity of one scheduled creation occurrence.

    The identity is derived only from existing persisted schedule facts.
    [requested_at] distinguishes an explicit same-ID recreation after pruning;
    retries of that same creation retain the same occurrence identity. *)

type t = private string

val protocol_tag : string
val make :
  schedule_id:string ->
  requested_at:float ->
  due_at:float ->
  payload_digest:string ->
  t
val of_string : string -> (t, string) result
val equal : t -> t -> bool
val to_string : t -> string
