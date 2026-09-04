type event_kind =
  Keeper_runtime_manifest_types.event_kind =
    Turn_started
  | Phase_gate_decided
  | Runtime_routed
  | Runtime_execution_built
  | Runtime_completed
  | Runtime_failed
  | Pre_dispatch_blocked
  | Provider_lane_resolved
  | Context_injected
  | Event_bus_correlated
  | Checkpoint_loaded
  | Checkpoint_saved
  | Receipt_appended
  | Turn_finished
val all_event_kinds : event_kind list
val event_kind_to_string : event_kind -> string
val event_kind_of_string : string -> event_kind option
type links =
  Keeper_runtime_manifest_types.links = {
  receipt_path : string option;
  checkpoint_path : string option;
  tool_call_log_path : string option;
}
type t =
  Keeper_runtime_manifest_types.t = {
  schema_version : int;
  ts : string;
  keeper_name : string;
  trace_id : string;
  keeper_turn_id : int option;
  agent_core_turn_count : int option;
  logical_seq : int option;
  event : event_kind;
  runtime_id : string option;
  status : string;
  decision : Yojson.Safe.t;
  links : links;
}
type turn_context =
  Keeper_runtime_manifest_types.turn_context = {
  manifest_keeper_name : string;
  manifest_trace_id : string;
  manifest_keeper_turn_id : int option;
}
val retention_days : unit -> int option
val maybe_prune_retention : base_dir:string -> unit
val mandatory_clock_refs_for_event : event_kind -> string list
val validate_manifest_completeness : t -> (unit, string) result
val is_finished_turn : t list -> bool
val is_complete_turn : t list -> bool
