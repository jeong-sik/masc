(** Identity helpers shared by workspace-facing tool surfaces. *)

type join_validation_error =
  { outcome : string
  ; detail : string
  }

let keeper_name_for_agent_name = Keeper_identity.keeper_name_from_agent_name
let canonicalize_if_keeper = Keeper_runtime.canonicalize_if_keeper

