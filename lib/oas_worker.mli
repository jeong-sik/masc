(** Oas_worker — Unified entry point for OAS-based MASC tool modules.

    Callers either pass a MASC-managed [cascade_name] string for configured fallback
    selection or a [model_label] string for {!run_model_by_label}.
    All public APIs accept string model labels; no [Model_spec.model_spec]
    type is exposed.

    Transport selection: all [run_*] functions accept an optional
    [~transport] parameter. When omitted, the transport is resolved
    from [MASC_AGENT_TRANSPORT] env var (default: [Local]).

    @since Phase 1 — MASC->OAS migration
    @since Phase 4 — public API restricted to named cascade functions
    @since Phase 5 — run_model_by_label added (string-based API)
    @since Phase 6 — Model_spec.model_spec type fully eliminated from API
    @since Phase 8 — legacy cascade wrapper deleted, MASC-owned defaults moved here
    @since Phase 9 — gRPC transport option added (#2381) *)

type cascade_attempt = {
  attempt_index : int;
  model_id : string;
  model_label : string option;
  latency_ms : int option;
  error : string option;
}

type cascade_fallback_event = {
  from_model_id : string;
  from_model_label : string option;
  to_model_id : string;
  to_model_label : string option;
  reason : string;
}

type cascade_observation = {
  cascade_name : Keeper_cascade_profile.runtime_name;
  strategy : string option;
  configured_labels : string list;
  candidate_models : string list;
  primary_model : string option;
  selected_model : string option;
  selected_model_raw : string option;
  selected_index : int option;
  fallback_hops : int option;
  fallback_applied : bool;
  attempts : cascade_attempt list;
  fallback_events : cascade_fallback_event list;
  attempt_details_available : bool;
  attempt_details_source : string;
}

type stop_reason =
  | Completed
  | TurnBudgetExhausted of { turns_used : int; limit : int }
  | MutationBoundaryReached of { turns_used : int; tool_name : string option }

type cli_transport_overrides = Oas_worker_exec.cli_transport_overrides = {
  cwd : string option;
  claude_mcp_config : string option;
  claude_allowed_tools : string list option;
  claude_permission_mode : string option;
  claude_max_turns : int option;
  gemini_yolo : bool option;
  cli_subprocess_idle_sec : float option;
}

type run_result = {
  response : Agent_sdk.Types.api_response;
  checkpoint : Agent_sdk.Checkpoint.t option;
  session_id : string;
  turns : int;
  trace_ref : Agent_sdk.Raw_trace.run_ref option;
  run_validation : Agent_sdk.Raw_trace.run_validation option;
  proof : Agent_sdk.Cdal_proof.t option;
  cascade_observation : cascade_observation option;
  stop_reason : stop_reason;
}

(** Cascade call/error metrics as JSON array, sorted by call count. *)
val cascade_metrics_json : unit -> Yojson.Safe.t
val cascade_observation_to_json : cascade_observation -> Yojson.Safe.t

(** Locate config/cascade.json via the resolved config root.
    Delegates to {!Cascade_runtime.cascade_config_path}. *)
val default_config_path : unit -> string option

(** Return the default model string list for a given cascade name. *)
val default_model_strings : cascade_name:string -> string list

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
  ?required_tool_satisfaction:
    Agent_sdk.Completion_contract.required_tool_satisfaction ->
  ?raw_trace:Agent_sdk.Raw_trace.t ->
  ?on_event:(Agent_sdk.Types.sse_event -> unit) ->
  ?on_yield:(unit -> unit) ->
  ?on_resume:(unit -> unit) ->
  ?agent_ref:Agent_sdk.Agent.t option ref ->
  ?proof_ref:Agent_sdk.Cdal_proof.t option ref ->
  ?contract:Agent_sdk.Risk_contract.t ->
  ?transport:Masc_grpc_transport.t ->
  ?cli_transport_overrides:cli_transport_overrides ->
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
  ?exit_condition_result:(int -> stop_reason * string option) ->
  ?summarizer:(Agent_sdk.Types.message list -> string) ->
  ?oas_checkpoint:Agent_sdk.Checkpoint.t ->
  ?event_bus:Agent_sdk.Event_bus.t ->
  ?sw:Eio.Switch.t ->
  ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?per_provider_timeout_s:float ->
  unit ->
  (run_result, Agent_sdk.Error.sdk_error) result

(** Run a single Agent.run() using a model label string (e.g. "llama:qwen3.5").
    Validates the label parses before attempting execution. *)
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
  ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  unit ->
  (run_result, Agent_sdk.Error.sdk_error) result

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
  ?required_tool_satisfaction:
    Agent_sdk.Completion_contract.required_tool_satisfaction ->
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
  ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  unit ->
  (run_result, Agent_sdk.Error.sdk_error) result

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
  ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  unit ->
  (run_result, Agent_sdk.Error.sdk_error) result
