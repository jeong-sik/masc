(** Spawn an asynchronous HITL context-summary worker.
    The worker is fire-and-forget: it calls [on_summary] or [on_failure] on
    the calling fiber, and the caller is responsible for writing the result
    back to the approval entry (e.g. via [Keeper_approval_queue.update_pending_entry]).
    This keeps the worker decoupled from the queue and avoids a module cycle. *)
val spawn
  :  sw:Eio.Switch.t
  -> ?provider_config:Llm_provider.Provider_config.t
  -> entry:Keeper_approval_queue_rules_types.pending_approval
  -> on_summary:(Keeper_approval_queue_rules_types.hitl_context_summary -> unit)
  -> on_failure:(reason:string -> retryable:bool -> unit)
  -> unit
  -> unit

module For_testing : sig
  val build_context_bundle
    : entry:Keeper_approval_queue_rules_types.pending_approval -> Yojson.Safe.t

  val parse_summary
    :  generated_at:float
    -> model_run_id:string
    -> Yojson.Safe.t
    -> Keeper_approval_queue_rules_types.hitl_context_summary

  val summary_of_response
    :  generated_at:float
    -> Agent_sdk.Types.api_response
    -> (Keeper_approval_queue_rules_types.hitl_context_summary, string) result
end
