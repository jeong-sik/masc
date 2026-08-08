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
  ?tools:Masc_agent_core.Tool.t list ->
  ?stream_idle_timeout_s:float ->
  ?temperature:float ->
  ?max_tokens:int ->
  ?accept:(Masc_agent_core_response.api_response -> bool) ->
  ?hooks:Masc_agent_core.Hooks.hooks ->
  ?enable_thinking:bool ->
  ?provider_config_transform:
    (Llm_provider.Provider_config.t ->
    (Llm_provider.Provider_config.t, Masc_agent_core.Error.sdk_error) result) ->
  ?on_event:(Masc_agent_core.Types.sse_event -> unit) ->
  ?transport:Masc_grpc_transport.t ->
  ?sw:Eio.Switch.t ->
  ?net:Eio_context.eio_net ->
  unit ->
  (Runtime_agent.run_result, Masc_agent_core.Error.sdk_error) result
(** Run a single [Agent.run] using a model label string
    (e.g. ["llama:qwen3.5"]).  Validates the label before execution. *)

(** {1 MASC tool bridging} *)

val run_named_with_masc_tools :
  runtime_id:string ->
  ?keeper_name:string ->
  goal:string ->
  base_path:string ->
  ?system_prompt:string ->
  masc_tools:Masc_domain.tool_schema list ->
  dispatch:(name:string -> args:Yojson.Safe.t -> Tool_result.result) ->
  ?stream_idle_timeout_s:float ->
  ?temperature:float ->
  ?accept:(Masc_agent_core_response.api_response -> bool) ->
  ?hooks:Masc_agent_core.Hooks.hooks ->
  ?raw_trace:Masc_agent_core.Raw_trace.t ->
  ?on_event:(Masc_agent_core.Types.sse_event -> unit) ->
  ?on_yield:(unit -> unit) ->
  ?on_resume:(unit -> unit) ->
  ?transport:Masc_grpc_transport.t ->
  ?yield_on_tool:bool ->
  ?provider_config_transform:
    (Llm_provider.Provider_config.t ->
    (Llm_provider.Provider_config.t, Masc_agent_core.Error.sdk_error) result) ->
  ?sw:Eio.Switch.t ->
  ?net:Eio_context.eio_net ->
  unit ->
  (Runtime_agent.run_result, Masc_agent_core.Error.sdk_error) result
(** [run_named] variant that bridges MASC tool schemas into OAS tools
    via {!Tool_bridge.oas_tool_of_masc}. [keeper_name] preserves per-Keeper
    lane ownership in runtime manifests and metrics; the default retains
    compatibility for non-Keeper callers. *)

val run_model_with_masc_tools :
  model_label:string ->
  goal:string ->
  ?system_prompt:string ->
  masc_tools:Masc_domain.tool_schema list ->
  dispatch:(name:string -> args:Yojson.Safe.t -> Tool_result.result) ->
  ?stream_idle_timeout_s:float ->
  ?temperature:float ->
  ?max_tokens:int ->
  ?hooks:Masc_agent_core.Hooks.hooks ->
  ?enable_thinking:bool ->
  ?provider_config_transform:
    (Llm_provider.Provider_config.t ->
    (Llm_provider.Provider_config.t, Masc_agent_core.Error.sdk_error) result) ->
  ?raw_trace:Masc_agent_core.Raw_trace.t ->
  ?on_event:(Masc_agent_core.Types.sse_event -> unit) ->
  ?transport:Masc_grpc_transport.t ->
  ?sw:Eio.Switch.t ->
  ?net:Eio_context.eio_net ->
  unit ->
  (Runtime_agent.run_result, Masc_agent_core.Error.sdk_error) result
(** [run_model_by_label] variant that bridges MASC tool schemas into OAS tools. *)
