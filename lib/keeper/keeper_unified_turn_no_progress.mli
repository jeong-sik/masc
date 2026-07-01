(** No-progress loop recovery helpers for the unified keeper turn. *)

val failure_reason_code : string

val mark_loop_detected
  :  ?no_progress_reason:
       Keeper_no_progress_loop_detector.no_progress_reason
  -> config:Workspace.config
  -> Keeper_meta_contract.keeper_meta
  -> streak:int
  -> threshold:int
  -> Keeper_meta_contract.keeper_meta

val clear_if_recovered
  :  config:Workspace.config
  -> Keeper_meta_contract.keeper_meta
  -> previous_streak:int
  -> was_latched:bool
  -> Keeper_meta_contract.keeper_meta

val clear_for_operator_resume
  :  base_path:string
  -> Keeper_meta_contract.keeper_meta
  -> (Keeper_meta_contract.keeper_meta, string) result
