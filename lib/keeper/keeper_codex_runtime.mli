(** Keeper projection for the official Codex app-server turn runtime. *)

type successful_tool_completion =
  | No_successful_tool_completion
  | Successful_tool_completion

type attempt_outcome =
  { result : (Runtime_agent.run_result, Agent_core.Error.t) result
  ; settled_session : Keeper_official_client_session_store.t option
  ; effect_disposition : Keeper_provider_attempt_effect.t
  ; successful_tool_completion : successful_tool_completion
  }
(** One Codex candidate result plus two distinct typed tool facts observed
    while producing it. The outer runtime-lane owner consumes
    [effect_disposition] as retry authority; [successful_tool_completion]
    only proves that a handler returned a successful result and can therefore
    support accepting a tool-only terminal. *)

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
  config:Runtime_execution.codex_app_server ->
  unit ->
  attempt_outcome
(** [on_model_input_window_observation] receives how much of the offered
    history a [Start] carried. Without it the turn record is written with no
    window and no input composition, which is what [/context] reads. A
    [Resume] sends no history and reports no window.

    A [Start] carries the carried range, not the whole history
    ({!Keeper_official_client_host.carried_start_range}), and injects it into
    the new thread; a [Resume] sends none of the history. The range starts
    where the last answered request's range did ([carried_front_seed]), at the
    turn's Librarian position ([librarian_front]) when that is later, else at
    [turn_start]. [on_carried_front] reports the front each [Start]
    composition cut, before the write, as on the Claude Code lane; a [Resume]
    reports none. When an overflow retry reaches the zero-history floor, no
    carried front is reported because no conversation atom is transmitted.

    [on_transmitted_model_input] fires once per attempt, after context injection
    is acknowledged and the complete turn/start input is written. Required
    rather than optional: a lane that reports nothing is what wrote every
    turn's input attribution on this lane as zero (masc#32995).

    [on_usage_report] receives the thread's running count from every
    [thread/tokenUsage/updated] frame of the turn, with the thread it counts,
    while the turn is still running, so a turn that ends in an error still
    reports it. A frame is not one response: repeats carry the same count.

    It reports [Whole_input_transmitted] only on a [Start], the one branch
    that injects the history into the thread. A [Resume] reports
    [Held_by_client_session]: the thread holds the conversation, and MASC sends
    only the per-turn context in front of the goal
    ({!Keeper_official_client_host.resume_prompt}), so its full model input
    cannot be measured here. *)

module For_testing : sig
  val note_transport_uncertainty : Keeper_provider_attempt_effect.t Atomic.t -> unit
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

  (** A Gate continuation's resume that overflowed is [Vendor_session_full],
      [Activity_observed] when a tool effect came first and
      [No_activity_observed] otherwise; everything else is
      {!recovery_failure_of_client_error}. *)
  val recovery_failure_of_attempt :
    thread_mode:Runtime_codex_app_server.thread_mode -> gate_continuation:bool ->
    Runtime_codex_app_server.error -> Keeper_official_client_session_store.recovery_failure

  val carried_projection
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
  (** The history a [Start] carries: the carried range, cut again by a
      declared ceiling when there is one. *)

  val unbounded_capacity_bytes : int
  (** [capacity_bytes] for a runtime that declares no max-prompt-bytes. *)
end
