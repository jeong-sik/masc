(** Unified Keeper projection for persistent ACP v1 official runtimes:
    Antigravity ([agy acp]), Kimi Code ([kimi acp]), and Mistral Vibe
    ([vibe-acp]).

    Each Keeper owns an isolated persistent child process and loopback HTTP MCP
    bridge under its own [Eio.Switch.t], amortizing CLI cold start while
    preventing cross-Keeper crash or stall blast radius. *)

val evict_keeper : keeper_name:string -> unit
(** Stop and remove any persistent ACP child processes owned by [keeper_name].
    Safe to call when no child is running. *)

val run :
  ?on_guidance_prepared:(unit -> (unit, Agent_core.Error.t) result) ->
  input_source:Keeper_request_source.t ->
  media_store:Agent_core.History.media_store ->
  ?argument_source:Keeper_official_client_host.argument_source ->
  ?official_task_reference:Keeper_official_task_reference.t ->
  ?composed_context:(unit -> Keeper_official_client_host.composed_context option) ->
  accepts_image_input:bool ->
  ?required_native_posture:Runtime_native_tools.posture ->
  ?official_client_continuation:Keeper_semantic_execution.official_client_checkpoint ->
  runtime_id:string ->
  host:Runtime_account_access.host_account ->
  configured_reasoning_effort:Llm_provider.Reasoning_effort.t option ->
  turn_timeout_s:float option ->
  keeper_name:string ->
  pre_tool_rejects:Keeper_official_client_host.rejected_tool_call list ref ->
  base_path:string ->
  outbox_viewer:Keeper_client_tool_outbox.viewer ->
  read_retained_media:Keeper_client_tool_outbox.media_reader option ->
  goal:string ->
  goal_blocks:Agent_core.Types.content_block list option ->
  system_prompt:string ->
  tools:Agent_core.Tool.t list ->
  ?loading_plan:Keeper_official_client_host.loading_plan ->
  initial_messages:Agent_core.Types.message list ->
  model_input_projection:Keeper_history_projection.t option ->
  on_transmitted_model_input:
    (Keeper_official_client_host.transmitted_model_input -> unit) ->
  hooks:Agent_core.Hooks.hooks option ->
  context_injector:Agent_core.Hooks.context_injector option ->
  context:Agent_core.Context.t option ->
  ?terminal_effect_state:(unit -> Keeper_tools_agent_core.terminal_effect_state) ->
  ?on_model_input_window_observation:
    (Runtime_model_input_tail_window.window_observation -> unit) ->
  ?carried_front_seed:(unit -> Keeper_carried_front.seed_read) ->
  ?librarian_front:Keeper_turn_driver_try_provider.continuity ->
  ?on_carried_front:Keeper_official_client_host.carried_front_observer ->
  turn_start:Keeper_carried_front.turn_start ->
  ?on_official_client_tool_boundary:
    (tool_name:string ->
     (Keeper_official_client_host.host_stop option, Agent_core.Error.t) result) ->
  ?on_official_client_result_handoff:
    (invocation:Agent_core.Tool_contract.Invocation.t -> content:string -> unit) ->
  ?on_native_tool_completion:
    (block_index:int ->
     tool_call_id:string option ->
     Runtime_native_tools.completion ->
     unit) ->
  ?on_native_action:
    (official_turn:int ->
     identity:Runtime_native_tools.action_identity ->
     tool_name:string ->
     unit) ->
  ?on_usage_report:(Keeper_client_usage_report.t -> unit) ->
  ?on_tool_execution:
    (block_index:int -> tool_call_id:string -> execution_id:Ids.Execution_id.t -> unit) ->
  event_bus:Agent_core.Event_bus.t option ->
  raw_trace:Agent_core.Raw_trace.t option ->
  on_event:(Agent_core.Types.sse_event -> unit) option ->
  config:Runtime_execution.acp_client ->
  unit ->
  Keeper_official_client_attempt.outcome

module For_testing : sig
  val acp_error_to_core_error : Runtime_acp_client.error -> Agent_core.Error.t

  val recovery_failure_of_acp_error
    :  Runtime_acp_client.error
    -> Keeper_official_client_session_store.recovery_failure

  val api_usage_of_acp_usage
    :  driver:Runtime_acp_client.driver
    -> Runtime_acp_client.usage
    -> Agent_core.Types.api_usage

  val stop_reason_of_acp_stop_reason
    :  Runtime_acp_client.stop_reason
    -> Agent_core.Types.stop_reason

  val compaction_detected : prev_used:int option -> cur_used:int option -> bool

  val start_mcp_bridge_for_specs
    :  sw:Eio.Switch.t
    -> env:Eio_unix.Stdenv.base
    -> pinned_tool_specs:Yojson.Safe.t list
    -> Runtime_official_client_mcp_http.t

  type pool_key =
    { keeper_name : string
    ; runtime_id : string
    ; tool_surface_sha256 : string
    ; cwd : string
    ; dangerously_skip_permissions : bool
    }

  val run_serialized_turn
    :  mutex:Eio.Mutex.t
    -> on_holder_exception:(unit -> unit)
    -> (unit -> ('a, Agent_core.Error.t) result)
    -> ('a, Agent_core.Error.t) result

  module Pool : sig
    type 'a t

    val create : unit -> 'a t
    val count : 'a t -> int
    val find_opt : 'a t -> pool_key -> 'a option

    val install_for_keeper
      :  'a t
      -> key:pool_key
      -> fresh:'a
      -> is_alive:('a -> bool)
      -> close:('a -> unit)
      -> 'a

    val evict_if_same : 'a t -> key:pool_key -> target:'a -> close:('a -> unit) -> unit
    val evict_keeper : 'a t -> keeper_name:string -> close:('a -> unit) -> unit
  end
end
