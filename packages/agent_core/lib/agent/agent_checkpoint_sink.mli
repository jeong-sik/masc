(** Checkpoint persistence for input ownership and pipeline mutations.
    An explicit caller sink remains the required persistence authority; it is
    not an optional observer and does not dual-write a journal checkpoint.
    Without a caller sink, an active journal commits a frozen candidate. With
    neither authority the transition remains in-memory. *)

val persist_for_state
  :  Agent_types.t
  -> Agent_types.checkpoint_stage
  -> pending_input:Agent_input_request.pending option
  -> Types.agent_state
  -> (unit, Error.t) result
