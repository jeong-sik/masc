(** Keeper_turn_driver — MASC named-cascade and model-label execution entry points.

    Public API for running OAS agents through MASC-managed named cascade
    profiles ([run_named]) or explicit model label ([run_model_by_label]),
    with optional MASC tool bridging variants.

    The facade intentionally exposes only the logical keeper entry points and
    typed MASC/OAS error helpers. Provider/model-shaped OAS runner helpers stay
    behind lower-level boundary modules.

    @since God file decomposition — extracted from oas_worker.ml *)

(** {1 MASC/OAS structured errors}

    Re-exported from {!Cascade_error_classify} (which itself includes
    {!Cascade_internal_error}). Using [include module type of] instead of a
    manual type copy so the interface stays structurally identical to the
    implementation's [include Cascade_error_classify]. *)

include module type of Cascade_error_classify

(** {1 Cascade error helpers} *)

val sdk_error_to_cascade_outcome :
  Agent_sdk.Error.sdk_error -> Cascade_fsm.provider_outcome option

val message_looks_like_cli_wrapped_hard_quota : string -> bool

val message_looks_like_cli_wrapped_max_turns : string -> bool

val message_looks_like_capacity_backpressure : string -> bool

val message_looks_like_resumable_cli_session : string -> bool

val sdk_error_to_resumable_cli_session :
  cascade_name:Cascade_name.t ->
  Agent_sdk.Error.sdk_error ->
  Agent_sdk.Error.sdk_error option

val sdk_error_is_resumable_cli_session : Agent_sdk.Error.sdk_error -> bool

val sdk_error_is_terminal_provider_runtime_failure :
  Agent_sdk.Error.sdk_error -> bool

val sdk_error_is_model_access_denied : Agent_sdk.Error.sdk_error -> bool

val sdk_error_is_required_tool_contract_violation :
  Agent_sdk.Error.sdk_error -> bool

val sdk_error_is_hard_quota : Agent_sdk.Error.sdk_error -> bool

val sdk_error_soft_rate_limited :
  Agent_sdk.Error.sdk_error -> float option option

val sdk_error_is_max_turns_exceeded : Agent_sdk.Error.sdk_error -> bool

val sdk_error_cascade_fallback_class :
  Agent_sdk.Error.sdk_error -> string option

(** [apply_stream_idle_timeout_default opt] returns [opt] when the caller
    supplied a value, otherwise injects
    [Env_config_keeper.KeeperKeepalive.stream_idle_timeout_sec]. Used at
    every {!run_model_by_label} / {!run_model_with_masc_tools} entry so a
    single-agent dashboard run cannot block forever on a stalled HTTP
    stream. *)
val apply_stream_idle_timeout_default : float option -> float option

(** {1 Turn pipeline records} *)

type provider_attempt_provenance =
  { model_source : string
  ; resolved_model_source : string
  ; capability_source : string
  ; fallback_authority : string
  ; provider_source_cascade : string option
  }

type provider_attempt_started_record =
  { started_provenance : provider_attempt_provenance
  ; started_is_last : bool
  ; started_per_provider_timeout_s : float option
  ; started_attempt_timeout_source : string
  ; started_attempt_watchdog_source : string
  ; started_liveness_mode : string
  ; started_liveness_budget_source : string option
  }

type provider_attempt_finished_record =
  { finished_provenance : provider_attempt_provenance
  ; finished_status : string
  ; finished_latency_ms : float
  ; finished_checkpoint_after_present : bool
  ; finished_error : Yojson.Safe.t
  ; finished_exception_kind : string option
  }

val provider_attempt_started_decision :
  provider_attempt_started_record -> Yojson.Safe.t

val provider_attempt_finished_decision :
  provider_attempt_finished_record -> Yojson.Safe.t

(** {1 Named cascade execution} *)

val run_named :
  cascade_name:string ->
  ?base_path:string ->
  ?keeper_name:string ->
  goal:string ->
  ?provider_filter:string list ->
  ?require_tool_choice_support:bool ->
  ?require_tool_support:bool ->
  ?priority:Llm_provider.Request_priority.t ->
  ?session_id:string ->
  ?system_prompt:string ->
  ?tools:Agent_sdk.Tool.t list ->
  ?initial_messages:Agent_sdk.Types.message list ->
  ?max_turns:int ->
  ?max_idle_turns:int ->
  ?stream_idle_timeout_s:float ->
  ?temperature:float ->
  ?max_tokens:int ->
  ?max_input_tokens:int ->
  ?max_cost_usd:float ->
  ?wait_timeout_sec:float ->
  ?accept:(Agent_sdk_response.api_response -> bool) ->
  ?guardrails:Agent_sdk.Guardrails.t ->
  ?hooks:Agent_sdk.Hooks.hooks ->
  ?context_reducer:Agent_sdk.Context_reducer.t ->
  ?memory:Agent_sdk.Memory.t ->
  ?tool_retry_policy:Agent_sdk.Tool_retry_policy.t ->
  ?required_tool_satisfaction:Agent_sdk.Completion_contract.required_tool_satisfaction ->
  ?raw_trace:Agent_sdk.Raw_trace.t ->
  ?on_event:(Agent_sdk.Types.sse_event -> unit) ->
  ?on_yield:(unit -> unit) ->
  ?on_resume:(unit -> unit) ->
  ?agent_ref:Agent_sdk.Agent.t option ref ->
  ?proof_ref:Masc_mcp_cdal_runtime.Cdal_proof.t option ref ->
  ?contract:Masc_mcp_cdal_runtime.Risk_contract.t ->
  ?transport:Masc_grpc_transport.t ->
  ?cli_transport_overrides:Cascade_runner.cli_transport_overrides ->
  ?allowed_paths:string list ->
  ?checkpoint_sidecar:Yojson.Safe.t ->
  ?cache_system_prompt:bool ->
  ?yield_on_tool:bool ->
  ?compact_ratio:float ->
  ?oas_auto_context_overflow_retry:bool ->
  ?checkpoint_dir:string ->
  ?context_injector:Agent_sdk.Hooks.context_injector ->
  ?context:Agent_sdk.Context.t ->
  ?slot_id:int ->
  ?enable_thinking:bool ->
  ?approval:Agent_sdk.Hooks.approval_callback ->
  ?exit_condition:(int -> bool) ->
  ?exit_condition_result:(int -> Cascade_runner.stop_reason * string option) ->
  ?summarizer:(Agent_sdk.Types.message list -> string) ->
  ?oas_checkpoint:Agent_sdk.Checkpoint.t ->
  ?event_bus:Agent_sdk.Event_bus.t ->
  ?runtime_manifest_context:Keeper_runtime_manifest.turn_context ->
  ?runtime_manifest_append:(Keeper_runtime_manifest.t -> unit) ->
  ?runtime_manifest_required_tool_names:string list ->
  ?sw:Eio.Switch.t ->
  ?net:Eio_context.eio_net ->
  ?per_provider_timeout_s:float ->
  unit ->
  (Cascade_runner.run_result, Agent_sdk.Error.sdk_error) result
(** Run a single [Agent.run] call with MASC-driven cascade model fallback.
    MASC drives the cascade FSM directly: resolves cascade providers,
    tries each with OAS, and uses [Cascade_fsm.decide] on failure.
    The cascade loop runs inside an admission queue permit. *)

module For_testing : sig
  val checkpoint_after_attempt :
    ?agent_ref:Agent_sdk.Agent.t option ref ->
    Agent_sdk.Agent.t option ->
    Agent_sdk.Checkpoint.t option

  val missing_required_tool_names_after_lane_by_name :
    required_tool_names:string list ->
    materialized_tool_names:string list ->
    string list

  val success_selected_model_raw : Cascade_runtime_candidate.t -> string option

  val cascade_tier_admission_policy_of_priority :
    Llm_provider.Request_priority.t ->
    Cascade_tier_admission.admission_policy

  val with_cascade_tier_admission_for_testing :
    admission:Cascade_tier_admission.t ->
    enabled:bool ->
    tier_id:string ->
    admission_policy:Cascade_tier_admission.admission_policy ->
    (unit -> 'a) ->
    ('a, Cascade_saturation_signal.t) result
end
