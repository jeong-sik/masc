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
