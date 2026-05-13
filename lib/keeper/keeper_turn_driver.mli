(** Keeper_turn_driver — MASC named-cascade and model-label execution entry points.

    Public API for running OAS agents through MASC-managed named cascade
    profiles ([run_named]) or explicit model label ([run_model_by_label]),
    with optional MASC tool bridging variants.

    The facade intentionally exposes only the logical keeper entry points and
    typed MASC/OAS error helpers. Provider/model-shaped OAS runner helpers stay
    behind lower-level boundary modules.

    @since God file decomposition — extracted from oas_worker.ml *)

(** {1 MASC/OAS structured errors} *)

type cascade_name = Keeper_cascade_profile.runtime_name

val cascade_name_of_string : string -> cascade_name
val cascade_name_to_string : cascade_name -> string

type provider_rejection = {
  reason : string;
}

type masc_internal_error =
  | Cascade_exhausted of {
      cascade_name : cascade_name;
      reason : Keeper_types.cascade_exhaustion_reason;
    }
  | Resumable_cli_session of {
      cascade_name : cascade_name;
      detail : string;
      exit_code : int option;
    }
  | No_tool_capable_provider of {
      cascade_name : cascade_name;
      configured_labels : string list;
      required_tool_names : string list;
      provider_rejections : provider_rejection list;
    }
  | Accept_rejected of {
      scope : string;
      model : string option;
      reason : string;
    }
  | Admission_queue_timeout of {
      keeper_name : string;
      cascade_name : cascade_name;
      wait_sec : float;
    }
  | Admission_queue_rejected of {
      keeper_name : string;
      reason : string;
    }
  | Turn_timeout of { elapsed_sec : float }
  | Oas_timeout_budget of {
      budget_sec : float;
      keeper_turn_timeout_sec : float;
      estimated_input_tokens : int;
      source : string;
      remaining_turn_budget_sec : float option;
      min_required_sec : float;
      phase : string;
    }
  | Ambiguous_post_commit of {
      is_timeout : bool;
      tools : string list;
      original_error : string;
    }

val masc_internal_error_to_json : masc_internal_error -> Yojson.Safe.t

val summary_of_masc_internal_error : masc_internal_error -> string option

val sdk_error_of_masc_internal_error :
  masc_internal_error -> Agent_sdk.Error.sdk_error

val classify_masc_internal_error :
  Agent_sdk.Error.sdk_error -> masc_internal_error option

val classify_masc_internal_error_of_string :
  string -> masc_internal_error option

val kind_of_masc_internal_error : masc_internal_error -> string

val cascade_name_of_masc_internal_error : masc_internal_error -> string

val masc_oas_error_total_metric : string

val admission_wait_timeout_error :
  keeper_name:string ->
  cascade_name:cascade_name ->
  priority:Llm_provider.Request_priority.t ->
  int ->
  (string, Agent_sdk.Error.sdk_error) result

val cross_cascade_fallback_metric : string

(** {1 Cascade error helpers} *)

val sdk_error_to_cascade_outcome :
  Agent_sdk.Error.sdk_error -> Cascade_fsm.provider_outcome option

val message_looks_like_cli_wrapped_hard_quota : string -> bool

val message_looks_like_cli_wrapped_max_turns : string -> bool

val message_looks_like_resumable_cli_session : string -> bool

val sdk_error_to_resumable_cli_session :
  cascade_name:Cascade_error_classify.cascade_name ->
  Agent_sdk.Error.sdk_error ->
  Agent_sdk.Error.sdk_error option

val sdk_error_is_resumable_cli_session : Agent_sdk.Error.sdk_error -> bool

val sdk_error_is_terminal_provider_runtime_failure :
  Agent_sdk.Error.sdk_error -> bool

val sdk_error_is_model_access_denied : Agent_sdk.Error.sdk_error -> bool

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

(** {1 Named cascade execution} *)

val run_named :
  cascade_name:string ->
  ?keeper_name:string ->
  ?model_strings:string list ->
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
end
