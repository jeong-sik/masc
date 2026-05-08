(** Oas_worker_exec — config, build, and run entry points
    for OAS agent execution.

    Thin facade over {!Oas_worker_exec_agent},
    {!Cascade_transport}, and
    {!Oas_worker_exec_checkpoint}.  External callers reach
    the entry points via [Oas_worker_exec.X]; the heavy
    transport machinery (CLI / MCP wire formats, runtime
    policy projections) is implemented in
    {!Cascade_transport} and re-exposed here for
    backward compatibility — that sub-module has no .mli
    of its own, so the canonical contract is the one
    pinned at this boundary.

    All model-selection and cascade logic lives in
    {!Oas_worker_cascade} and {!Oas_worker_named}.

    Internal helpers stay private at this boundary
    ([lowercase_enum_case_name],
    [invalid_runtime_config],
    [cli_model_override],
    [provider_supports_inline_tools],
    [provider_supports_runtime_mcp_lane],
    [dedupe_preserve_order],
    [public_mcp_tool_names_of_oas_tools],
    [public_mcp_tool_requires_bound_actor],
    [public_mcp_tools_of_oas_tools],
    [tool_names_are_public_mcp],
    [non_http_transport_of_provider],
    [persist_checkpoint], [build_checkpoint],
    [partial_response_of_stop]). *)

(** {1 Stop reason} *)

type stop_reason = Oas_worker_exec_agent.stop_reason =
  | Completed
  | TurnBudgetExhausted of { turns_used : int; limit : int }
  | MutationBoundaryReached of {
      turns_used : int;
      tool_name : string option;
    }
(** Why the run terminated.  [Completed] is the success
    path; [TurnBudgetExhausted] fires when the per-call
    [max_turns] is hit; [MutationBoundaryReached] fires
    when the keeper hit a mutation tool while in
    read-only mode (the [tool_name] surfaces which tool
    triggered the gate). *)

(** {1 CLI transport overrides} *)

type cli_transport_overrides =
  Cascade_transport.cli_transport_overrides = {
  cwd : string option;
  claude_mcp_config : string option;
  claude_allowed_tools : string list option;
  claude_permission_mode : string option;
  claude_max_turns : int option;
  gemini_yolo : bool option;
  cli_subprocess_idle_sec : float option;
}
(** Per-call overrides threaded into the local CLI transports
    (Claude Code, Gemini CLI, Kimi CLI).
    [cli_subprocess_idle_sec] is currently honoured only by Kimi CLI;
    see {!Cascade_transport.cli_transport_overrides}. *)

(** {1 Config} *)

type config = Oas_worker_exec_agent.config = {
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
  memory : Agent_sdk.Memory.t option;
  initial_messages : Agent_sdk.Types.message list;
  raw_trace : Agent_sdk.Raw_trace.t option;
  tool_retry_policy : Agent_sdk.Tool_retry_policy.t option;
  required_tool_satisfaction :
    Agent_sdk.Completion_contract.required_tool_satisfaction;
  contract : Masc_mcp_cdal_runtime.Risk_contract.t option;
  enable_thinking : bool option;
  transport : Masc_grpc_transport.t;
  allowed_paths : string list;
  checkpoint_sidecar : Yojson.Safe.t option;
  cache_system_prompt : bool;
  yield_on_tool : bool;
  compact_ratio : float option;
  context_injector : Agent_sdk.Hooks.context_injector option;
  context : Agent_sdk.Context.t option;
  slot_id : int option;
  approval : Agent_sdk.Hooks.approval_callback option;
  exit_condition : (int -> bool) option;
  exit_condition_result : (int -> stop_reason * string option) option;
  summarizer : (Agent_sdk.Types.message list -> string) option;
  cli_transport_overrides : cli_transport_overrides option;
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
  proof : Masc_mcp_cdal_runtime.Cdal_proof.t option;
  cascade_observation : Oas_worker_cascade.cascade_observation option;
  stop_reason : stop_reason;
}

val proof_result_status_to_string :
  Masc_mcp_cdal_runtime.Cdal_proof.result_status -> string

(** {1 Label resolution} *)

val label_resolution_error_to_string :
  Cascade_transport.label_resolution_error -> string
val label_resolution_error_to_sdk_error :
  Cascade_transport.label_resolution_error ->
  Agent_sdk.Error.sdk_error

