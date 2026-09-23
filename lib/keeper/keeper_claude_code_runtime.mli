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
    -> ?librarian_front:Keeper_official_client_host.librarian_front_reader
    -> ?on_carried_front:
         (Keeper_official_client_host.carried_start_front -> transmitted_bytes:int -> unit)
    -> turn_start:Keeper_carried_front.turn_start
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

  val recovery_failure_of_attempt
    :  session_mode:Runtime_claude_code.session_mode
    -> gate_continuation:bool
    -> Runtime_claude_code.error
    -> Keeper_official_client_session_store.recovery_failure
  (** The recovery failure an attempt records. A Gate continuation's resume
      refused as a context overflow is [Vendor_session_full], carrying whether
      a response or tool effect was observed first; everything else is
      {!recovery_failure_of_client_error}. *)
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
    range does not widen it and the ceiling does not undo the seed.
    [turn_start] is where the range starts when no seed names a front: the
    end of the last completed turn on this history, 0 when it has none, and
    the newest atom alone when that boundary is unknown (RFC
    keeper-context-window-in-tokens §13.4). A caller that passes no seed
    starts there, inside the ceiling.

    [librarian_front] hands over the turn's continuity choice as a position
    in the messages it is handed
    ({!Keeper_turn_driver_try_provider.librarian_position}): a fitting working
    state, carried in place of the atoms before it, or the Librarian's read
    position alone, with nothing carried for the atoms before it. It wins
    when it is at or past the seed that holds, or the ceiling's cut when no
    seed holds, so the range never moves back behind either; [turn_start] is
    not weighed against it, since it is where a range with no absorbed point
    begins. The ceiling cuts before the working state is known, so whether
    it goes is decided by {!Keeper_official_client_host.compose_librarian_range}
    (RFC-0460): it is carried only where it displaces none of the range's
    atoms, and otherwise the Librarian position goes alone and the turn is
    not refused. A reader error refuses the request, as the same check
    refuses an Agent Core request.

    [on_carried_front] receives the front the range started from and the
    range's bytes in the canonical encoding, once per composition that cut a
    range (the zero-history floor cuts none). The caller records it where the
    Agent Core lane records its own request
    ({!Keeper_official_client_host.continuity_observation_input}).

    [on_transmitted_model_input] fires once per attempt, after the capacity
    window has cut the history and before the prompt is built. Required rather
    than optional: a lane that reports nothing is what wrote every turn's
    input attribution on this lane as zero (masc#32995).

    It reports [Whole_input_transmitted] only on a [Start], the one branch
    whose prompt carries the history. A [Resume] reports
    [Held_by_client_session]: the accumulated conversation is the CLI's, not
    this process's, so it cannot be measured here.

    On a [Resume] Claude Code sends the system prompt it recorded at the
    session's first launch, not the [--system-prompt-file] this process
    writes, until the conversation is compacted. The resume prompt is
    therefore {!Keeper_official_client_host.resume_prompt}: the per-turn
    context carrier, the Librarian working state and the historical task
    reference in front of the goal. Any other per-turn System message must
    carry one of the markers {!Keeper_official_client_host.is_carried_on_resume}
    reads, or a resumed session never sees it. The canonical conversation is
    not sent, and the session's context frontier records
    [Held_by_vendor_session]. A resume reports no window observation and no
    carried front: the range the projection measures is not what it sends.

    A context overflow on a [Resume] is the vendor's own conversation, which a
    smaller range does not change. Without a continuation the shrink retry
    starts fresh and carries the shrunk range; a Gate continuation, bound to
    its original session, ends the turn on the typed overflow instead, and the
    session is recorded [Vendor_session_full] whether or not a response or tool
    effect came first: the Gate operation fails for good and the next ordinary
    turn starts a fresh session.

    A [Start] is unchanged: the system prompt file carries the Keeper prompt
    and every System message, and the prompt carries the history and the
    goal. *)
