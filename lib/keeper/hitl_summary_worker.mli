(** A provider config paired with the exact runtime id selected for judgment. *)
type summary_provider = private
  { runtime_id : string
  ; provider_config : Llm_provider.Provider_config.t
  }

val provider_config_for_summary : keeper_name:string -> summary_provider option

(** Spawn an asynchronous HITL context-summary worker for [runtime_id].
    The worker is fire-and-forget: it calls [on_summary] only for a validated
    LLM judgment and [on_failure] for every unavailable, timeout, transport, or
    parse failure. The caller is responsible for writing the result back to the
    approval entry (e.g. via [Keeper_approval_queue.attach_summary]). This
    keeps the worker decoupled from the queue and avoids a module cycle.
    [on_finish] runs exactly once even when the fiber is cancelled. *)
val spawn
  :  sw:Eio.Switch.t
  -> runtime_id:string
  -> ?provider_config:Llm_provider.Provider_config.t
  -> entry:Keeper_approval_queue.pending_approval
  -> on_summary:(Keeper_approval_queue.hitl_context_summary -> unit)
  -> on_failure:(reason:string -> retryable:bool -> unit)
  -> on_finish:(unit -> unit)
  -> unit
  -> unit

module For_testing : sig
  val system_prompt : unit -> (string, string) result

  (** How the judge is asked to return the summary. [Native_structured] uses
      provider-native json_schema; [Plain_json_text] is the degradation path for
      endpoints OAS cannot serve native structured output for. *)
  type summary_mode =
    | Native_structured
    | Plain_json_text

  val build_context_bundle
    : entry:Keeper_approval_queue.pending_approval -> Yojson.Safe.t

  val parse_summary
    :  generated_at:float
    -> model_run_id:string
    -> Yojson.Safe.t
    -> (Keeper_approval_queue.hitl_context_summary, string) result

  val summary_of_response
    :  generated_at:float
    -> mode:summary_mode
    -> Agent_sdk.Types.api_response
    -> (Keeper_approval_queue.hitl_context_summary, string) result

  (** Returns the clamped config plus the chosen output mode: [Native_structured]
      when {!Llm_provider.Provider_config.validate_output_schema_request} accepts
      a json_schema request for this endpoint, else [Plain_json_text]. The
      runtime.toml temperature for [runtime_id] overrides the subsystem fallback. *)
  val provider_config_for_summary
    :  runtime_id:string
    -> Llm_provider.Provider_config.t
    -> Llm_provider.Provider_config.t * summary_mode

  (** Strict complete-object parsing from model text (plain capability path). *)
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
