(** Keeper projection for the official Codex app-server turn runtime. *)

type successful_tool_completion =
  | No_successful_tool_completion
  | Successful_tool_completion

type attempt_outcome =
  { result : (Runtime_agent.run_result, Agent_core.Error.t) result
  ; effect_disposition : Keeper_provider_attempt_effect.t
  ; successful_tool_completion : successful_tool_completion
  }
(** One Codex candidate result plus two distinct typed tool facts observed
    while producing it. The outer runtime-lane owner consumes
    [effect_disposition] as retry authority; [successful_tool_completion]
    only proves that a handler returned a successful result and can therefore
    support accepting a tool-only terminal. *)

val run :
  runtime_id:string ->
  keeper_name:string ->
  pre_tool_rejects:Keeper_official_client_host.rejected_tool_call list ref ->
  base_path:string ->
  goal:string ->
  goal_blocks:Agent_core.Types.content_block list option ->
  system_prompt:string ->
  tools:Agent_core.Tool.t list ->
  initial_messages:Agent_core.Types.message list ->
  model_input_projection:Agent_core.Agent.model_input_projection option ->
  hooks:Agent_core.Hooks.hooks option ->
  context_injector:Agent_core.Hooks.context_injector option ->
  context:Agent_core.Context.t option ->
  ?terminal_effect_state:(unit -> Keeper_tools_agent_core.terminal_effect_state) ->
  event_bus:Agent_core.Event_bus.t option ->
  raw_trace:Agent_core.Raw_trace.t option ->
  on_event:(Agent_core.Types.sse_event -> unit) option ->
  config:Runtime_execution.codex_app_server ->
  unit ->
  attempt_outcome

module For_testing : sig
  (** Typed carriage of Codex app-server client errors into agent-core
      errors; rotation class per constructor is pinned by
      [test_keeper_codex_error_carriage]. RFC-0370 §3.1. *)
  val codex_error_to_core_error :
    Runtime_codex_app_server.error -> Agent_core.Error.t

  (** Snap a requested reasoning effort into the catalog's accepted set for
      [model_id]: the requested effort when it is accepted, otherwise the
      nearest accepted effort. Pure; pinned by
      [test_keeper_codex_effort_clamp]. *)
  val clamp_reasoning_effort_to_catalog :
       model_id:string option
    -> requested:Llm_provider.Reasoning_effort.t option
    -> Llm_provider.Reasoning_effort.t option

  (** Typed map from a Codex app-server client error to the durable recovery
      failure. A typed context overflow becomes [Input_rejected] so the
      session admission fence holds instead of auto-replaying. *)
  val recovery_failure_of_client_error :
    Runtime_codex_app_server.error -> Keeper_official_client_session_store.recovery_failure
end
