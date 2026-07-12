type event_kind =
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
  | Event_bus_correlated
  | Checkpoint_loaded
  | Checkpoint_saved
  | Receipt_appended
  | Turn_finished
val all_event_kinds : event_kind list
val event_kind_to_string : event_kind -> string
val event_kind_of_string : string -> event_kind option

(** Persisted schema-v1 events whose producers are no longer part of the
    active product. They are decode-only and cannot be passed to
    [Keeper_runtime_manifest.make]. *)
type retired_event_kind =
  | Memory_injected
  | Memory_flushed
  | Tool_lineage_recorded
  | Tool_surface_selected
  | Cascade_routed
  | State_snapshot_sidecar_saved
  | Working_state_sidecar_saved

val all_retired_event_kinds : retired_event_kind list
val retired_event_kind_to_string : retired_event_kind -> string
val retired_event_kind_of_string : string -> retired_event_kind option

type event_wire_class =
  | Active_event of event_kind
  | Retired_event of retired_event_kind
  | Unsupported_event of string

(** Classify a manifest event wire once at the persistence boundary. Current
    producers consume only [event_kind]; readers can observe retired and
    genuinely unsupported wires without reintroducing their behavior. *)
val classify_event_wire : string -> event_wire_class

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

(** Identity retained for validated persisted rows whose event is no longer
    constructible as an active [t]. *)
type row_identity = {
  keeper_name : string;
  trace_id : string;
  keeper_turn_id : int option;
}

(** Result of decoding the durable wire envelope. All three constructors have
    passed schema and common-field validation; only [Active_row] is accepted
    by current producer-facing APIs. *)
type decoded_row =
  | Active_row of t
  | Retired_row of row_identity * retired_event_kind
  | Unsupported_row of row_identity * string

type turn_context = {
  manifest_keeper_name : string;
  manifest_agent_name : string option;
  manifest_trace_id : string;
  manifest_generation : int option;
  manifest_keeper_turn_id : int option;
}
