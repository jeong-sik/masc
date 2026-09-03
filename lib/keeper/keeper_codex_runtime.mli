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
  on_transmitted_model_input:(Agent_core.Types.message list -> unit) ->
  hooks:Agent_core.Hooks.hooks option ->
  context_injector:Agent_core.Hooks.context_injector option ->
  context:Agent_core.Context.t option ->
  ?terminal_effect_state:(unit -> Keeper_tools_agent_core.terminal_effect_state) ->
  ?on_model_input_window_observation:
    (Runtime_model_input_tail_window.window_observation -> unit) ->
  ?on_official_client_result_handoff:
    (invocation:Agent_core.Tool_contract.Invocation.t -> content:string -> unit) ->
  ?on_native_action:(official_turn:int ->
    identity:Runtime_native_tools.action_identity -> tool_name:string -> unit) ->
  event_bus:Agent_core.Event_bus.t option ->
  raw_trace:Agent_core.Raw_trace.t option ->
  on_event:(Agent_core.Types.sse_event -> unit) option ->
  config:Runtime_execution.codex_app_server ->
  unit ->
  attempt_outcome
(** [on_model_input_window_observation] receives how much of the offered
    history this turn carried. Without it the turn record is written with no
    window and no input composition, which is what [/context] reads.

    [on_transmitted_model_input] receives the history list this runtime hands
    to the client, once per projection call, after the capacity window has cut
    it. Required rather than optional: a lane that reports nothing is what
    wrote every turn's input attribution on this lane as zero (masc#32995).
    The list is what masc handed over, not what crossed the wire -- the client
    assembles the request, and on a resumed conversation it re-sends only the
    new turn. That is the same [Durable_shape] reading the window observation
    reports. *)

module For_testing : sig
  val observe_stream_native_action :
    turn_count:int ->
    observe:(official_turn:int -> identity:Runtime_native_tools.action_identity ->
      tool_name:string -> unit) ->
    Runtime_codex_app_server.stream_event -> unit
  (** What the developer instructions say about the built-in write path.

      Codex cannot be told to drop its built-in tools, so under
      [Native_read] the model carries a refused [apply_patch] beside a working
      [Write]. This names which one the session refused. Empty for every other
      posture, where nothing about the built-in surface is unusual. Pure;
      pinned by [test_keeper_codex_write_path_note]. *)
  val native_posture_note : Runtime_native_tools.posture -> string list

  (** Typed carriage of Codex app-server client errors into agent-core
      errors; rotation class per constructor is pinned by
      [test_keeper_codex_error_carriage]. RFC-0370 §3.1. *)
  val codex_error_to_core_error :
    Runtime_codex_app_server.error -> Agent_core.Error.t

  (** Typed map from a Codex app-server client error to the durable recovery
      failure. A typed context overflow becomes [Input_rejected] so the
      session admission fence holds instead of auto-replaying. *)
  val recovery_failure_of_client_error :
    Runtime_codex_app_server.error -> Keeper_official_client_session_store.recovery_failure
end
