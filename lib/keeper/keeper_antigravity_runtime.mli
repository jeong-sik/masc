(** Keeper projection for the official Antigravity subscription runtime. *)

type attempt_outcome =
  { result : (Runtime_agent.run_result, Agent_core.Error.t) result
  ; settled_session : Keeper_official_client_session_store.t option
  ; pending_result_receipts : Keeper_client_tool_outbox.consumption option
      (** [Some] names exact receipt snapshots of a durably settled candidate,
          not acceptance. [None] carries no authority on failed/prevalidation
          results. The caller accepts first, then settles with its final stop reason. *)
  ; effect_disposition : Keeper_provider_attempt_effect.t
  }
(** One Antigravity candidate result plus its typed effect observation.
    Validation, setup and spawn rejection are effect-free. Entering a dynamic
    tool closes the same-turn retry boundary before user/tool code can run.
    A non-completed result keeps any observed effect or marks observation
    unavailable: built-in tools may have run outside the MCP observer. *)

val run :
  ?on_guidance_prepared:(unit -> (unit,Agent_core.Error.t) result) ->
  input_source:Keeper_request_source.t ->
  ?argument_source:Keeper_official_client_host.argument_source ->
  ?official_task_reference:Keeper_official_task_reference.t ->
  ?composed_context:(unit -> Keeper_official_client_host.composed_context option) ->
  (* Read after hook assembly to preserve typed block rendering. This lane
      resends context on every resume until a compaction/reset witness can
      prove previously delivered blocks remain available to the model. *)
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
  ?librarian_front:Keeper_official_client_host.librarian_front_reader ->
  ?on_carried_front:
    (Keeper_official_client_host.carried_start_front -> transmitted_bytes:int -> unit) ->
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
  attempt_outcome
(** [on_transmitted_model_input] fires once per turn, after the carried
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

    [librarian_front] reads the turn's continuity choice as a position in the
    history a fresh conversation starts from
    ({!Keeper_official_client_host.read_librarian_front}); a reader error
    refuses the request, as the same check refuses an Agent Core request.
    [on_carried_front] receives the front that history started from and its
    bytes in the canonical encoding; the caller records it where the Agent
    Core lane records its own request
    ({!Keeper_official_client_host.continuity_observation_input}). *)

val eager_tool_names : Keeper_official_client_host.dynamic_tool list -> string list
(** The tools this lane marks [eager] in the Antigravity MCP config: all of
    them, whatever their declared [loading]. A tool that is not eager gets no
    schema unless the model reads a schema file, and a masc home denies
    [read_file] ({!Runtime_official_client_mcp_http.mcp_config_json}), so a
    declared on-demand tool is still eager here. *)

module For_testing : sig
  val runtime_error_to_core_error : Runtime_antigravity.error -> Agent_core.Error.t
  (** The Agent Core error a runtime error becomes. *)

  val recovery_failure_of_runtime_error
    :  Runtime_antigravity.error
    -> Keeper_official_client_session_store.recovery_failure
  (** The durable recovery failure a runtime error settles a claim with. *)

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