val resolve_provider_config_of_label :
  string -> (Llm_provider.Provider_config.t,
             Cascade_transport.label_resolution_error) result

(** {1 Provider helpers} *)

val provider_caps_of_config :
  Llm_provider.Provider_config.t ->
  Llm_provider.Capabilities.capabilities
val provider_label : Llm_provider.Provider_config.t -> string
val claude_code_max_turns_hard_cap : int
val provider_effective_max_turns :
  Llm_provider.Provider_config.provider_kind -> int -> int

(** {1 Kimi CLI configuration} *)

val kimi_mcp_config_json_of_policy :
  Llm_provider.Llm_transport.runtime_mcp_policy ->
  string option
val kimi_cli_model_for_provider :
  Llm_provider.Provider_config.t -> string option
val kimi_cli_config_json_for_provider :
  Llm_provider.Provider_config.t -> string option
val kimi_cli_runtime_mcp_jsons :
  base:string list ->
  Llm_provider.Llm_transport.runtime_mcp_policy option ->
  string list

module Kimi_cli_transport_local :
  module type of Cascade_transport.Kimi_cli_transport_local

(** {1 Runtime-MCP policy} *)

val runtime_mcp_tool_requires_bound_actor : string -> bool
val runtime_mcp_policy_with_masc_agent_name :
  ?include_internal_token:bool ->
  agent_name:string ->
  Llm_provider.Llm_transport.runtime_mcp_policy ->
  Llm_provider.Llm_transport.runtime_mcp_policy
val codex_cli_can_auth_keeper_bound_runtime_mcp :
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
  ?allow_keeper_internal:bool ->
  string list ->
  Llm_provider.Llm_transport.runtime_mcp_policy option
val resolve_tool_lane_for_oas_tools :
  ?agent_name:string ->
  ?tool_requirement:[ `Required | `Optional ] ->
  provider_cfg:Llm_provider.Provider_config.t ->
  tools:Agent_sdk.Tool.t list ->
  unit ->
  ( Agent_sdk.Tool.t list
    * Llm_provider.Llm_transport.runtime_mcp_policy option,
    Agent_sdk.Error.sdk_error )
  result

(** {1 Per-call switch transport} *)

val make_per_call_switch_transport :
  (sw:Eio.Switch.t -> Llm_provider.Llm_transport.t) ->
  Llm_provider.Llm_transport.t

(** {1 Lifecycle / checkpoint helpers (re-exported)} *)

val publish_lifecycle :
  Agent_sdk.Event_bus.t ->
  name:string ->
  event:string ->
  detail:string ->
  ?error:string ->
  ?session_id:string ->
  ?status:string ->
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
    fresh run.  Resolves the per-call non-HTTP transport
    via {!non_http_transport_of_provider}; threads
    [config.approval] into the OAS builder when present. *)

val resume_from_checkpoint :
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  config:config ->
  checkpoint:Agent_sdk.Checkpoint.t ->
  (Agent_sdk.Agent.t, Agent_sdk.Error.sdk_error) result
(** Resumes from a persisted checkpoint.  Uses
    [Oas_worker_exec_agent.prepare_resume] to reconcile
    [checkpoint.turn_count] with the current
    [config.max_turns]. *)

val run :
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  config:config ->
  ?oas_checkpoint:Agent_sdk.Checkpoint.t ->
  ?on_event:(Agent_sdk.Types.sse_event -> unit) ->
  ?on_yield:(unit -> unit) ->
  ?on_resume:(unit -> unit) ->
  ?agent_ref:Agent_sdk.Agent.t option ref ->
  ?proof_ref:Masc_mcp_cdal_runtime.Cdal_proof.t option ref ->
  ?contract:Masc_mcp_cdal_runtime.Risk_contract.t ->
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
  dispatch:(name:string -> args:Yojson.Safe.t -> Tool_result.t) ->
  ?contract:Masc_mcp_cdal_runtime.Risk_contract.t ->
  ?on_event:(Agent_sdk.Types.sse_event -> unit) ->
  ?on_yield:(unit -> unit) ->
  ?on_resume:(unit -> unit) ->
  string ->
  (run_result, Agent_sdk.Error.sdk_error) result
(** Variant of {!run} that wires MASC public-MCP tools
    into the agent through [dispatch].  Used by the
    keeper-runtime path that needs to expose MCP-style
    tools to the model alongside OAS tools. *)
