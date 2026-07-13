(** Keeper_unified_turn_types — pure helpers extracted from
    Keeper_unified_turn (3020 LoC godfile).

    Holds [unit -> Yojson] and JSON projection helpers used by the
    unified keeper turn loop. State-touching orchestration stays in
    Keeper_unified_turn. Re-included by it so existing callers continue
    to use [Keeper_unified_turn.<name>] unchanged. *)

(** Immutable per-turn accumulator that replaces the casual [ref] cells
    previously threaded through [run_keeper_cycle] and the retry loop. *)
type turn_state =
  { cycle_completed : bool
  ; manifest_seq : int
  ; post_commit_failure_reason : Keeper_registry.failure_reason option
  ; current_turn_blocker_info : Keeper_meta_contract.blocker_info option
  ; last_execution : Keeper_turn_runtime_budget.runtime_execution option
  ; last_provider_timeout_budget : Keeper_turn_runtime_budget.provider_timeout_budget option
  ; degraded_retry_info : Keeper_error_classify.degraded_retry option
  ; runtime_rotation_attempts : Keeper_execution_receipt.runtime_rotation_attempt list
  ; failure_reason : Keeper_turn_fsm.failure_reason option
  ; retry_phase_started_at : float option
  }

val require_last_execution_for_finalize :
  keeper_name:string ->
  turn_state ->
  (Keeper_turn_runtime_budget.runtime_execution, Agent_sdk.Error.sdk_error) result

val turn_event_bus_manifest_decision :
  Keeper_turn_runtime_budget.turn_event_bus_summary -> Yojson.Safe.t

(** [registry_failure_reason_of_terminal_reason terminal ~raw_error]
    maps a [Keeper_turn_terminal.t] disposition to the corresponding
    [Keeper_registry.failure_reason], or [None] for benign terminals
    (Success, External_cancel, timeouts, etc.). [raw_error] is truncated
    via [Keeper_types_profile.short_preview]. *)
val registry_failure_reason_of_terminal_reason :
  Keeper_turn_terminal.t ->
  raw_error:string ->
  Keeper_registry.failure_reason option

(** Tracker for matching ToolCalled/ToolCompleted event pairs within a
    single keeper turn. The value is an immutable accumulator; every
    operation returns an updated tracker. *)
type turn_tool_event_tracker

val create_turn_tool_event_tracker : unit -> turn_tool_event_tracker
val turn_tool_event_integrity_error :
  turn_tool_event_tracker -> Agent_sdk.Error.sdk_error option
val committed_mutating_tools_from_events :
  turn_tool_event_tracker -> string list

(** Append [input] to the pending FIFO queue for [tool_name]. Returns the
    updated tracker. *)
val push_turn_tool_input :
  turn_tool_event_tracker -> string -> Yojson.Safe.t -> turn_tool_event_tracker

(** Remove and return the oldest pending input for [tool_name], or [None]
    if the queue is empty. Returns the updated tracker as the second
    component. *)
val pop_turn_tool_input :
  turn_tool_event_tracker -> string -> Yojson.Safe.t option * turn_tool_event_tracker

(** Record an unmatched [ToolCompleted] (no prior [ToolCalled]) into the
    tracker. Logs an integrity error via [Log.Keeper.error], appends to
    the committed mutating tools when [tool_committed] AND the tool has a
    mutating side-effect, and stores the first observed integrity error.
    Returns the updated tracker. *)
val record_unmatched_tool_completed :
  turn_tool_event_tracker ->
  keeper_name:string ->
  tool_name:string ->
  outcome:string ->
  tool_committed:bool ->
  turn_tool_event_tracker

(** Drive the tracker over a batch of [Agent_sdk.Event_bus.event]s,
    matching [ToolCalled] <-> [ToolCompleted] pairs and recording
    integrity violations + committed mutating tools. Returns the updated
    tracker. *)
val record_turn_tool_events :
  ?has_mutating_side_effect_with_input:(tool_name:string -> input:Yojson.Safe.t -> bool) ->
  keeper_name:string ->
  turn_tool_event_tracker ->
  Agent_sdk.Event_bus.event list ->
  turn_tool_event_tracker

(** Record the observation for a streaming turn cancelled externally.
    Reads the fiber_stop flag from [Keeper_registry], emits FSM
    transitions, and writes a terminal observation via
    [Keeper_turn_helpers.record_pre_dispatch_terminal_observation].

    [cancel_reason] overrides the inferred reason when provided:
      - ["attempt_watchdog_safety_deadline"] — legacy watchdog timeout receipt
      - ["supervisor_stop"] — supervisor requested stop
      - ["external_cancel"] — external fiber cancellation (default) *)
val record_streaming_cancelled_observation :
  ?cancel_reason:string ->
  config:Workspace.config ->
  run_meta:Keeper_meta_contract.keeper_meta ->
  run_generation:int ->
  runtime_id:string ->
  keeper_turn_id:int ->
  unit ->
  unit
