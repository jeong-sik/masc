(** Runtime_agent — config, build, and run entry points
    for OAS agent execution.

    Thin facade over {!Runtime_agent_context},
    {!Runtime_transport}, and
    {!Runtime_oas_checkpoint}.  External callers reach
    the run/config entry points via [Runtime_agent.X];
    provider transport internals (CLI / MCP wire formats,
    runtime policy projections, and transport-local
    diagnostics) are owned by {!Runtime_transport}.

    All model-selection and runtime logic lives in
    {!Runtime_observation} and {!Keeper_turn_driver}.

    Internal helpers stay private at this boundary
    ([invalid_runtime_config],
    [provider_supports_inline_tools],
    [provider_supports_runtime_mcp_lane],
    [dedupe_preserve_order],
    [public_mcp_tool_names_of_oas_tools],
    [public_mcp_tool_requires_bound_actor],
    [public_mcp_tools_of_oas_tools],
    [tool_names_are_public_mcp],
    [persist_checkpoint], [build_checkpoint],
    [partial_response_of_stop]). *)

(** {1 Stop reason} *)

type stop_reason = Runtime_agent_context.stop_reason =
  | Completed
  | TurnBudgetExhausted of { turns_used : int; limit : int }
  | MutationBoundaryReached of {
      turns_used : int;
      tool_name : string option;
    }
(** Why this single OAS call yielded control. [Completed] is the
    model's success path; [TurnBudgetExhausted] means the per-call
    turn budget checkpoint was reached and the keeper should continue
    from the persisted checkpoint on the next cycle; [MutationBoundaryReached]
    fires when the keeper hit a mutation tool while in read-only mode
    (the [tool_name] surfaces which tool triggered the gate). *)

(** {1 Config} *)

type config = Runtime_agent_context.config = {
  name : string;
  provider_cfg : Llm_provider.Provider_config.t;
  provider : Agent_sdk.Provider.config;
  model_id : string;
  priority : Llm_provider.Request_priority.t option;
  system_prompt : string;
  tools : Agent_sdk.Tool.t list;
  runtime_mcp_policy :
    Llm_provider.Llm_transport.runtime_mcp_policy option;
  max_turns : int;
  max_idle_turns : int;
  stream_idle_timeout_s : float option;
  max_execution_time_s : float option;
  body_timeout_s : float option;
  max_tokens : int;
  max_input_tokens : int option;
  max_cost_usd : float option;
  temperature : float;
  hooks : Agent_sdk.Hooks.hooks option;
  context_reducer : Agent_sdk.Context_reducer.t option;
  guardrails : Agent_sdk.Guardrails.t option;
  event_bus : Agent_sdk.Event_bus.t option;
  checkpoint_dir : string option;
  session_id : string option;
  description : string option;
  initial_messages : Agent_sdk.Types.message list;
  raw_trace : Agent_sdk.Raw_trace.t option;
  trace_link : (string * string) option;
  enable_thinking : bool option;
  preserve_thinking : bool option;
  transport : Masc_grpc_transport.t;
  allowed_paths : string list;
  checkpoint_sidecar : Yojson.Safe.t option;
  cache_system_prompt : bool;
  yield_on_tool : bool;
  compact_ratio : float option;
  oas_auto_context_overflow_retry : bool;
  context_injector : Agent_sdk.Hooks.context_injector option;
  context : Agent_sdk.Context.t option;
  approval : Agent_sdk.Hooks.approval_callback option;
  exit_condition : (int -> bool) option;
  exit_condition_result : (int -> stop_reason * string option) option;
  summarizer : (Agent_sdk.Types.message list -> string) option;
  execution_idle_timeout_s : float option;
  thinking_budget : int option;
  min_p : float option;
  on_run_complete : (bool -> unit) option;
  disclosure_level : Agent_sdk.Tool.disclosure_level option;
  disclosure_resolver
      : (Agent_sdk.Types.tool_result list -> Agent_sdk.Tool.disclosure_level option) option;
  tool_selector : Agent_sdk.Tool_selector.strategy option;
  checkpoint_sink : Agent_sdk.Agent.checkpoint_sink option;
}

