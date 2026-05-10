(** Keeper_turn_driver_wrappers — convenience wrappers around
    {!Keeper_turn_driver.run_named}.

    Extracted from keeper_turn_driver.ml as RFC-0048 PR-2 to reduce the
    1347-LOC hotspot.

    @since RFC-0048 PR-2 *)


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
  ?contract:Masc_mcp_cdal_runtime.Risk_contract.t ->
  ?on_event:(Agent_sdk.Types.sse_event -> unit) ->
  ?transport:Masc_grpc_transport.t ->
  ?sw:Eio.Switch.t ->
  ?net:Eio_context.eio_net ->
  unit ->
  (Cascade_runner.run_result, Agent_sdk.Error.sdk_error) result
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
  ?proof_ref:Masc_mcp_cdal_runtime.Cdal_proof.t option ref ->
  ?contract:Masc_mcp_cdal_runtime.Risk_contract.t ->
  ?transport:Masc_grpc_transport.t ->
  ?yield_on_tool:bool ->
  ?compact_ratio:float ->
  ?approval:Agent_sdk.Hooks.approval_callback ->
  ?sw:Eio.Switch.t ->
  ?net:Eio_context.eio_net ->
  unit ->
  (Cascade_runner.run_result, Agent_sdk.Error.sdk_error) result
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
  ?contract:Masc_mcp_cdal_runtime.Risk_contract.t ->
  ?raw_trace:Agent_sdk.Raw_trace.t ->
  ?on_event:(Agent_sdk.Types.sse_event -> unit) ->
  ?transport:Masc_grpc_transport.t ->
  ?sw:Eio.Switch.t ->
  ?net:Eio_context.eio_net ->
  unit ->
  (Cascade_runner.run_result, Agent_sdk.Error.sdk_error) result
(** [run_model_by_label] variant that bridges MASC tool schemas into OAS tools. *)
