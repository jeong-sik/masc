(** Keeper projection for the official Muse subscription runtime. *)

type attempt_outcome =
  { result : (Runtime_agent.run_result, Agent_core.Error.t) result
  ; settled_session : Keeper_official_client_session_store.t option
  ; effect_disposition : Keeper_provider_attempt_effect.t
  }
(** One Muse candidate result plus its typed effect observation. Validation,
    prompt-file preparation, process spawn, and provider work before the
    first model output are provably effect-free. The CLI's built-in tools
    run inside the client where MASC cannot observe them, so a turn that
    ran them still reports [No_effect_observed]: the disposition covers
    MASC-observed attempts only. *)

val run :
  ?official_task_reference:Keeper_official_task_reference.t ->
  accepts_image_input:bool ->
  ?required_native_posture:Runtime_native_tools.posture ->
  ?official_client_continuation:Keeper_semantic_execution.official_client_checkpoint ->
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
  config:Runtime_execution.muse_cli ->
  unit ->
  attempt_outcome
(** [on_transmitted_model_input] fires once per turn, after the complete
    prompt file is handed to the spawned child. Required rather than
    optional: a lane that reports nothing is what wrote every Antigravity
    turn's input attribution as zero (masc#32995).

    It reports [Whole_input_transmitted] only when the conversation starts,
    because only then does the rendered prompt carry the whole list. A
    resumed conversation reports [Held_by_client_session]: the CLI holds
    the seeded history, so what the model reads is not this process's to
    measure.

    The transport carries no MASC tools, so [pre_tool_rejects],
    [terminal_effect_state], [on_official_client_tool_boundary] and
    [on_official_client_result_handoff] are accepted and have no effect;
    [context], [context_injector] and [on_native_action] likewise have no
    carrier here. There is no carried-front window: the whole prompt file
    goes out, so [on_model_input_window_observation], [carried_front_seed],
    [librarian_front] and [on_carried_front] are accepted and unread, and
    [turn_start] only seeds the session claim. *)

module For_testing : sig
  val report_stream_usage
    :  turn_count:int
    -> position:Keeper_usage_resolution.cumulative_position
    -> report:(Keeper_client_usage_report.t -> unit)
    -> Runtime_muse.stream_event
    -> unit
  (** Feed one runtime event through the Keeper stream projection with only a
      usage observer installed. *)

  val start_prompt_bytes :
    system_prompt:string ->
    goal:string ->
    Agent_core.Types.message list ->
    (int, string) result
  (** Render through the production start-turn formatter and return the exact
      transmitted prompt byte count. *)

  val muse_images_of_goal_blocks
    :  Agent_core.Types.content_block list
    -> (Runtime_muse.image_input list, Agent_core.Error.t) result
  (** Decode goal images into the CLI's [--image] file inputs. The files are
      written under the process temporary directory and live until the turn
      that consumed them finishes. *)
end
