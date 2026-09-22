(** Keeper projection for the official Antigravity subscription runtime. *)

type attempt_outcome =
  { result : (Runtime_agent.run_result, Agent_core.Error.t) result
  ; settled_session : Keeper_official_client_session_store.t option
  ; effect_disposition : Keeper_provider_attempt_effect.t
  }
(** One Antigravity candidate result plus its typed effect observation.
    Validation, setup, process spawn, and provider work before the first
    dynamic tool invocation are provably effect-free. Entering a dynamic tool
    closes the same-turn retry boundary before user/tool code can run. *)

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
  event_bus:Agent_core.Event_bus.t option ->
  raw_trace:Agent_core.Raw_trace.t option ->
  on_event:(Agent_core.Types.sse_event -> unit) option ->
  config:Runtime_execution.antigravity_cli ->
  unit ->
  attempt_outcome
(** [on_transmitted_model_input] fires once per turn, after the admission
    window has cut the history and before the prompt is rendered. Required
    rather than optional: a lane that reports nothing is what wrote every
    Antigravity turn's input attribution as zero (masc#32995).

    It reports [Whole_input_transmitted] only when the conversation starts,
    because only then does the rendered prompt carry the whole list. The
    admission window and its observation likewise apply only to that fresh
    input. A resumed conversation reports [Held_by_client_session]: the CLI
    re-sends just the new turn, so what the model reads is not this process's
    to measure.

    [librarian_front] reads the turn's continuity choice as a position in the
    history a fresh conversation starts from
    ({!Keeper_official_client_host.read_librarian_front}); a reader error
    refuses the request, as the same check refuses an Agent Core request.
    [on_carried_front] receives the front that history started from and its
    bytes in the canonical encoding, before the declared window cuts it; the
    caller records it where the Agent Core lane records its own request
    ({!Keeper_official_client_host.continuity_observation_input}). *)

module For_testing : sig
  val capacity_bounded_model_input_projection
    :  declared_max_prompt_bytes:int option
    -> system_prompt:string
    -> goal:string
    -> ?on_model_input_window_observation:
         (Runtime_model_input_tail_window.window_observation -> unit)
    -> ?carried_front_seed:(unit -> Keeper_carried_front.seed_read)
    -> ?librarian_front:Keeper_official_client_host.librarian_front_reader
    -> ?on_carried_front:
         (Keeper_official_client_host.carried_start_front -> transmitted_bytes:int -> unit)
    -> turn_start:Keeper_carried_front.turn_start
    -> keeper_name:string
    -> runtime_id:string
    -> Agent_core.Agent.model_input_projection option
    -> (Agent_core.Agent.model_input_projection option, Agent_core.Error.t) result
  (** Starts from the admitted carried front, runs the source projection, then
      applies the declared byte window. A Librarian front carries a pinned
      working state that the window cannot trim; a window it does not fit
      refuses the request, as for any pinned message. Thus a Gate replay reference is
      charged to the provider-bound input without becoming a front in the
      durable checkpoint vocabulary. Refuses an undeclared window:
      Antigravity has no typed overflow response from which MASC could derive
      a safe retry capacity. *)

  val start_prompt_bytes :
    system_prompt:string ->
    goal:string ->
    Agent_core.Types.message list ->
    (int, string) result
  (** Render through the production start-turn formatter and return the exact
      transmitted prompt byte count. *)

  val reserved_prompt_bytes : system_prompt:string -> goal:string -> int
end
