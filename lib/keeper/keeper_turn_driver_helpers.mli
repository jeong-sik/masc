(** Pure helpers extracted from [Keeper_turn_driver].

    See [.ml] for rationale. No behavior change from pre-RFC-0048 inline
    definitions. *)

val checkpoint_after_attempt :
  ?agent_ref:Agent_core.Agent.t option ref ->
  Agent_core.Agent.t option ->
  Agent_core.Checkpoint.t option
