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
     and type provider_cooldown_cause =
      Keeper_internal_error.provider_cooldown_cause
     and type transcript_quarantine_reason =
      Keeper_internal_error.transcript_quarantine_reason
     and type gate_replay_repair_stage =
      Keeper_internal_error.gate_replay_repair_stage
     and type masc_internal_error = Keeper_internal_error.masc_internal_error

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

(** {1 Named runtime execution} *)

type deferred_runtime_lane = private
  { assignment_id : string
  ; failed_runtime_id : string
  ; next_runtime_id : string
  ; later_runtime_ids : string list
  ; failure : Masc_agent_core.Error.sdk_error
  }

val deferred_runtime_ids : deferred_runtime_lane -> string list
val equal_deferred_runtime_lane :
  deferred_runtime_lane -> deferred_runtime_lane -> bool

val run_named :
  runtime_id:string ->
  ?keeper_name:string ->
  base_path:string ->
  goal:string ->
  ?goal_blocks:Masc_agent_core.Types.content_block list ->
  ?session_id:string ->
  ?system_prompt:string ->
  ?tools:Masc_agent_core.Tool.t list ->
  ?initial_messages:Masc_agent_core.Types.message list ->
  ?model_input_projection:Masc_agent_core.Agent.model_input_projection ->
  ?stream_idle_timeout_s:float ->
  ?body_timeout_s:float ->
  ?temperature:float ->
  ?accept:(Masc_agent_core_response.api_response -> bool) ->
  ?hooks:Masc_agent_core.Hooks.hooks ->
  ?raw_trace:Masc_agent_core.Raw_trace.t ->
  ?on_event:(Masc_agent_core.Types.sse_event -> unit) ->
  ?on_yield:(unit -> unit) ->
  ?on_resume:(unit -> unit) ->
  ?agent_ref:Masc_agent_core.Agent.t option ref ->
  ?transport:Masc_grpc_transport.t ->
  ?checkpoint_sidecar:Yojson.Safe.t ->
  ?cache_system_prompt:bool ->
  ?yield_on_tool:bool ->
  ?checkpoint_sink:Masc_agent_core.Agent.checkpoint_sink ->
  ?context_injector:Masc_agent_core.Hooks.context_injector ->
  ?context:Masc_agent_core.Context.t ->
  ?enable_thinking:bool ->
  ?cooperative_yield_probe:Runtime_agent.cooperative_yield_probe ->
  ?oas_checkpoint:Masc_agent_core.Checkpoint.t ->
  ?trace_link:string * string ->
  ?event_bus:Masc_agent_core.Event_bus.t ->
  ?on_runtime_observation:(Runtime_observation.runtime_observation -> unit) ->
  ?on_request_wire_observation:
    (runtime_id:string ->
     max_request_body_bytes:int ->
     body_bytes:int ->
     unit) ->
  ?runtime_manifest_context:Keeper_runtime_manifest.turn_context ->
  ?runtime_manifest_append:(Keeper_runtime_manifest.t -> unit) ->
  ?deferred_runtime_lane:deferred_runtime_lane ->
  ?on_runtime_retry_deferred:(deferred_runtime_lane -> unit) ->
  ?on_deferred_runtime_consumed:(unit -> unit) ->
  ?provider_config_transform:
    (Llm_provider.Provider_config.t ->
    (Llm_provider.Provider_config.t, Masc_agent_core.Error.sdk_error) result) ->
  ?sw:Eio.Switch.t ->
  ?net:Eio_context.eio_net ->
  unit ->
  (Runtime_agent.run_result, Masc_agent_core.Error.sdk_error) result
(** Run a single [Agent.run] call with MASC-driven runtime model fallback.
    MASC drives the runtime FSM directly: resolves runtime providers,
    resolves each candidate's model temperature before trying it with OAS, and
    uses [Runtime_fsm.decide] on failure.
    The runtime loop runs inside a capacity-managed queue permit. *)

