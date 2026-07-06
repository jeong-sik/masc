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
  | Provider_attempt_started
  | Provider_attempt_finished
  | Context_injected
  | Context_compacted
  | State_snapshot_sidecar_saved
  | Working_state_sidecar_saved
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
  agent_name : string option;
  trace_id : string;
  generation : int option;
  keeper_turn_id : int option;
  oas_turn_count : int option;
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
  manifest_agent_name : string option;
  manifest_trace_id : string;
  manifest_generation : int option;
  manifest_keeper_turn_id : int option;
}
val retention_days : unit -> int option
val prune_mu : Mutex.t
val last_prune_day_by_base_dir : (string, string) Hashtbl.t
val today_key : unit -> string
val is_runtime_manifest_file : String.t -> bool
val prune_old_trace_files : base_dir:string -> days:int -> int
val maybe_prune_retention : base_dir:string -> unit
val mandatory_clock_refs_for_event : event_kind -> string list
val clock_refs_has_keys :
  String.t list -> [> `Assoc of (String.t * 'a) list ] -> bool
val validate_manifest_completeness : t -> (unit, string) result
val is_finished_turn : t list -> bool
val is_complete_turn : t list -> bool
