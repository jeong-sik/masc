type event_kind =
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

type links = {
  receipt_path : string option;
  checkpoint_path : string option;
  tool_call_log_path : string option;
}
type t = {
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

(** Identity retained for a validated persisted row with an unsupported event. *)
type row_identity = {
  keeper_name : string;
  trace_id : string;
  keeper_turn_id : int option;
}

(** Result of decoding the durable wire envelope. Both constructors have
    passed schema and common-field validation; only [Active_row] is accepted
    by current producer-facing APIs. *)
type decoded_row =
  | Active_row of t
  | Unsupported_row of row_identity * string

type turn_context = {
  manifest_keeper_name : string;
  manifest_trace_id : string;
  manifest_keeper_turn_id : int option;
}
