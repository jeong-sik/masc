(** Keeper projection for the official Antigravity subscription runtime. *)

val run :
  ?on_guidance_prepared:(unit -> (unit,Agent_core.Error.t) result) ->
  input_source:Keeper_request_source.t ->
  ?argument_source:Keeper_official_client_host.argument_source ->
  ?on_memory_capacity_refusal:Keeper_memory_delivery_reprojection.t ->
  ?official_task_reference:Keeper_official_task_reference.t ->
  ?composed_context:(unit -> Keeper_official_client_host.composed_context option) ->
  (* Read after hook assembly to preserve typed block rendering. Held
     standing-context digests from the last settled turn avoid resending
     unchanged blocks on Resume; standing System observations refresh under
     [resume_system_notice]. *)
  accepts_image_input:bool ->
  ?required_native_posture:Runtime_native_tools.posture ->
  ?official_client_continuation:Keeper_semantic_execution.official_client_checkpoint ->
  runtime_id:string ->
  host:Runtime_account_access.host_account ->
    (** The start the access allowed for this attempt (plan D3b). *)
  configured_reasoning_effort:Llm_provider.Reasoning_effort.t option ->
  turn_timeout_s:float option ->
  keeper_name:string ->
  pre_tool_rejects:Keeper_official_client_host.rejected_tool_call list ref ->
  base_path:string ->
  outbox_viewer:Keeper_client_tool_outbox.viewer ->
  read_retained_media:Keeper_client_tool_outbox.media_reader option ->
  (* The lane walk's shared reader for retained host Audio/Document results.
      [None] preserves the original-only carrier, including completion review.
      This Text surface needs readings even on a native-media-capable lane. *)
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
    (tool_name:string -> (Keeper_official_client_host.host_stop option, Agent_core.Error.t) result) ->
  ?on_official_client_result_handoff:
    (invocation:Agent_core.Tool_contract.Invocation.t -> content:string -> unit) ->
  ?on_native_tool_completion:
    (block_index:int -> tool_call_id:string option -> Runtime_native_tools.completion -> unit) ->
  ?on_native_action:(official_turn:int ->
    identity:Runtime_native_tools.action_identity -> tool_name:string -> unit) ->
  ?on_usage_report:(Keeper_client_usage_report.t -> unit) ->
  ?on_tool_execution:
    (block_index:int -> tool_call_id:string -> execution_id:Ids.Execution_id.t -> unit) ->
  (* Each MASC tool call's committed execution id, named by the stream block
     that opened it. A call answered before init opens the message is
     reported after its held block reaches the stream. *)
  event_bus:Agent_core.Event_bus.t option ->
  raw_trace:Agent_core.Raw_trace.t option ->
  on_event:(Agent_core.Types.sse_event -> unit) option ->
  config:Runtime_execution.antigravity_cli ->
  unit ->
  Keeper_official_client_attempt.outcome
(** One Antigravity candidate result plus its typed effect observation.
    Validation, setup and spawn rejection are effect-free. Entering a dynamic
    tool closes the same-turn retry boundary before user/tool code can run.
    A non-completed result keeps any observed effect or marks observation
    unavailable: built-in tools may have run outside the MCP observer.

    [on_transmitted_model_input] fires once per turn, after the carried
    range is composed and before the prompt is rendered. Required
    rather than optional: a lane that reports nothing is what wrote every
    Antigravity turn's input attribution as zero (masc#32995).

    [configured_reasoning_effort] and [turn_timeout_s] come from the already
    selected model. They are not looked up again by [runtime_id] on fresh or
    resumed turns. An absent idle declaration keeps
    the captured provider timeout; a nonpositive declaration removes the model
    idle bound. Native admission still uses the provider timeout.
    Generic reasoning intent is passed through host hooks and remains subject
    to Antigravity's existing refusal: only [config.effort] owns native effort.
    [None] declares no generic reasoning intent; a hook may set or clear it.

    It reports [Whole_input_transmitted] only when the conversation starts,
    because only then does the rendered prompt carry the whole list. The
    carried range and its observation likewise apply only to that fresh
    input. A resumed conversation reports [Held_by_client_session]: the CLI
    re-sends just the new turn, so what the model reads is not this process's
    to measure.

    [librarian_front] is the turn's continuity
    ({!Keeper_turn_driver_try_provider.read_keeper_continuity}): where the
    Memory writer has read to in the history a fresh conversation starts
    from, and the working state it committed. Without it the turn has no
    read end.
    [on_carried_front] receives the front that history started from and its
    bytes in the canonical encoding; the caller records where the request
    starts, as the Agent Core lane does for its own request
    ({!Keeper_request_start.record}). *)

