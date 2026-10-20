(** Private checkpoint persistence shared by input ownership and pipeline
    mutation boundaries. The supplied pending proof belongs to the same
    candidate state; no second read of the mutable Agent participates. *)

val persist_for_state
  :  Agent_types.t
  -> Agent_types.checkpoint_stage
  -> pending_input:Agent_input_request.pending option
  -> Types.agent_state
  -> (unit, Error.t) result
