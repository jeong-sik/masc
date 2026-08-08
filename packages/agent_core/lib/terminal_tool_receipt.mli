(** Exact successful terminal-tool turn receipt. *)

type t =
  { invocation : Tool_contract.Invocation.t
  ; response : Types.api_response
  ; checkpoint_stage : Agent_types.checkpoint_stage
  }
