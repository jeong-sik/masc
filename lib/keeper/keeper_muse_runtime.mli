(** Keeper projection for the official Muse Code subscription runtime.

    One Keeper turn is one [muse serve] turn ({!Runtime_muse_serve}). The
    Keeper's dynamic tools reach the session through a turn-scoped loopback
    MCP bridge ({!Runtime_official_client_mcp_http}) that the session adds as
    its own [masc] server. The official-client session store records the
    vendor session the same way it does for Codex, Claude Code and
    Antigravity: claim, active, turn starting, turn identity, settle, and a
    recovery observation when the turn fails. *)

val runtime_label : string
(** The client's name in the Keeper's errors and logs. *)

val resolve_native_posture :
  base_path:string ->
  keeper_name:string ->
  required_native_posture:Runtime_native_tools.posture option ->
  (Runtime_native_tools.posture, Agent_core.Error.t) result
(** The same strict admission used by [run]: absent configuration defaults to
    native read; native none is refused, and native full requires the Keeper's
    explicit full-access mode. *)

type attempt_outcome =
  { result : (Runtime_agent.run_result, Agent_core.Error.t) result
  ; settled_session : Keeper_official_client_session_store.t option
  ; effect_disposition : Keeper_provider_attempt_effect.t
  }
(** One Muse Code candidate result plus its typed effect observation.
    Validation, bridge start, process spawn, the session start and a
    [turn/start] the host refuses are effect-free. A [turn/start] write that
    broke off, or one that was written and not refused, is
    [Observation_unavailable]: the host takes a command in durably before it
    answers. Once the host acknowledges the turn it is at least
    [Observation_unavailable] whatever follows: the configured native policy
    constrains permission, but is not an execution receipt, and a subagent's
    tools run in a child session this adapter does not observe. Entering a dynamic tool is [Effect_attempted]
    before user/tool code can run. *)

val run :
  ?official_task_reference:Keeper_official_task_reference.t ->
  accepts_image_input:bool ->
  ?required_native_posture:Runtime_native_tools.posture ->
  ?official_client_continuation:Keeper_semantic_execution.official_client_checkpoint ->
  runtime_id:string ->
  keeper_name:string ->
  pre_tool_rejects:Keeper_official_client_host.rejected_tool_call list ref ->
  base_path:string ->
  workspace_root:string ->
  goal:string ->
  goal_blocks:Agent_core.Types.content_block list option ->
  system_prompt:string ->
  tools:Agent_core.Tool.t list ->
  initial_messages:Agent_core.Types.message list ->
  model_input_projection:Agent_core.Agent.model_input_projection option ->
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
    (unit -> (Keeper_official_client_host.host_stop option, Agent_core.Error.t) result) ->
  ?on_official_client_result_handoff:
    (invocation:Agent_core.Tool_contract.Invocation.t -> content:string -> unit) ->
  ?on_native_action:(official_turn:int ->
    identity:Runtime_native_tools.action_identity -> tool_name:string -> unit) ->
  ?on_usage_report:(Keeper_client_usage_report.t -> unit) ->
  event_bus:Agent_core.Event_bus.t option ->
  raw_trace:Agent_core.Raw_trace.t option ->
  on_event:(Agent_core.Types.sse_event -> unit) option ->
  config:Runtime_muse_serve.config ->
  unit ->
  attempt_outcome
(** [workspace_root] is an explicitly selected absolute native directory.
    The caller owns selecting the Keeper's workspace and account home.
    The adapter prepares a managed profile and credential generation before
    the claim; an absent account home is refused. This adapter selects no host or guest path implicitly.

    Account home, opaque sign-in generation, native posture and tools bind session reuse. Canonical
    history, instructions, model and workspace changes start a fresh session;
    a Gate continuation instead refuses a mismatch before dispatch.

    Native read requires the client's explicit write/shell disable flags and
    a managed read profile. Only exact attached MCP requests are approved.
    Native none is unsupported. This is not an MASC-only execution claim.

    Start carries canonical history; Resume reports the history held by the
    vendor session and sends the current goal and context. A declared
    max-prompt-bytes bounds the prepared input because MSP supplies no typed
    oversized-input error. No top-level runtime routing is exposed here. *)

module For_testing : sig
  val usage_reports
    :  turn_count:int
    -> position:Keeper_usage_resolution.cumulative_position
    -> Runtime_muse_serve.stream_event list
    -> Keeper_client_usage_report.t list
  (** The usage reports the Keeper stream projection makes for [events], in
      order, with no stream observer installed. *)

  val project_stream :
    Runtime_muse_serve.stream_event list -> Agent_core.Types.sse_event list
  (** The Keeper live-stream events the projection emits for [events], in
      order, with no MASC tool call between them. *)

  type stream_input =
    | Serve_event of Runtime_muse_serve.stream_event
        (** An event the serve client read from [muse serve]'s stdout. *)
    | Mcp_tool_started of
        { call_id : string
        ; tool_name : string
        ; arguments : Yojson.Safe.t
        }  (** MASC's MCP bridge began answering a tool call. *)
    | Mcp_tool_finished of { call_id : string }
        (** The bridge finished that call. *)

  val project_stream_inputs :
    during:(Agent_core.Types.sse_event -> stream_input list) ->
    stream_input list ->
    Agent_core.Types.sse_event list
  (** The Keeper live-stream events the projection emits for [inputs] from
      both channels, in the order the viewer records them. [during event]
      names inputs that arrive while [event] is being emitted, as the
      bridge's fiber would when the viewer's callback yields before it
      records [event]; they are fed before [event] is recorded. *)

  val runtime_error_to_core_error : Runtime_muse_serve.error -> Agent_core.Error.t

  val recovery_failure_of_runtime_error :
    Runtime_muse_serve.error -> Keeper_official_client_session_store.recovery_failure

  val start_prompt :
    system_prompt:string ->
    goal:string ->
    Agent_core.Types.message list ->
    (string, string) result
  (** The prompt a start turn sends, rendered by the production formatter. *)

  val reserved_prompt_bytes : system_prompt:string -> goal:string -> int
  (** What the fixed sections of a start prompt charge against
      [max-prompt-bytes] before any history message. *)

  val measure_model_input_message_bytes : Agent_core.Types.message -> int
  (** What the window charges one history message, framing included. *)

  val native_posture_note : Runtime_native_tools.posture -> string list
  (** What a start prompt's system section adds after the system prompt to
      tell the model the session's posture. *)
end
