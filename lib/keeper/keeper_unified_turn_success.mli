(** Success-path post-processing for [Keeper_unified_turn].

    Emits the terminal FSM transitions [Streaming -> Completing -> Done];
    this function is the single source of truth for those transitions on the
    success path and must be called at most once per turn.
    [Keeper_unified_turn.run_keeper_cycle] is the expected caller. *)

module For_testing : sig
  val budget_exhausted_no_progress_threshold_override
    :  stop_reason:Runtime_agent.stop_reason
    -> strong_evidence:bool
    -> surface_requires_evidence:bool
    -> observation:Keeper_world_observation.world_observation
    -> int option

  (** RFC-0276 §3.2 runtime-observed delivery classification (replaces the LLM
      self-declared delivery header as the no-progress detector input). *)
  type turn_delivery =
    | Peer_only
    | User_facing  (** externally delivered reactive visible reply; exempt *)
    | Internal_prose
        (** Visible prose not externally delivered to the prompting surface;
            requires evidence. *)
    | Task_claim

  type reply_delivery =
    | Internal_only
    | Externally_delivered

  val classify_delivery
    :  is_autonomous:bool
    -> reply_delivery:reply_delivery
    -> tools:string list
    -> has_visible_text:bool
    -> turn_delivery

  val delivery_requires_evidence : turn_delivery -> bool

  (** Outcome-aware substantive evidence (audit D1): an execution/completion
      tool whose typed outcome is not a failure. A [None] typed outcome keeps
      the legacy name-based behavior. *)
  val has_substantive_tool_calls_with_outcome
    : (string * Keeper_tool_outcome.t option) list -> bool

  (** Did a claim-context call bind work (audit D3)? [Progress]/[None] => yes;
      a typed [No_progress]/[Error] claim did not bind work, so a [Task_claim]
      turn is no longer exempt from the no-progress streak. *)
  val claim_bound_work
    : (string * Keeper_tool_outcome.t option) list -> bool

  val apply_loop_detectors
    :  config:Workspace.config
    -> observation:Keeper_world_observation.world_observation
    -> meta:Keeper_meta_contract.keeper_meta
    -> Keeper_meta_contract.keeper_meta
    -> Keeper_agent_run.run_result
    -> Keeper_meta_contract.keeper_meta
end

val handle
  :  config:Workspace.config
  -> base_dir:string
  -> meta:Keeper_meta_contract.keeper_meta
  -> turn_ctx_cell:Keeper_tool_call_log.turn_ctx_cell
  -> observation:Keeper_world_observation.world_observation
  -> final_execution:Keeper_turn_runtime_budget.runtime_execution
  -> latency_ms:int
  -> degraded_retry_applied:bool
  -> degraded_retry_runtime:string option
  -> fallback_reason:Keeper_error_classify.degraded_retry_reason option
  -> last_provider_timeout_budget:
       Keeper_turn_runtime_budget.provider_timeout_budget option
  -> current_turn_blocker_info:Keeper_meta_contract.blocker_info option
  -> keeper_turn_id:int
  -> Keeper_agent_run.run_result
  -> Keeper_meta_contract.keeper_meta
