(** Spawn an asynchronous HITL context-summary worker.
    The worker is fire-and-forget: it calls [on_summary] with either the LLM
    summary or a deterministic request-metadata fallback. [on_failure] is
    reserved for unexpected worker failures where even fallback generation did
    not run. The caller is responsible for writing the result back to the
    approval entry (e.g. via [Keeper_approval_queue.update_pending_entry]). This
    keeps the worker decoupled from the queue and avoids a module cycle. *)
val spawn
  :  sw:Eio.Switch.t
  -> ?provider_config:Llm_provider.Provider_config.t
  -> entry:Keeper_approval_queue_rules_types.pending_approval
  -> on_summary:(Keeper_approval_queue_rules_types.hitl_context_summary -> unit)
  -> on_failure:(reason:string -> retryable:bool -> unit)
  -> unit
  -> unit

module For_testing : sig
  (** How the judge is asked to return the summary. [Native_structured] uses
      provider-native json_schema; [Plain_json_text] is the degradation path for
      endpoints OAS cannot serve native structured output for. *)
  type summary_mode =
    | Native_structured
    | Plain_json_text

  val build_context_bundle
    : entry:Keeper_approval_queue_rules_types.pending_approval -> Yojson.Safe.t

  val fallback_summary
    :  generated_at:float
    -> entry:Keeper_approval_queue_rules_types.pending_approval
    -> context_bundle:Yojson.Safe.t
    -> reason:string
    -> Keeper_approval_queue_rules_types.hitl_context_summary

  val parse_summary
    :  generated_at:float
    -> model_run_id:string
    -> Yojson.Safe.t
    -> Keeper_approval_queue_rules_types.hitl_context_summary

  val summary_of_response
    :  generated_at:float
    -> mode:summary_mode
    -> Agent_sdk.Types.api_response
    -> (Keeper_approval_queue_rules_types.hitl_context_summary, string) result

  (** Returns the clamped config plus the chosen output mode: [Native_structured]
      when {!Llm_provider.Provider_config.validate_output_schema_request} accepts
      a json_schema request for this endpoint, else [Plain_json_text]. *)
  val provider_config_for_summary
    :  Llm_provider.Provider_config.t
    -> Llm_provider.Provider_config.t * summary_mode

  (** Best-effort single-JSON-object extraction from model text (plain path). *)
  val extract_json_object : string -> (Yojson.Safe.t, string) result

  (** Metric outcomes emitted when the LLM call fails after [summary_mode] has
      been selected. Plain-mode failures include [degraded_plain_json] before
      the terminal failure outcome so degradation is observable even without a
      model response. *)
  val summary_llm_error_outcomes
    :  mode:summary_mode
    -> Agent_sdk.Error.sdk_error
    -> string list

  val summary_version : int
end
