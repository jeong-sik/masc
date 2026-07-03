(** Manifest event kind type and serialization.

    Extracted from [keeper_runtime_manifest.ml] to break the cycle
    with [keeper_runtime_manifest_housekeeping.ml]. Both modules
    include this one; external callers still access the type as
    [Keeper_runtime_manifest.event_kind]. *)

type event_kind =
  | Turn_started
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

let all_event_kinds =
  [
    Turn_started;
    Phase_gate_decided;
    Runtime_routed;
    Runtime_completed;
    Runtime_failed;
    Pre_dispatch_blocked;
    Provider_lane_resolved;
    Provider_attempt_started;
    Provider_attempt_finished;
    Context_injected;
    Context_compacted;
    State_snapshot_sidecar_saved;
    Working_state_sidecar_saved;
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
  | Runtime_completed -> "runtime_completed"
  | Runtime_failed -> "runtime_failed"
  | Pre_dispatch_blocked -> "pre_dispatch_blocked"
  | Provider_lane_resolved -> "provider_lane_resolved"
  | Provider_attempt_started -> "provider_attempt_started"
  | Provider_attempt_finished -> "provider_attempt_finished"
  | Context_injected -> "context_injected"
  | Context_compacted -> "context_compacted"
  | State_snapshot_sidecar_saved -> "state_snapshot_sidecar_saved"
  | Working_state_sidecar_saved -> "working_state_sidecar_saved"
  | Event_bus_correlated -> "event_bus_correlated"
  | Checkpoint_loaded -> "checkpoint_loaded"
  | Checkpoint_saved -> "checkpoint_saved"
  | Receipt_appended -> "receipt_appended"
  | Turn_finished -> "turn_finished"

let event_kind_of_string = function
  | "turn_started" -> Some Turn_started
  | "phase_gate_decided" -> Some Phase_gate_decided
  | "runtime_routed" -> Some Runtime_routed
  | "runtime_completed" -> Some Runtime_completed
  | "runtime_failed" -> Some Runtime_failed
  | "pre_dispatch_blocked" -> Some Pre_dispatch_blocked
  | "provider_lane_resolved" -> Some Provider_lane_resolved
  | "provider_attempt_started" -> Some Provider_attempt_started
  | "provider_attempt_finished" -> Some Provider_attempt_finished
  | "context_injected" -> Some Context_injected
  | "context_compacted" -> Some Context_compacted
  | "state_snapshot_sidecar_saved" -> Some State_snapshot_sidecar_saved
  | "working_state_sidecar_saved" -> Some Working_state_sidecar_saved
  | "event_bus_correlated" -> Some Event_bus_correlated
  | "checkpoint_loaded" -> Some Checkpoint_loaded
  | "checkpoint_saved" -> Some Checkpoint_saved
  | "receipt_appended" -> Some Receipt_appended
  | "turn_finished" -> Some Turn_finished
  | _ -> None

type compaction_snapshot_event_class =
  | Compaction_snapshot_relevant
  | Compaction_snapshot_known_unrelated
  | Compaction_snapshot_unknown

let known_unrelated_untyped_compaction_snapshot_events =
  [ "memory_injected"
  ; "memory_flushed"
  ; "tool_lineage_recorded"
  ; "tool_surface_selected"
  ; "cascade_routed"
  ]
;;

let is_known_unrelated_untyped_compaction_snapshot_event event =
  List.exists
    (String.equal event)
    known_unrelated_untyped_compaction_snapshot_events
;;

let classify_compaction_snapshot_typed_event = function
  | Event_bus_correlated | Context_compacted -> Compaction_snapshot_relevant
  | Turn_started
  | Phase_gate_decided
  | Runtime_routed
  | Runtime_completed
  | Runtime_failed
  | Pre_dispatch_blocked
  | Provider_lane_resolved
  | Provider_attempt_started
  | Provider_attempt_finished
  | Context_injected
  | State_snapshot_sidecar_saved
  | Working_state_sidecar_saved
  | Checkpoint_loaded
  | Checkpoint_saved
  | Receipt_appended
  | Turn_finished ->
      Compaction_snapshot_known_unrelated

let classify_compaction_snapshot_event event =
  if is_known_unrelated_untyped_compaction_snapshot_event event
  then Compaction_snapshot_known_unrelated
  else (
    match event_kind_of_string event with
    | Some typed_event -> classify_compaction_snapshot_typed_event typed_event
    | None -> Compaction_snapshot_unknown)

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

type turn_context = {
  manifest_keeper_name : string;
  manifest_agent_name : string option;
  manifest_trace_id : string;
  manifest_generation : int option;
  manifest_keeper_turn_id : int option;
}
