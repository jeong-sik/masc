(** Failure-path post-processing for [Keeper_unified_turn]. *)

val record_failure_and_maybe_escalate
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> updated_meta:Keeper_meta_contract.keeper_meta
  -> is_auto_recoverable:bool
  -> err:Agent_sdk.Error.sdk_error
  -> error_text:string
  -> unit
