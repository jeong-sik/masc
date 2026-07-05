(** Keeper_turn_driver — MASC named-runtime and model-label execution entry points.

    Public API for running OAS agents through MASC-managed named runtime
    profiles ([run_named]) or explicit model label ([run_model_by_label]),
    with optional MASC tool bridging variants.

    The facade intentionally exposes only the logical keeper entry points and
    typed MASC/OAS error helpers. Provider/model-shaped OAS runner helpers stay
    behind lower-level boundary modules.

    @since God file decomposition — extracted from oas_worker.ml *)

(** {1 MASC/OAS structured errors}

    Re-exported from {!Keeper_internal_error}. The manifest aliases keep the
    facade's public types identical to the internal-error SSOT instead of
    copying fresh nominal types into this interface. *)

include
  module type of Keeper_internal_error
    with type provider_rejection = Keeper_internal_error.provider_rejection
     and type capacity_backpressure_source =
      Keeper_internal_error.capacity_backpressure_source
     and type capacity_retry_after = Keeper_internal_error.capacity_retry_after
     and type runtime_exhaustion_reason =
      Keeper_internal_error.runtime_exhaustion_reason
     and type accept_rejection_kind =
      Keeper_internal_error.accept_rejection_kind
     and type accept_response_shape =
      Keeper_internal_error.accept_response_shape
     and type tool_progress_effect =
      Keeper_internal_error.tool_progress_effect
     and type masc_internal_error = Keeper_internal_error.masc_internal_error

(** {1 Provider error helpers} *)

val message_looks_like_cli_wrapped_hard_quota : string -> bool

val message_looks_like_capacity_backpressure : string -> bool

val sdk_error_is_terminal_provider_runtime_failure :
  Agent_sdk.Error.sdk_error -> bool

val sdk_error_is_hard_quota : Agent_sdk.Error.sdk_error -> bool

val sdk_error_soft_rate_limited :
  Agent_sdk.Error.sdk_error -> float option option


val sdk_error_runtime_fallback_class :
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
  ; provider_source_runtime : string option
  }

