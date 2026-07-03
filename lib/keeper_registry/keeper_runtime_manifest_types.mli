type event_kind =
    Turn_started
  | Phase_gate_decided
  | Runtime_routed
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

type compaction_snapshot_event_class =
  | Compaction_snapshot_relevant
  | Compaction_snapshot_known_unrelated
  | Compaction_snapshot_unknown

val known_unrelated_untyped_compaction_snapshot_events : string list
val classify_compaction_snapshot_event : string -> compaction_snapshot_event_class

type links = {
  receipt_path : string option;
  checkpoint_path : string option;
  tool_call_log_path : string option;
}
type t = {
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
type turn_context = {
  manifest_keeper_name : string;
  manifest_agent_name : string option;
  manifest_trace_id : string;
  manifest_generation : int option;
  manifest_keeper_turn_id : int option;
}
