(** Keeper_unified_turn_types — pure helpers extracted from
    Keeper_unified_turn (3020 LoC godfile).

    Holds [unit -> Yojson] and JSON projection helpers used by the
    unified keeper turn loop. State-touching orchestration stays in
    Keeper_unified_turn. Re-included by it so existing callers continue
    to use [Keeper_unified_turn.<name>] unchanged. *)

val json_of_string_opt : string option -> Yojson.Safe.t

val turn_event_bus_manifest_decision :
  Keeper_turn_cascade_budget.turn_event_bus_summary -> Yojson.Safe.t
