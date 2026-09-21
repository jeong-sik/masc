(** Keeper projection for the official Claude Code subscription runtime. *)

type attempt_outcome =
  { result : (Runtime_agent.run_result, Agent_core.Error.t) result
  ; settled_session : Keeper_official_client_session_store.t option
  ; effect_disposition : Keeper_provider_attempt_effect.t
  }
(** One Claude Code candidate result plus the explicit tool-effect observation
    available at its runtime boundary. Preflight failures remain
    [No_effect_observed]; once the model turn is dispatched, the adapter fails
    closed with [Observation_unavailable]. *)

module For_testing : sig
  (** Typed carriage of Claude Code client errors into agent-core errors, the
      twin of [Keeper_codex_runtime.For_testing.codex_error_to_core_error].
      Pinned by [test_keeper_claude_code_runtime]. *)
  val claude_error_to_core_error :
    Runtime_claude_code.error -> Agent_core.Error.t

  val observe_stream_native_action :
    turn_count:int ->
    observe:(official_turn:int -> identity:Runtime_native_tools.action_identity ->
      tool_name:string -> unit) ->
    Runtime_claude_code.stream_event -> unit
  val bounded_probe_config
    :  fallback_timeout_s:float
    -> Runtime_claude_code.config
    -> Runtime_claude_code.config
  (** Keep an explicit turn bound unchanged and give an unbounded turn config a
      finite login-probe fallback. *)

  val host_stop_turn_identity : session_id:string -> turn_count:int -> string
  (** Deterministic durable identity used when a dynamic-tool host stop arrives
      before Claude emits its terminal result-frame turn id. *)

  val start_seed_projection
    :  capacity_bytes:int
    -> ?carried_front_seed:(unit -> Keeper_carried_front.seed_read)
    -> ?on_model_input_window_observation:
         (Runtime_model_input_tail_window.window_observation -> unit)
    -> keeper_name:string
    -> runtime_id:string
    -> Agent_core.Types.message list
    -> (Agent_core.Types.message list, Agent_core.Error.t) result
  (** The start seed this lane composes: the declared ceiling's cut and the
      seeded front, whichever names the later atom. Pinned by
      [test_keeper_claude_code_runtime]. *)

  val unbounded_capacity_bytes : int
  (** [capacity_bytes] for a runtime that declares no max-prompt-bytes. *)

  val recovery_failure_of_client_error
    :  Runtime_claude_code.error
    -> Keeper_official_client_session_store.recovery_failure
  (** Typed map from a Claude Code client error to the durable recovery
      failure. A typed context overflow becomes [Input_rejected] so the
      session admission fence can hold instead of auto-replaying. *)
end

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
  ?on_official_client_tool_boundary:
    (unit -> (Keeper_official_client_host.host_stop option, Agent_core.Error.t) result) ->
  ?on_official_client_result_handoff:
    (invocation:Agent_core.Tool_contract.Invocation.t -> content:string -> unit) ->
  ?on_native_action:(official_turn:int ->
    identity:Runtime_native_tools.action_identity -> tool_name:string -> unit) ->
  event_bus:Agent_core.Event_bus.t option ->
  raw_trace:Agent_core.Raw_trace.t option ->
  on_event:(Agent_core.Types.sse_event -> unit) option ->
  config:Runtime_execution.claude_code ->
  unit ->
  attempt_outcome
(** [on_model_input_window_observation] receives how much of the offered
    history this turn actually carried. The Agent Core path reports the same
    reading through [Keeper_turn_driver]'s callback of that name; without it
    here, every official-client turn record was written with no window and no
    input composition, which is what [/context] reads.

    [carried_front_seed] names where the start seed begins: the range the
    newest completed turn record on this history carried, whichever runtime
    measured it ({!Keeper_official_client_host.carried_start_range}). The
    declared max-prompt-bytes ceiling still cuts, and the range starts at
    whichever of the two positions is later, so a turn seeded from a narrow
    range does not widen it and the ceiling does not undo the seed. A caller
    that passes none starts a start seed at the oldest atom, inside the
    ceiling.

    [on_transmitted_model_input] fires once per attempt, after the capacity
    window has cut the history and before the prompt is built. Required rather
    than optional: a lane that reports nothing is what wrote every turn's
    input attribution on this lane as zero (masc#32995).

    It reports [Whole_input_transmitted] only on a [Start], the one branch
    whose prompt carries the history. A [Resume] reports
    [Held_by_client_session] and sends the goal alone: the accumulated
    conversation is the CLI's, not this process's, so it cannot be measured
    here -- which is what the composition line for this lane has said all
    along. *)
