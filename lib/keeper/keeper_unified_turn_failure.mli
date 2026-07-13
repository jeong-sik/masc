(** Failure-path post-processing for [Keeper_unified_turn]. *)

val record_failure_observation
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> is_auto_recoverable:bool
  -> err:Agent_sdk.Error.sdk_error
  -> error_text:string
  -> unit
(** Record explicit failure evidence without rewriting Keeper lifecycle or
    escalating a numeric streak into pause/crash. *)
