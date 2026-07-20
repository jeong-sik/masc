(** Board-owned side-effect hooks. *)

type vote_direction =
  | Up
  | Down

type observer =
  { record_vote : agent_name:string -> direction:vote_direction -> unit }

val set_observer : observer -> unit

val record_vote : agent_name:string -> direction:vote_direction -> unit
