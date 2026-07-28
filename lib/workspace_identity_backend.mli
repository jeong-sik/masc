(** Identity helpers shared by workspace-facing tool surfaces. *)

type join_validation_error =
  { outcome : string
  ; detail : string
  }

val keeper_name_for_agent_name : string -> string option
val canonicalize_if_keeper : Workspace.config -> string -> string

