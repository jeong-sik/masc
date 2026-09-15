(** What a failed ordinary (non-terminal) tool call does to the provider turn,
    decided by the call's runtime handler. A call the model makes directly and
    the same call as a skill composition node read this one table, so a
    failure ends the turn or goes back to the model the same way on both
    paths. Terminal tools keep their own boundary. *)

val ends_turn
  :  Keeper_tool_descriptor.runtime_handler
  -> Tool_result.failure_effect_disposition
  -> bool
(** Whether a failed call to this handler, with this effect disposition, ends
    the provider turn. A proven pre-effect failure never does. *)
