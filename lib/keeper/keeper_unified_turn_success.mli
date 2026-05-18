(** Success-path post-processing for [Keeper_unified_turn]. *)

val handle
  :  config:Coord.config
  -> base_dir:string
  -> meta:Keeper_types.keeper_meta
  -> observation:Keeper_world_observation.world_observation
  -> previous_social_state:Keeper_social_model.social_state option
  -> final_execution:Keeper_turn_cascade_budget.cascade_execution
  -> latency_ms:int
  -> semaphore_wait_ms:int
  -> degraded_retry_applied:bool
  -> degraded_retry_cascade:string option
  -> fallback_reason:Keeper_error_classify.degraded_retry_reason option
  -> last_timeout_budget:
       Keeper_turn_cascade_budget.oas_timeout_budget_resolution option
  -> current_turn_blocker_info:Keeper_meta_contract.blocker_info option
  -> keeper_turn_id:int
  -> Keeper_agent_run.run_result
  -> Keeper_types.keeper_meta
