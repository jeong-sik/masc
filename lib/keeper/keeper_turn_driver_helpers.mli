(** Pure helpers extracted from [Keeper_turn_driver].

    See [.ml] for rationale. No behavior change from pre-RFC-0048 inline
    definitions. *)

val apply_stream_idle_timeout_default : float option -> float option

val checkpoint_after_attempt :
  ?agent_ref:Agent_sdk.Agent.t option ref ->
  Agent_sdk.Agent.t option ->
  Agent_sdk.Checkpoint.t option
