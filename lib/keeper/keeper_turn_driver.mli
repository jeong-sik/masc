(** Keeper_turn_driver — MASC named-runtime and model-label execution entry points.

    Public API for running AGENT_CORE agents through MASC-managed named runtime
    profiles ([run_named]) or explicit model label ([run_model_by_label]),
    with optional MASC tool bridging variants.

    The facade intentionally exposes only the logical keeper entry points and
    typed MASC/AGENT_CORE error helpers. Provider/model-shaped AGENT_CORE runner helpers stay
    behind lower-level boundary modules.

    Owns one Keeper turn over the MASC runtime boundary. *)

(** {1 MASC/AGENT_CORE structured errors}

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
     and type transcript_quarantine_reason =
      Keeper_internal_error.transcript_quarantine_reason
     and type gate_replay_repair_stage =
      Keeper_internal_error.gate_replay_repair_stage
     and type masc_internal_error = Keeper_internal_error.masc_internal_error

(** {1 Turn pipeline records} *)

(** {1 Named runtime execution} *)

type deferred_runtime_lane = private
  { assignment_id : string
  ; failed_runtime_id : string
  ; next_runtime_id : string
  ; later_runtime_ids : string list
  ; failure : Agent_core.Error.t
  }

val deferred_runtime_ids : deferred_runtime_lane -> string list
val quota_ordered_deferred_runtime_lane :
  now:float -> deferred_runtime_lane -> deferred_runtime_lane
(** Apply active quota-window ordering to a frozen deferred suffix while
    preserving its assignment and failure evidence. Call once before building
    pre-dispatch execution so prompt shaping and dispatch consume the same
    selected runtime. *)
val equal_deferred_runtime_lane :
  deferred_runtime_lane -> deferred_runtime_lane -> bool

type named_run_result =
  { run_result : Runtime_agent.run_result
  ; selected_runtime_id : string
  ; selected_max_context : int
  ; checkpoint_owner : Runtime_execution.checkpoint_owner
  ; lane_attempt_index : int
    (** Position of the winning candidate in this turn's lane walk
        ([attempt_runtime_candidates]'s [idx], 0-based). 0 means the turn
        settled on the first candidate; a later index means the lane
        rotated past one or more failed candidates before landing here.
        This is the truth source for the execution receipt's
        [runtime_fallback_applied] / [runtime_outcome]. *)
  }

type runtime_attempt =
  { runtime_id : string
  ; lane_attempt_index : int
  ; checkpoint_owner : Runtime_execution.checkpoint_owner
  }
(** Exact materialized candidate selected immediately before dispatch. Lane
    assignment ids and later runtime-table lookups are not attempt authority. *)

val run_named :
  runtime_id:string ->
  ?keeper_name:string ->
  ?pre_tool_rejects:Keeper_official_client_host.rejected_tool_call list ref ->
  base_path:string ->
  goal:string ->
  ?goal_blocks:Agent_core.Types.content_block list ->
  ?session_id:string ->
  ?system_prompt:string ->
  ?tools:Agent_core.Tool.t list ->
  ?deferred_tool_surface:Keeper_deferred_tool_index.surface ->
  ?initial_messages:Agent_core.Types.message list ->
  ?model_input_projection:Agent_core.Agent.model_input_projection ->
  ?stream_idle_timeout_s:float ->
  ?body_timeout_s:float ->
  ?temperature:float ->
  ?accept:(Agent_core.Types.api_response -> bool) ->
  ?hooks:Agent_core.Hooks.hooks ->
  ?approval_gate:Keeper_tool_approval_gate.t ->
  ?raw_trace:Agent_core.Raw_trace.t ->
  ?on_event:(Agent_core.Types.sse_event -> unit) ->
  ?on_yield:(unit -> unit) ->
  ?on_resume:(unit -> unit) ->
  ?agent_ref:Agent_core.Agent.t option ref ->
  ?transport:Masc_grpc_transport.t ->
  ?checkpoint_sidecar:Yojson.Safe.t ->
  ?cache_system_prompt:bool ->
  ?yield_on_tool:bool ->
  ?checkpoint_sink:Agent_core.Agent.checkpoint_sink ->
  ?context_injector:Agent_core.Hooks.context_injector ->
  ?context:Agent_core.Context.t ->
  ?terminal_effect_state:(unit -> Keeper_tools_agent_core.terminal_effect_state) ->
  ?enable_thinking:bool ->
  ?cooperative_yield_probe:Runtime_agent.cooperative_yield_probe ->
  ?agent_core_checkpoint:Agent_core.Checkpoint.t ->
  ?trace_link:string * string ->
  ?event_bus:Agent_core.Event_bus.t ->
  ?on_runtime_observation:(Runtime_observation.runtime_observation -> unit) ->
  ?on_request_wire_observation:
    (runtime_id:string ->
     max_request_body_bytes:int ->
     body_bytes:int ->
     unit) ->
  ?on_official_client_result_handoff:
    (runtime_id:string ->
     invocation:Agent_core.Tool_contract.Invocation.t ->
     content:string ->
       unit) ->
  ?on_official_client_native_action:
    (runtime_id:string -> official_turn:int ->
     identity:Runtime_native_tools.action_identity -> tool_name:string -> unit) ->
  ?on_model_input_window_observation:
    (measurement:Turn_record.model_input_measurement
     -> Runtime_model_input_tail_window.window_observation
     -> unit) ->
  ?runtime_manifest_context:Keeper_runtime_manifest.turn_context ->
  ?runtime_manifest_append:(Keeper_runtime_manifest.t -> unit) ->
  ?deferred_runtime_lane:deferred_runtime_lane ->
  ?on_runtime_attempt:(runtime_attempt -> unit) ->
  ?on_runtime_retry_deferred:(deferred_runtime_lane -> unit) ->
  ?on_runtime_attempt_error:
    (runtime_id:string -> attempt:int -> Agent_core.Error.t -> unit) ->
  ?on_deferred_runtime_consumed:(unit -> unit) ->
  ?provider_config_transform:
    (Llm_provider.Provider_config.t ->
    (Llm_provider.Provider_config.t, Agent_core.Error.t) result) ->
  ?sw:Eio.Switch.t ->
  ?net:Eio_context.eio_net ->
  unit ->
  (named_run_result, Agent_core.Error.t) result
(** Run a single [Agent.run] call with MASC-driven runtime model fallback.
    MASC drives the runtime FSM directly: resolves runtime providers,
    resolves each candidate's model temperature before trying it with AGENT_CORE, and
    uses [Runtime_fsm.decide] on failure.
    The runtime loop runs inside a capacity-managed queue permit.

    [on_runtime_attempt_error] observes every typed candidate failure after
    its runtime manifest row is emitted. It does not change candidate
    selection or the final error; verifier callers use it to aggregate
    retryability across a bare runtime and its terminal default fallback. *)

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
    failure:Agent_core.Error.t ->
    deferred_runtime_lane

  type provider_attempt_outcomes

  val project_provider_attempt_result :
    replay_prefix_projection:Keeper_replay_prefix.projection ->
    (Runtime_agent.run_result, Agent_core.Error.t) result ->
    provider_attempt_outcomes

  val provider_result :
    provider_attempt_outcomes ->
    (Runtime_agent.run_result, Agent_core.Error.t) result

  val turn_result :
    provider_attempt_outcomes ->
    (Runtime_agent.run_result, Agent_core.Error.t) result

  val checkpoint_after_attempt :
    ?agent_ref:Agent_core.Agent.t option ref ->
    Agent_core.Agent.t option ->
    Agent_core.Checkpoint.t option

  val success_selected_model_raw : Runtime_candidate.t -> string option

  val apply_accept :
    runtime_id:string ->
    accept:(Agent_core.Types.api_response -> bool) ->
    Runtime_agent.run_result ->
    (Runtime_agent.run_result, Agent_core.Error.t) result

  val apply_official_client_accept :
    runtime_id:string ->
    accept:(Agent_core.Types.api_response -> bool) ->
    terminal_effect_state:(unit -> Keeper_tools_agent_core.terminal_effect_state) ->
    Runtime_agent.run_result ->
    (Runtime_agent.run_result, Agent_core.Error.t) result

  val first_runtime_after_modality_reroute :
    keeper_name:string ->
    assignment_id:string ->
    first_candidate_id:string ->
    first_candidate:Runtime.t ->
    Runtime_agent.reroute_decision ->
    string * Runtime.t

  val lane_modality_reroute_decision :
    checkpoint_messages:Agent_core.Types.message list ->
    initial_messages:Agent_core.Types.message list ->
    goal_blocks:Agent_core.Types.content_block list ->
    first_candidate:Runtime.t ->
    remaining_runtimes:Runtime.t list ->
    Runtime_agent.reroute_decision

  val dedupe_runtimes_preserve_order : Runtime.t list -> Runtime.t list
  val resolve_runtime_candidates :
    string list ->
    (Runtime.t list, Agent_core.Error.t) result

  val resolve_runtime_candidate_for_attempt :
    ?on_missing:(unit -> unit) ->
    string ->
    (Runtime.t, Agent_core.Error.t) result

  val selected_runtime_result :
    Runtime.t ->
    lane_attempt_index:int ->
    (Runtime_agent.run_result, Agent_core.Error.t) result ->
    (named_run_result, Agent_core.Error.t) result

  val media_degrade_manifest_decision :
    runtime_id:string -> (string * int) list -> Yojson.Safe.t

  val attempt_inference_policy :
    runtime_id:string ->
    fallback_enable_thinking:bool option ->
    unit ->
    attempt_inference_policy

  val attempt_runtime_candidates :
    ?pre_tool_rejects:Keeper_official_client_host.rejected_tool_call list ref ->
    ?allow_retry:
      (runtime_id:string -> attempt:int -> Agent_core.Error.t -> bool) ->
    ?allow_accept_no_progress_retry:
      (runtime_id:string -> attempt:int -> Agent_core.Error.t -> bool) ->
    ?lane_id:string ->
    ?on_retry_deferred:(deferred_runtime_lane -> unit) ->
    ?on_attempt_error:
      (runtime_id:string -> attempt:int -> Agent_core.Error.t -> unit) ->
    ?quota_scope_of:('candidate -> Runtime_quota_window.scope option) ->
    ?candidate_dispatchable:('candidate -> bool) ->
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
      ('result, Agent_core.Error.t) result
      * Agent_core.Checkpoint.t option
      * Keeper_provider_attempt_effect.t) ->
    'candidate list ->
    ('result, Agent_core.Error.t) result

  val observe_checkpoint_stage :
    bool Atomic.t -> Agent_core.Agent.checkpoint_stage -> unit

  val same_run_retry_allowed : bool Atomic.t -> bool

  val accept_no_progress_should_try_next : Agent_core.Error.t -> bool

end
