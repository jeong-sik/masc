(** Identity helpers shared by coord-facing tool surfaces. *)

type join_validation_error =
  { outcome : string
  ; detail : string
  }

val keeper_name_for_agent_name : string -> string option
val canonicalize_if_keeper : Coord.config -> string -> string

val validate_join_identity :
  base_path:string -> agent_name:string -> (string, join_validation_error) result
