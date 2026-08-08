(** Pure helpers extracted from [Keeper_turn_driver].

    See [.ml] for rationale. No behavior change from pre-RFC-0048 inline
    definitions. *)

val checkpoint_after_attempt :
  ?agent_ref:Masc_agent_core.Agent.t option ref ->
  Masc_agent_core.Agent.t option ->
  Masc_agent_core.Checkpoint.t option
