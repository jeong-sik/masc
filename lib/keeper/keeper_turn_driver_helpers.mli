(** Pure helpers extracted from [Keeper_turn_driver].

    See [.ml] for rationale. No behavior change from pre-RFC-0048 inline
    definitions. *)

val checkpoint_after_attempt :
  ?agent_ref:Agent_sdk.Agent.t option ref ->
  Agent_sdk.Agent.t option ->
  Agent_sdk.Checkpoint.t option
