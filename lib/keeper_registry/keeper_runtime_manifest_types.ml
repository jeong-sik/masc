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
  | Context_injected
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
    Context_injected;
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
  | Context_injected -> "context_injected"
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
  | "context_injected" -> Some Context_injected
  | "event_bus_correlated" -> Some Event_bus_correlated
  | "checkpoint_loaded" -> Some Checkpoint_loaded
  | "checkpoint_saved" -> Some Checkpoint_saved
  | "receipt_appended" -> Some Receipt_appended
  | "turn_finished" -> Some Turn_finished
  | _ -> None

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

type row_identity = {
  keeper_name : string;
  trace_id : string;
  keeper_turn_id : int option;
}

type decoded_row =
  | Active_row of t
  | Unsupported_row of row_identity * string

type turn_context = {
  manifest_keeper_name : string;
  manifest_trace_id : string;
  manifest_keeper_turn_id : int option;
}