val default_config :
  name:string ->
  provider_cfg:Llm_provider.Provider_config.t ->
  system_prompt:string ->
  tools:Agent_sdk.Tool.t list ->
  config
(** Builds a {!config} populated with sensible defaults
    for every field except the four required ones.
    Caller mutates fields in place via record copy
    ([\{ cfg with ... \}]) before passing to {!build} or
    {!resume_from_checkpoint}. *)

(** {1 Run result} *)

type run_result = {
  response : Agent_sdk.Types.api_response;
  checkpoint : Agent_sdk.Checkpoint.t option;
  session_id : string;
  turns : int;
  trace_ref : Agent_sdk.Raw_trace.run_ref option;
  run_validation : Agent_sdk.Raw_trace.run_validation option;
  runtime_observation : Runtime_observation.runtime_observation option;
  stop_reason : stop_reason;
}

type worker_lifecycle_classification =
  { event : string
  ; status : string
  ; error : string option
  }

val worker_lifecycle_classification_of_result :
  (run_result, Agent_sdk.Error.sdk_error) result -> worker_lifecycle_classification


(** {1 Label resolution} *)

val label_resolution_error_to_string :
  Runtime_transport.label_resolution_error -> string
val label_resolution_error_to_sdk_error :
  Runtime_transport.label_resolution_error ->
  Agent_sdk.Error.sdk_error

val resolve_provider_config_of_label :
  string -> (Llm_provider.Provider_config.t,
             Runtime_transport.label_resolution_error) result

(** {1 Provider helpers} *)

val provider_caps_of_config :
  Llm_provider.Provider_config.t ->
  Llm_provider.Capabilities.capabilities
val provider_label : Llm_provider.Provider_config.t -> string
(** {1 Runtime-MCP policy} *)

val runtime_mcp_tool_requires_bound_actor : string -> bool
val runtime_mcp_policy_with_masc_agent_name :
  ?include_internal_token:bool ->
  agent_name:string ->
  Llm_provider.Llm_transport.runtime_mcp_policy ->
  Llm_provider.Llm_transport.runtime_mcp_policy
val cli_tool_a_can_auth_keeper_bound_runtime_mcp :
  agent_name:string ->
  Llm_provider.Llm_transport.runtime_mcp_policy ->
  bool
val runtime_mcp_policy_for_provider :
  provider_cfg:Llm_provider.Provider_config.t ->
  agent_name:string ->
  Llm_provider.Llm_transport.runtime_mcp_policy option ->
  Llm_provider.Llm_transport.runtime_mcp_policy option
val public_mcp_runtime_policy_of_tool_names :
  ?agent_name:string ->
  string list ->
  Llm_provider.Llm_transport.runtime_mcp_policy option
val runtime_mcp_policy_of_tool_names :
  ?agent_name:string ->
  ?allow_agent_internal:bool ->
  string list ->
  Llm_provider.Llm_transport.runtime_mcp_policy option
val resolve_tool_lane_for_oas_tools :
  ?agent_name:string ->
  provider_cfg:Llm_provider.Provider_config.t ->
  tools:Agent_sdk.Tool.t list ->
  unit ->
  ( Agent_sdk.Tool.t list
    * Llm_provider.Llm_transport.runtime_mcp_policy option,
    Agent_sdk.Error.sdk_error )
  result

val runtime_observation_for_terminal_config :
  total_duration_ms:float ->
  ?error:string ->
  config ->
  Runtime_observation.runtime_observation