type provider_attempt_started_record =
  { started_provenance : provider_attempt_provenance
  ; started_is_last : bool
  ; started_per_provider_timeout_s : float option
  ; started_attempt_timeout_source : string
  ; started_attempt_watchdog_source : string
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

type context_window_rebudget =
  { requested_context_window : int option
  ; final_runtime_context_window : int
  ; resolved_context_window : int
  ; context_window_rebudgeted : bool
  }

(** {1 Named runtime execution} *)

val run_named :
  runtime_id:string ->
  ?keeper_name:string ->
  base_path:string ->
  goal:string ->
  ?goal_blocks:Agent_sdk.Types.content_block list ->
  ?priority:Llm_provider.Request_priority.t ->
  ?session_id:string ->
  ?system_prompt:string ->
  ?tools:Agent_sdk.Tool.t list ->
  ?initial_messages:Agent_sdk.Types.message list ->
  ?max_turns:int ->
  max_idle_turns:int ->
  ?stream_idle_timeout_s:float ->
  ?body_timeout_s:float ->
  ?temperature:float ->
  ?max_tokens:int ->
  ?max_tokens_for_runtime:(runtime_id:string -> int) ->
  ?accept:(Agent_sdk_response.api_response -> bool) ->
  ?guardrails:Agent_sdk.Guardrails.t ->
  ?hooks:Agent_sdk.Hooks.hooks ->
  ?context_reducer:Agent_sdk.Context_reducer.t ->
  ?raw_trace:Agent_sdk.Raw_trace.t ->
  ?on_event:(Agent_sdk.Types.sse_event -> unit) ->
  ?on_yield:(unit -> unit) ->
  ?on_resume:(unit -> unit) ->
  ?agent_ref:Agent_sdk.Agent.t option ref ->
  ?transport:Masc_grpc_transport.t ->
  ?allowed_paths:string list ->
  ?checkpoint_sidecar:Yojson.Safe.t ->
  ?cache_system_prompt:bool ->
  ?yield_on_tool:bool ->
  ?compact_ratio:float ->
  ?context_window_tokens:int ->
  ?oas_auto_context_overflow_retry:bool ->
  ?checkpoint_dir:string ->
  ?context_injector:Agent_sdk.Hooks.context_injector ->
  ?context:Agent_sdk.Context.t ->
  ?enable_thinking:bool ->
  ?approval:Agent_sdk.Hooks.approval_callback ->
  ?exit_condition:(int -> bool) ->
  ?exit_condition_result:(int -> Runtime_agent.stop_reason * string option) ->
  ?summarizer:(Agent_sdk.Types.message list -> string) ->
  ?oas_checkpoint:Agent_sdk.Checkpoint.t ->
  ?trace_link:string * string ->
  ?event_bus:Agent_sdk.Event_bus.t ->
  ?on_runtime_observation:(Runtime_observation.runtime_observation -> unit) ->
  ?runtime_manifest_context:Keeper_runtime_manifest.turn_context ->
  ?runtime_manifest_append:(Keeper_runtime_manifest.t -> unit) ->
  ?provider_config_transform:
    (Llm_provider.Provider_config.t ->
    (Llm_provider.Provider_config.t, Agent_sdk.Error.sdk_error) result) ->
  ?sw:Eio.Switch.t ->
  ?net:Eio_context.eio_net ->
  ?per_provider_timeout_s:float ->
  unit ->
  (Runtime_agent.run_result, Agent_sdk.Error.sdk_error) result
(** Run a single [Agent.run] call with MASC-driven runtime model fallback.
    MASC drives the runtime FSM directly: resolves runtime providers,
    tries each with OAS, and uses [Runtime_fsm.decide] on failure.
    The runtime loop runs inside a capacity-managed queue permit. *)

type attempt_inference_policy =
  { attempt_enable_thinking : bool option
  ; attempt_preserve_thinking : bool option
  ; attempt_max_tokens : int
  }

module For_testing : sig
  val checkpoint_after_attempt :
    ?agent_ref:Agent_sdk.Agent.t option ref ->
    Agent_sdk.Agent.t option ->
    Agent_sdk.Checkpoint.t option

  val success_selected_model_raw : Runtime_candidate.t -> string option

  val record_candidate_health_error :
    keeper_name:string -> Runtime_candidate.t -> Agent_sdk.Error.sdk_error -> unit

  val apply_accept :
    ?initial_messages:Agent_sdk.Types.message list ->
    runtime_id:string ->
    accept:(Agent_sdk_response.api_response -> bool) ->
    Runtime_agent.run_result ->
    (Runtime_agent.run_result, Agent_sdk.Error.sdk_error) result

  val max_execution_time_for_attempt :
    ?per_provider_timeout_s:float -> unit -> float option

  val last_tool_progress_context_string_of_messages :
    Agent_sdk.Types.message list -> string option

  val sdk_error_of_nonretryable_attempt_error :
    runtime_id:string ->
    original_error:Agent_sdk.Error.sdk_error ->
    Llm_provider.Http_client.http_error ->
    Agent_sdk.Error.sdk_error

  val first_runtime_after_modality_reroute :
    keeper_name:string ->
    assignment_id:string ->
    first_candidate_id:string ->
    first_candidate:Runtime.t ->
    Runtime_agent.reroute_decision ->
    string * Runtime.t

  val lane_modality_reroute_decision :
    checkpoint_messages:Agent_sdk.Types.message list ->
    initial_messages:Agent_sdk.Types.message list ->
    goal_blocks:Agent_sdk.Types.content_block list ->
    first_candidate:Runtime.t ->
    remaining_runtimes:Runtime.t list ->
    Runtime_agent.reroute_decision

  val dedupe_runtimes_preserve_order : Runtime.t list -> Runtime.t list

  val media_degrade_manifest_decision :
    runtime_id:string -> (string * int) list -> Yojson.Safe.t

  val resolve_context_window_tokens_after_runtime_selection :
    requested_context_window:int option ->
    final_runtime_context_window:int ->
    (context_window_rebudget, Agent_sdk.Error.sdk_error) result

  val attempt_inference_policy :
    ?max_tokens_for_runtime:(runtime_id:string -> int) ->
    runtime_id:string ->
    fallback_enable_thinking:bool option ->
    fallback_max_tokens:int ->
    unit ->
    attempt_inference_policy

  val attempt_runtime_candidates :
    ?allow_accept_no_progress_retry:
      (runtime_id:string -> attempt:int -> Agent_sdk.Error.sdk_error -> bool) ->
    runtime_id:string ->
    runtime_id_of:('candidate -> string) ->
    emit_runtime_manifest:
      (?status:string ->
      ?decision:Yojson.Safe.t ->
      Keeper_runtime_manifest.event_kind ->
      unit) ->
    run_attempt:
      (?resume_checkpoint:Agent_sdk.Checkpoint.t ->
      idx:int ->
      runtime_id:string ->
      'candidate ->
      ('result, Agent_sdk.Error.sdk_error) result * Agent_sdk.Checkpoint.t option) ->
    'candidate list ->
    ('result, Agent_sdk.Error.sdk_error) result

  val accept_no_progress_should_try_next : Agent_sdk.Error.sdk_error -> bool

  val accept_no_progress_read_only_should_try_next :
    Agent_sdk.Error.sdk_error -> bool

  val accept_rejected_result_should_try_next :
    is_last:bool -> Agent_sdk.Error.sdk_error -> bool

  val runtime_exhaustion_reason_of_http_error :
    Llm_provider.Http_client.http_error option ->
    Keeper_internal_error.runtime_exhaustion_reason

  val sdk_error_of_exhausted :
    runtime_id:string ->
    Llm_provider.Http_client.http_error option ->
    Agent_sdk.Error.sdk_error
end
