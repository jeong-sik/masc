(** Failure-path post-processing for [Keeper_unified_turn]. *)

val record_failure_observation
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> err:Agent_core.Error.t
  -> error_text:string
  -> unit
(** Record explicit failure evidence without rewriting Keeper lifecycle or
    escalating a numeric streak into pause/crash.
    Every failure advances the same consecutive-failure observation. *)
