(** Keeper_turn_driver_wrappers — convenience wrappers around
    {!Keeper_turn_driver.run_named}.

    Extracted from keeper_turn_driver.ml as RFC-0048 PR-2 to reduce the
    1347-LOC hotspot.

    @since RFC-0048 PR-2 *)


(** {1 Model-label execution} *)

(** {1 MASC tool bridging} *)

val run_named_with_masc_tools :
  runtime_id:string ->
  ?runtime_selection:Keeper_turn_driver.runtime_selection ->
  ?keeper_name:string ->
  goal:string ->
  ?goal_blocks:Agent_core.Types.content_block list ->
  base_path:string ->
  system_prompt:string ->
  ?native_tools:Agent_core.Tool.t list ->
  ?tool_requirement:Keeper_required_tools.t ->
  ?required_native_posture:Runtime_native_tools.posture ->
  ?tool_result_projection:Tool_output.model_projection ->
  ?on_selected_runtime:(string -> unit) ->
  masc_tools:Masc_domain.tool_schema list ->
  dispatch:(name:string -> args:Yojson.Safe.t -> Tool_result.result) ->
  ?stream_idle_timeout_s:float ->
  ?temperature:float ->
  ?accept:(Agent_core.Types.api_response -> bool) ->
  ?hooks:Agent_core.Hooks.hooks ->
  ?raw_trace:Agent_core.Raw_trace.t ->
  ?on_event:(Agent_core.Types.sse_event -> unit) ->
  ?on_yield:(unit -> unit) ->
  ?on_resume:(unit -> unit) ->
  ?on_runtime_attempt_error:
    (runtime_id:string ->
    attempt:int ->
    dispatch:Keeper_attempt_dispatch.t ->
    Agent_core.Error.t ->
    unit) ->
  ?transport:Masc_grpc_transport.t ->
  ?yield_on_tool:bool ->
  ?context:Agent_core.Context.t ->
  ?output_contract:Keeper_turn_driver.output_contract ->
  ?provider_config_transform:
    (Llm_provider.Provider_config.t ->
    (Llm_provider.Provider_config.t, Agent_core.Error.t) result) ->
  ?sw:Eio.Switch.t ->
  ?net:Eio_context.eio_net ->
  unit ->
  (Runtime_agent.run_result, Agent_core.Error.t) result
(** [run_named] variant that bridges MASC tool schemas into AGENT_CORE tools
    via {!Tool_bridge.agent_core_tool_of_masc}. [keeper_name] preserves per-Keeper
    lane ownership in runtime manifests and metrics; the default retains
    compatibility for non-Keeper callers. [on_runtime_attempt_error] forwards
    the typed per-candidate observation from {!Keeper_turn_driver.run_named}
    without changing its terminal result.

    [native_tools] adds native tools without losing invocation identity or
    handler observations.

    [tool_requirement] and [required_native_posture] preserve the caller's
    invocation authority through candidate admission. A required native posture
    is never replaced by the runtime's ordinary degraded posture.

    [tool_result_projection] preserves a bounded caller-owned inline policy.
    [on_selected_runtime] observes the actual winning runtime before the
    wrapper returns its run result, including when a declared lane was used.

    [goal_blocks] replaces the [goal] string as the turn input when present
    (same contract as {!Keeper_turn_driver.run_named}): the caller puts the
    prompt itself in a [Text] block first, then any media blocks. *)
