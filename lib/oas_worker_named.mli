(** Oas_worker_named — MASC named-cascade and model-label execution entry points.

    Public API for running OAS agents through MASC-managed named cascade
    profiles ([run_named]) or explicit model label ([run_model_by_label]),
    with optional MASC tool bridging variants.

    The facade [include]s the three sub-modules:
    - {!Oas_worker_named_cascade} — Eio context, cascade resolution, runtime MCP policy
    - {!Oas_worker_named_error} — masc_internal_error type, error conversion, codex CLI preflight
    - {!Oas_worker_named_fsm} — SDK error to FSM outcome, session/resumption analysis

    @since God file decomposition — extracted from oas_worker.ml *)

include module type of Oas_worker_named_cascade
include module type of Oas_worker_named_error
include module type of Oas_worker_named_fsm

(** [effective_provider_attempt_timeout_s] applies provider-specific
    timeout constraints to a configured cascade attempt budget.

    - Ollama has a 300s floor for local model cold-load.
    - Claude Code, Gemini, and Kimi CLI have shorter attempt caps so one
      provider cannot spend the whole keeper turn budget before fallback.
    - Providers without a known constraint keep the configured timeout unless
      they are the last attempt, where the enclosing keeper/OAS timeout is
      sufficient. *)
val effective_provider_attempt_timeout_s :
  is_last:bool ->
  configured_timeout_s:float option ->
  Llm_provider.Provider_config.t ->
  float option

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
  ?proof_ref:Agent_sdk.Cdal_proof.t option ref ->
  ?contract:Agent_sdk.Risk_contract.t ->
  ?transport:Masc_grpc_transport.t ->
  ?cli_transport_overrides:Oas_worker_exec.cli_transport_overrides ->
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
  ?exit_condition_result:(int -> Oas_worker_exec.stop_reason * string option) ->
  ?summarizer:(Agent_sdk.Types.message list -> string) ->
  ?oas_checkpoint:Agent_sdk.Checkpoint.t ->
  ?event_bus:Agent_sdk.Event_bus.t ->
  ?sw:Eio.Switch.t ->
  ?net:Eio_context.eio_net ->
  ?per_provider_timeout_s:float ->
  unit ->
  (Oas_worker_exec.run_result, Agent_sdk.Error.sdk_error) result
(** Run a single [Agent.run] call with MASC-driven cascade model fallback.
    MASC drives the cascade FSM directly: resolves cascade providers,
    tries each with OAS, and uses [Cascade_fsm.decide] on failure.
    The cascade loop runs inside an admission queue permit. *)

(** {1 Model-label execution} *)

val run_model_by_label :
  model_label:string ->
  goal:string ->
  ?system_prompt:string ->
  ?tools:Agent_sdk.Tool.t list ->
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
  ?enable_thinking:bool ->
  ?compact_ratio:float ->
  ?contract:Agent_sdk.Risk_contract.t ->
  ?on_event:(Agent_sdk.Types.sse_event -> unit) ->
  ?transport:Masc_grpc_transport.t ->
  ?sw:Eio.Switch.t ->
  ?net:Eio_context.eio_net ->
  unit ->
  (Oas_worker_exec.run_result, Agent_sdk.Error.sdk_error) result
(** Run a single [Agent.run] using a model label string
    (e.g. ["llama:qwen3.5"]).  Validates the label before execution. *)

(** {1 MASC tool bridging} *)

val run_named_with_masc_tools :
  cascade_name:string ->
  goal:string ->
  ?priority:Llm_provider.Request_priority.t ->
  ?system_prompt:string ->
  masc_tools:Masc_domain.tool_schema list ->
  dispatch:(name:string -> args:Yojson.Safe.t -> Tool_result.t) ->
  ?max_turns:int ->
  ?stream_idle_timeout_s:float ->
  ?temperature:float ->
  ?max_tokens:int ->
  ?max_input_tokens:int ->
  ?max_cost_usd:float ->
  ?wait_timeout_sec:float ->
  ?guardrails:Agent_sdk.Guardrails.t ->
  ?hooks:Agent_sdk.Hooks.hooks ->
  ?memory:Agent_sdk.Memory.t ->
  ?tool_retry_policy:Agent_sdk.Tool_retry_policy.t ->
  ?required_tool_satisfaction:Agent_sdk.Completion_contract.required_tool_satisfaction ->
  ?raw_trace:Agent_sdk.Raw_trace.t ->
  ?on_event:(Agent_sdk.Types.sse_event -> unit) ->
  ?on_yield:(unit -> unit) ->
  ?on_resume:(unit -> unit) ->
  ?proof_ref:Agent_sdk.Cdal_proof.t option ref ->
  ?contract:Agent_sdk.Risk_contract.t ->
  ?transport:Masc_grpc_transport.t ->
  ?yield_on_tool:bool ->
  ?compact_ratio:float ->
  ?approval:Agent_sdk.Hooks.approval_callback ->
  ?sw:Eio.Switch.t ->
  ?net:Eio_context.eio_net ->
  unit ->
  (Oas_worker_exec.run_result, Agent_sdk.Error.sdk_error) result
(** [run_named] variant that bridges MASC tool schemas into OAS tools
    via {!Tool_bridge.oas_tool_of_masc}. *)

val run_model_with_masc_tools :
  model_label:string ->
  goal:string ->
  ?system_prompt:string ->
  masc_tools:Masc_domain.tool_schema list ->
  dispatch:(name:string -> args:Yojson.Safe.t -> Tool_result.t) ->
  ?max_turns:int ->
  ?stream_idle_timeout_s:float ->
  ?temperature:float ->
  ?max_tokens:int ->
  ?max_input_tokens:int ->
  ?max_cost_usd:float ->
  ?wait_timeout_sec:float ->
  ?guardrails:Agent_sdk.Guardrails.t ->
  ?hooks:Agent_sdk.Hooks.hooks ->
  ?memory:Agent_sdk.Memory.t ->
  ?tool_retry_policy:Agent_sdk.Tool_retry_policy.t ->
  ?enable_thinking:bool ->
  ?compact_ratio:float ->
  ?contract:Agent_sdk.Risk_contract.t ->
  ?raw_trace:Agent_sdk.Raw_trace.t ->
  ?on_event:(Agent_sdk.Types.sse_event -> unit) ->
  ?transport:Masc_grpc_transport.t ->
  ?sw:Eio.Switch.t ->
  ?net:Eio_context.eio_net ->
  unit ->
  (Oas_worker_exec.run_result, Agent_sdk.Error.sdk_error) result
(** [run_model_by_label] variant that bridges MASC tool schemas into OAS tools. *)

module For_testing : sig
  val checkpoint_after_attempt :
    ?agent_ref:Agent_sdk.Agent.t option ref ->
    Agent_sdk.Agent.t option ->
    Agent_sdk.Checkpoint.t option
end