module For_testing : sig
  val runtime_error_to_core_error : Runtime_antigravity.error -> Agent_core.Error.t
  (** The Agent Core error a runtime error becomes. *)

  val recovery_failure_of_runtime_error
    :  Runtime_antigravity.error
    -> Keeper_official_client_session_store.recovery_failure
  (** The durable recovery failure a runtime error settles a claim with. *)

  val recovery_failure_of_attempt
    :  conversation_mode:Runtime_antigravity.conversation_mode
    -> gate_continuation:bool
    -> Runtime_antigravity.error
    -> Keeper_official_client_session_store.recovery_failure

  val unbounded_capacity_bytes : int

  val start_seed_projection
    :  input_source:Keeper_request_source.t
    -> capacity_bytes:int
    -> ?carried_front_seed:(unit -> Keeper_carried_front.seed_read)
    -> ?librarian_front:Keeper_turn_driver_try_provider.continuity
    -> ?on_carried_front:Keeper_official_client_host.carried_front_observer
    -> turn_start:Keeper_carried_front.turn_start
    -> ?on_model_input_window_observation:
         (Runtime_model_input_tail_window.window_observation -> unit)
    -> keeper_name:string
    -> runtime_id:string
    -> Agent_core.Types.message list
    -> (Agent_core.Types.message list, Agent_core.Error.t) result

  val observe_resume_shrink_capacity
    :  input_source:Keeper_request_source.t
    -> capacity_bytes:int
    -> turn_start:Keeper_carried_front.turn_start
    -> keeper_name:string
    -> runtime_id:string
    -> Agent_core.Types.message list
    -> (int option * int option, Agent_core.Error.t) result

  val held_context_for_resume_turn
    :  resume_system_notice:string option
    -> previously_held:Keeper_official_client_session_store.held_context list
    -> goal:string
    -> turn_observation:Keeper_official_client_host.turn_observation option
    -> ?composed_context:Keeper_official_client_host.composed_context
    -> Agent_core.Types.message list
    -> Keeper_official_client_session_store.held_context list

  val report_stream_usage
    :  turn_count:int
    -> position:Keeper_usage_resolution.cumulative_position
    -> report:(Keeper_client_usage_report.t -> unit)
    -> Runtime_antigravity.stream_event
    -> unit
  (** Feed one runtime event through the Keeper stream projection with only a
      usage observer installed. *)

  val project_stream :
    ?on_event:(Agent_core.Types.sse_event -> unit) ->
    ?on_native_tool_completion:(block_index:int -> tool_call_id:string option ->
      Runtime_native_tools.completion -> unit) ->
    Runtime_antigravity.stream_event list -> Agent_core.Types.sse_event list
  (** The Keeper live-stream events the projection emits for [events], in
      order, with no MASC tool call between them. *)

  type stream_input =
    | Cli_event of Runtime_antigravity.stream_event
        (** A runtime event parsed from the CLI's stdout. *)
    | Mcp_tool_started of
        { call_id : string
        ; tool_name : string
        ; arguments : Yojson.Safe.t
        }  (** MASC's MCP server began answering a tool call. *)
    | Mcp_tool_finished of { call_id : string }
        (** MASC's MCP server finished that call. *)

  val project_stream_inputs :
    during:(Agent_core.Types.sse_event -> stream_input list) ->
    stream_input list ->
    Agent_core.Types.sse_event list
  (** The Keeper live-stream events the projection emits for [inputs] from
      both channels, in order. [during event] names inputs that arrive while
      [event] is being emitted, as another fiber would when emitting yields;
      they are fed before the emit returns. *)

end