module For_testing : sig
  val request_runtime_fields_on_base_config :
    base:Llm_provider.Provider_config.t ->
    Llm_provider.Provider_config.t ->
    Llm_provider.Provider_config.t

  val provider_http_slot_transport :
    Llm_provider.Llm_transport.t -> Llm_provider.Llm_transport.t

  val runtime_id_of_config : config -> string

  (* RFC-OAS-026 §4.6 fail-fast (pure decision; raises [Failure] when an idle
     deadline is configured but no clock resolves). *)
  val decide_clock_for_idle :
    stream_idle_timeout_s:float option ->
    process_clock:(float Eio.Time.clock_ty Eio.Resource.t, string) result ->
    ctx_clock:float Eio.Time.clock_ty Eio.Resource.t option ->
    float Eio.Time.clock_ty Eio.Resource.t option

  val runtime_observation_for_completed_config :
    total_duration_ms:float -> config -> Runtime_observation.runtime_observation

  val runtime_observation_for_terminal_config :
    total_duration_ms:float ->
    ?error:string ->
    config ->
    Runtime_observation.runtime_observation
end

(** {1 Lifecycle / checkpoint helpers (re-exported)} *)

val publish_lifecycle :
  Agent_sdk.Event_bus.t ->
  name:string ->
  event:string ->
  detail:string ->
  ?error:string ->
  ?session_id:string ->
  ?status:string ->
  ?attrs:(string * Yojson.Safe.t) list ->
  unit ->
  unit
val enrich_idle_detail :
  string -> Agent_sdk.Types.message list -> string

(** {1 Build / resume / run} *)

val build :
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  config:config ->
  (Agent_sdk.Agent.t, Agent_sdk.Error.sdk_error) result
(** Builds an [Agent_sdk.Agent.t] from a {!config} ready for a
    fresh run over the HTTP provider transport; threads
    [config.approval] into the OAS builder when present. *)

val resume_from_checkpoint :
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  config:config ->
  checkpoint:Agent_sdk.Checkpoint.t ->
  (Agent_sdk.Agent.t, Agent_sdk.Error.sdk_error) result
(** Resumes from a persisted checkpoint.  Uses
    [Runtime_agent_context.prepare_resume] to reconcile
    [checkpoint.turn_count] with the current config. *)

val run :
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  config:config ->
  ?oas_checkpoint:Agent_sdk.Checkpoint.t ->
  ?on_event:(Agent_sdk.Types.sse_event -> unit) ->
  ?on_yield:(unit -> unit) ->
  ?on_resume:(unit -> unit) ->
  ?agent_ref:Agent_sdk.Agent.t option ref ->
  string ->
  (run_result, Agent_sdk.Error.sdk_error) result
(** Runs an OAS agent against [goal].  When
    [oas_checkpoint] is present, {!resume_from_checkpoint}
    is used; otherwise {!build} produces a fresh agent.
    Returns the wrapped {!run_result}; errors propagate
    as [Agent_sdk.Error.sdk_error]. *)

val run_with_masc_tools :
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  config:config ->
  masc_tools:Masc_domain.tool_schema list ->
  dispatch:(name:string -> args:Yojson.Safe.t -> Tool_result.result) ->
  ?on_event:(Agent_sdk.Types.sse_event -> unit) ->
  ?on_yield:(unit -> unit) ->
  ?on_resume:(unit -> unit) ->
  string ->
  (run_result, Agent_sdk.Error.sdk_error) result
(** Variant of {!run} that wires MASC public-MCP tools
    into the agent through [dispatch].  Used by the
    keeper-runtime path that needs to expose MCP-style
    tools to the model alongside OAS tools. *)

val set_oas_tool_of_masc_hook :
  (name:string ->
   description:string ->
   input_schema:Yojson.Safe.t ->
   (Yojson.Safe.t -> Tool_result.result) ->
   Agent_sdk.Tool.t) ->
  unit
(** [set_oas_tool_of_masc_hook f] registers a function to project MASC tool schemas
    into Agent_sdk.Tool.t. Used to decouple the [Tool_bridge] module. *)
