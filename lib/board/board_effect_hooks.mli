(** Board-owned side-effect hooks. *)

type earn_kind =
  | Board_post
  | Upvote

type vote_direction =
  | Up
  | Down

type observer =
  { earn :
      base_path:string ->
      agent_name:string ->
      kind:earn_kind ->
      reason:string ->
      unit ->
      (unit, string) result
  ; record_vote : agent_name:string -> direction:vote_direction -> unit
  }

val set_observer : observer -> unit

val earn :
  base_path:string ->
  agent_name:string ->
  kind:earn_kind ->
  reason:string ->
  unit ->
  (unit, string) result

val record_vote : agent_name:string -> direction:vote_direction -> unit
