(** Manifest event kind type and serialization.

    Extracted from [keeper_runtime_manifest.ml] to break the cycle
    with [keeper_runtime_manifest_housekeeping.ml]. Both modules
    include this one; external callers still access the type as
    [Keeper_runtime_manifest.event_kind]. *)

type event_kind =
  | Turn_started
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

let all_event_kinds =
  [
    Turn_started;
    Phase_gate_decided;
    Runtime_routed;
    Runtime_execution_built;
    Runtime_completed;
    Runtime_failed;
    Pre_dispatch_blocked;
    Provider_lane_resolved;
    Provider_attempt_started;
    Provider_attempt_finished;
    Context_injected;
    Context_compacted;
    Event_bus_correlated;
    Checkpoint_loaded;
    Checkpoint_saved;
    Receipt_appended;
    Turn_finished;
  ]

let event_kind_to_string = function
  | Turn_started -> "turn_started"
  | Phase_gate_decided -> "phase_gate_decided"
  | Runtime_routed -> "runtime_routed"
  | Runtime_execution_built -> "runtime_execution_built"
  | Runtime_completed -> "runtime_completed"
  | Runtime_failed -> "runtime_failed"
  | Pre_dispatch_blocked -> "pre_dispatch_blocked"
  | Provider_lane_resolved -> "provider_lane_resolved"
  | Provider_attempt_started -> "provider_attempt_started"
  | Provider_attempt_finished -> "provider_attempt_finished"
  | Context_injected -> "context_injected"
  | Context_compacted -> "context_compacted"
  | Event_bus_correlated -> "event_bus_correlated"
  | Checkpoint_loaded -> "checkpoint_loaded"
  | Checkpoint_saved -> "checkpoint_saved"
  | Receipt_appended -> "receipt_appended"
  | Turn_finished -> "turn_finished"

let event_kind_of_string = function
  | "turn_started" -> Some Turn_started
  | "phase_gate_decided" -> Some Phase_gate_decided
  | "runtime_routed" -> Some Runtime_routed
  | "runtime_execution_built" -> Some Runtime_execution_built
  | "runtime_completed" -> Some Runtime_completed
  | "runtime_failed" -> Some Runtime_failed
  | "pre_dispatch_blocked" -> Some Pre_dispatch_blocked
  | "provider_lane_resolved" -> Some Provider_lane_resolved
  | "provider_attempt_started" -> Some Provider_attempt_started
  | "provider_attempt_finished" -> Some Provider_attempt_finished
  | "context_injected" -> Some Context_injected
  | "context_compacted" -> Some Context_compacted
  | "event_bus_correlated" -> Some Event_bus_correlated
  | "checkpoint_loaded" -> Some Checkpoint_loaded
  | "checkpoint_saved" -> Some Checkpoint_saved
  | "receipt_appended" -> Some Receipt_appended
  | "turn_finished" -> Some Turn_finished
  | _ -> None

(** Event kinds that were valid in persisted schema-v1 manifests but whose
    producers and product behavior have been retired. Keeping them outside
    [event_kind] makes it impossible for current manifest producers to emit a
    retired row while preserving a typed read boundary for durable history. *)
type retired_event_kind =
  | Memory_injected
  | Memory_flushed
  | Tool_lineage_recorded
  | Tool_surface_selected
  | Cascade_routed
  | State_snapshot_sidecar_saved
  | Working_state_sidecar_saved

let all_retired_event_kinds =
  [ Memory_injected
  ; Memory_flushed
  ; Tool_lineage_recorded
  ; Tool_surface_selected
  ; Cascade_routed
  ; State_snapshot_sidecar_saved
  ; Working_state_sidecar_saved
  ]
;;

let retired_event_kind_to_string = function
  | Memory_injected -> "memory_injected"
  | Memory_flushed -> "memory_flushed"
  | Tool_lineage_recorded -> "tool_lineage_recorded"
  | Tool_surface_selected -> "tool_surface_selected"
  | Cascade_routed -> "cascade_routed"
  | State_snapshot_sidecar_saved -> "state_snapshot_sidecar_saved"
  | Working_state_sidecar_saved -> "working_state_sidecar_saved"
;;

let retired_event_kind_of_string value =
  List.find_opt
    (fun event -> String.equal value (retired_event_kind_to_string event))
    all_retired_event_kinds
;;

type event_wire_class =
  | Active_event of event_kind
  | Retired_event of retired_event_kind
  | Unsupported_event of string

let classify_event_wire value =
  match event_kind_of_string value with
  | Some event -> Active_event event
  | None ->
    (match retired_event_kind_of_string value with
     | Some event -> Retired_event event
     | None -> Unsupported_event value)
;;

type compaction_snapshot_event_class =
  | Compaction_snapshot_relevant
  | Compaction_snapshot_known_unrelated
  | Compaction_snapshot_unknown

let known_unrelated_untyped_compaction_snapshot_events =
  List.map retired_event_kind_to_string all_retired_event_kinds
;;

let classify_compaction_snapshot_typed_event = function
  | Event_bus_correlated
  | Context_compacted
  | Context_injected
  | Checkpoint_loaded ->
    Compaction_snapshot_relevant
  | Turn_started
  | Phase_gate_decided
  | Runtime_routed
  | Runtime_execution_built
  | Runtime_completed
  | Runtime_failed
  | Pre_dispatch_blocked
  | Provider_lane_resolved
  | Provider_attempt_started
  | Provider_attempt_finished
  | Checkpoint_saved
  | Receipt_appended
  | Turn_finished ->
      Compaction_snapshot_known_unrelated

let classify_compaction_snapshot_event event =
  match classify_event_wire event with
  | Active_event typed_event -> classify_compaction_snapshot_typed_event typed_event
  | Retired_event _ -> Compaction_snapshot_known_unrelated
  | Unsupported_event _ -> Compaction_snapshot_unknown

(* ── Record types ────────────────────────────────────────────────────── *)

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

type row_identity = {
  keeper_name : string;
  trace_id : string;
  keeper_turn_id : int option;
}

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
