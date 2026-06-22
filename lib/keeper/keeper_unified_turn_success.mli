(** Success-path post-processing for [Keeper_unified_turn].

    Emits the terminal FSM transitions [Streaming -> Completing -> Done];
    this function is the single source of truth for those transitions on the
    success path and must be called at most once per turn.
    [Keeper_unified_turn.run_keeper_cycle] is the expected caller. *)

module For_testing : sig
  val no_work_budget_threshold_override
    :  stop_reason:Runtime_agent.stop_reason
    -> has_current_task:bool
    -> active_goal_ids:string list
    -> strong_evidence:bool
    -> surface_requires_evidence:bool
    -> observation:Keeper_world_observation.world_observation
    -> int option

  (** RFC-0276 §3.2 runtime-observed delivery classification (replaces the LLM
      self-declared [delivery_surface] as the no-progress detector input). *)
  type turn_delivery =
    | Peer_only
    | User_facing
    | Task_claim

  val classify_delivery
    :  tools:string list
    -> has_visible_text:bool
    -> turn_delivery

  val delivery_requires_evidence : turn_delivery -> bool
end

val handle
  :  config:Workspace.config
  -> base_dir:string
  -> meta:Keeper_meta_contract.keeper_meta
  -> turn_ctx_cell:Keeper_tool_call_log.turn_ctx_cell
  -> observation:Keeper_world_observation.world_observation
  -> previous_social_state:Keeper_social_model.social_state option
  -> final_execution:Keeper_turn_runtime_budget.runtime_execution
  -> latency_ms:int
  -> degraded_retry_applied:bool
  -> degraded_retry_runtime:string option
  -> fallback_reason:Keeper_error_classify.degraded_retry_reason option
  -> last_provider_timeout_budget:
       Keeper_turn_runtime_budget.provider_timeout_budget option
  -> current_turn_blocker_info:Keeper_meta_contract.blocker_info option
  -> keeper_turn_id:int
  -> ?turn_ref:Ids.Turn_ref.t
  -> Keeper_agent_run.run_result
  -> Keeper_meta_contract.keeper_meta
