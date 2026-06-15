(** Keeper_unified_turn_types — pure helpers extracted from
    Keeper_unified_turn (3020 LoC godfile).

    Holds [unit -> Yojson] and JSON projection helpers used by the
    unified keeper turn loop. State-touching orchestration stays in
    Keeper_unified_turn. Re-included by it so existing callers continue
    to use [Keeper_unified_turn.<name>] unchanged. *)

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
    single keeper turn. *)
type turn_tool_event_tracker = {
  pending_tool_inputs : (string, Yojson.Safe.t Queue.t) Hashtbl.t;
  mutable mutating_tools_committed : string list;
  mutable integrity_error : Agent_sdk.Error.sdk_error option;
}

val create_turn_tool_event_tracker : unit -> turn_tool_event_tracker
val turn_tool_event_integrity_error :
  turn_tool_event_tracker -> Agent_sdk.Error.sdk_error option
val committed_mutating_tools_from_events :
  turn_tool_event_tracker -> string list
val push_turn_tool_input :
  turn_tool_event_tracker -> string -> Yojson.Safe.t -> unit
val pop_turn_tool_input :
  turn_tool_event_tracker -> string -> Yojson.Safe.t option

(** Record an unmatched [ToolCompleted] (no prior [ToolCalled]) into the
    tracker. Logs an integrity error via [Log.Keeper.error], appends to
    [tracker.mutating_tools_committed] when [tool_committed] AND the tool
    has a mutating side-effect, and stores the first observed integrity
    error in [tracker.integrity_error]. *)
val record_unmatched_tool_completed :
  turn_tool_event_tracker ->
  keeper_name:string ->
  tool_name:string ->
  outcome:string ->
  tool_committed:bool ->
  unit

(** Drive the tracker over a batch of [Agent_sdk.Event_bus.event]s,
    matching [ToolCalled] <-> [ToolCompleted] pairs and recording
    integrity violations + committed mutating tools. *)
val record_turn_tool_events :
  ?has_mutating_side_effect_with_input:(tool_name:string -> input:Yojson.Safe.t -> bool) ->
  keeper_name:string ->
  turn_tool_event_tracker ->
  Agent_sdk.Event_bus.event list ->
  unit

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
