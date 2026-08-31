(** Failure-path post-processing for [Keeper_unified_turn]. *)

val record_failure_observation
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> err:Agent_core.Error.t
  -> error_text:string
  -> unit
(** Record one turn failure: advance the durable crash-accounting streak and
    health. Every failure class counts (RFC turn-failure-visible-stop,
    #32105) — there is no exemption and no per-class budget. This does not
    rewrite Keeper lifecycle: the phase machine derives visibility from the
    streak, and the next successful turn (or an operator clear) resets it. *)
