(** Private checkpoint persistence for pipeline mutation boundaries. *)

val persist_for_state
  :  Agent_types.t
  -> Agent_types.checkpoint_stage
  -> Types.agent_state
  -> (unit, Error.sdk_error) result