type attempt_inference_policy =
  { attempt_enable_thinking : bool option
  ; attempt_preserve_thinking : bool option
  }

module For_testing : sig
  val make_deferred_runtime_lane :
    assignment_id:string ->
    failed_runtime_id:string ->
    next_runtime_id:string ->
    later_runtime_ids:string list ->
    failure:Masc_agent_core.Error.sdk_error ->
    deferred_runtime_lane

  type provider_attempt_outcomes

  val project_provider_attempt_result :
    replay_prefix_projection:Keeper_replay_prefix.projection ->
    (Runtime_agent.run_result, Masc_agent_core.Error.sdk_error) result ->
    provider_attempt_outcomes

  val provider_result :
    provider_attempt_outcomes ->
    (Runtime_agent.run_result, Masc_agent_core.Error.sdk_error) result

  val turn_result :
    provider_attempt_outcomes ->
    (Runtime_agent.run_result, Masc_agent_core.Error.sdk_error) result

  val checkpoint_after_attempt :
    ?agent_ref:Masc_agent_core.Agent.t option ref ->
    Masc_agent_core.Agent.t option ->
    Masc_agent_core.Checkpoint.t option

  val success_selected_model_raw : Runtime_candidate.t -> string option

  val apply_accept :
    runtime_id:string ->
    accept:(Masc_agent_core_response.api_response -> bool) ->
    Runtime_agent.run_result ->
    (Runtime_agent.run_result, Masc_agent_core.Error.sdk_error) result

  val first_runtime_after_modality_reroute :
    keeper_name:string ->
    assignment_id:string ->
    first_candidate_id:string ->
    first_candidate:Runtime.t ->
    Runtime_agent.reroute_decision ->
    string * Runtime.t

  val lane_modality_reroute_decision :
    checkpoint_messages:Masc_agent_core.Types.message list ->
    initial_messages:Masc_agent_core.Types.message list ->
    goal_blocks:Masc_agent_core.Types.content_block list ->
    first_candidate:Runtime.t ->
    remaining_runtimes:Runtime.t list ->
    Runtime_agent.reroute_decision

  val dedupe_runtimes_preserve_order : Runtime.t list -> Runtime.t list
  val resolve_runtime_candidates :
    string list ->
    (Runtime.t list, Masc_agent_core.Error.sdk_error) result

  val resolve_runtime_candidate_for_attempt :
    ?on_missing:(unit -> unit) ->
    string ->
    (Runtime.t, Masc_agent_core.Error.sdk_error) result

  val media_degrade_manifest_decision :
    runtime_id:string -> (string * int) list -> Yojson.Safe.t

  val attempt_inference_policy :
    runtime_id:string ->
    fallback_enable_thinking:bool option ->
    unit ->
    attempt_inference_policy

  val attempt_runtime_candidates :
    ?allow_retry:
      (runtime_id:string -> attempt:int -> Masc_agent_core.Error.sdk_error -> bool) ->
    ?allow_accept_no_progress_retry:
      (runtime_id:string -> attempt:int -> Masc_agent_core.Error.sdk_error -> bool) ->
    ?lane_id:string ->
    ?on_retry_deferred:(deferred_runtime_lane -> unit) ->
    runtime_id:string ->
    runtime_id_of:('candidate -> string) ->
    emit_runtime_manifest:
      (?status:string ->
      ?decision:Yojson.Safe.t ->
      Keeper_runtime_manifest.event_kind ->
      unit) ->
    run_attempt:
      (idx:int ->
      runtime_id:string ->
      'candidate ->
      ('result, Masc_agent_core.Error.sdk_error) result * Masc_agent_core.Checkpoint.t option) ->
    'candidate list ->
    ('result, Masc_agent_core.Error.sdk_error) result

  val observe_checkpoint_stage :
    bool Atomic.t -> Masc_agent_core.Agent.checkpoint_stage -> unit

  val same_run_retry_allowed : bool Atomic.t -> bool

  val accept_no_progress_should_try_next : Masc_agent_core.Error.sdk_error -> bool

end
