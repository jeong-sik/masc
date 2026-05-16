(** Keeper_unified_turn_types — pure helpers extracted from
    Keeper_unified_turn (3020 LoC godfile).

    Holds [unit -> Yojson] and JSON projection helpers used by the
    unified keeper turn loop. State-touching orchestration stays in
    Keeper_unified_turn. Re-included by it so existing callers continue
    to use [Keeper_unified_turn.<name>] unchanged. *)

val json_of_string_opt : string option -> Yojson.Safe.t

val turn_event_bus_manifest_decision :
  Keeper_turn_cascade_budget.turn_event_bus_summary -> Yojson.Safe.t

val should_auto_pause_required_tool_contract_violation :
  paused:bool ->
  consecutive_failures:int ->
  Agent_sdk.Error.sdk_error ->
  bool

val sdk_error_of_retry_slot_reacquire_timeout :
  keeper_name:string ->
  Keeper_turn_slot.semaphore_wait_timeout ->
  Agent_sdk.Error.sdk_error

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
