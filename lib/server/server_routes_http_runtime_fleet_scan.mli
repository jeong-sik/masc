type paused_keeper_scan = {
  names : string list;
  autoboot_enabled_names : string list;
  details : Yojson.Safe.t list;
  read_errors : (string * string) list;
}
val sorted_unique_strings : String.t list -> String.t list
val effective_autoboot_enabled :
  Workspace.config ->
  string ->
  Keeper_meta_contract.keeper_meta -> bool
type pause_kind = Keeper_activation_readiness.pause_kind =
  | Active
  | Operator_paused
  | Unclassified_paused

val pause_kind : Keeper_meta_contract.keeper_meta -> pause_kind
val pause_kind_to_wire : pause_kind -> string
val registry_paused_keeper_names : unit -> String.t list
val paused_keepers_health_json_of_scan :
  registry_paused_names:String.t list ->
  paused_keeper_scan ->
  [> `Assoc of
       (string * [> `Int of int | `List of Yojson.Safe.t list | `String of string ])
       list
  ]
val paused_keepers_health_json :
  unit ->
  [> `Assoc of
       (string * [> `Int of int | `List of Yojson.Safe.t list | `String of string ])
       list
  ]
val running_keeper_names : ?base_path:string -> unit -> String.t list
type autoboot_keeper_scan = {
  autoboot_names : string list;
  read_errors : (string * string) list;
}
val empty_autoboot_keeper_scan : autoboot_keeper_scan
type keeper_fleet_meta_scan = {
  paused_scan : paused_keeper_scan;
  autoboot_scan : autoboot_keeper_scan;
  bootable_names : string list;
}
type keeper_identity_drift_scan = {
  configured_names : string list;
  persisted_meta_names : string list;
  materializable_configured_names : string list;
  configured_without_meta_names : string list;
  meta_without_config_names : string list;
}
val keeper_fleet_meta_scan :
  ?include_paused_details:bool ->
  Workspace.config -> keeper_fleet_meta_scan
val keeper_identity_drift_health_json : Workspace.config -> Yojson.Safe.t
type keeper_phase_counts = {
  running : int;
  failing : int;
  recovering : int;
}
type keeper_phase_detail = {
  phase : string;
  last_failure_reason : string option;
  last_error : string option;
  restart_count : int;
  latest_crash_at : float option;
  latest_crash_reason : string option;
}
type keeper_phase_snapshot = {
  counts : keeper_phase_counts;
  running_names : string list;
  recovering_names : string list;
  configuration_blocked_names : string list;
  phase_values : (string * Keeper_state_machine.phase) list;
  phase_details : (string * keeper_phase_detail) list;
}
val keeper_phase_snapshot : ?base_path:string -> unit -> keeper_phase_snapshot
val keeper_phase_counts : ?base_path:string -> unit -> keeper_phase_counts
type keeper_execution_owner = {
  keeper_name : string;
  truth : Keeper_activation_readiness.owner_execution_truth;
  non_executable_cause : keeper_non_executable_cause option;
}
and keeper_non_executable_cause =
  | Cause_owner_absent_from_snapshot
  | Cause_owner_unregistered
  | Cause_no_keeper_binding
  | Cause_fiber_dead
  | Cause_lane_exited
  | Cause_completion_settled
  | Cause_autoboot_disabled
  | Cause_proactive_disabled
  | Cause_lifecycle_denied
  | Cause_runtime_terminal
  | Cause_shutdown_fenced
  | Cause_metadata_unavailable
  | Cause_runtime_not_live
type keeper_execution_snapshot = {
  owners : keeper_execution_owner list;
  executable_names : string list;
}
val empty_keeper_execution_snapshot : keeper_execution_snapshot
val keeper_execution_snapshot :
  Workspace.config -> keeper_execution_snapshot
(** Canonical per-owner execution projection for one route assembly. Every
    owner is classified once from current effective durable metadata, registry
    runtime facts, and shutdown admission. Metadata read failure is retained as
    that owner's typed [Unknown]. *)
val owner_execution_truth :
  keeper_execution_snapshot ->
  keeper_name:string ->
  Keeper_activation_readiness.owner_execution_truth
val active_task_owner_fiber_scan_semantics : string
val keeper_fleet_safety_health_json :
  ?bootable_names:string list ->
  ?autoboot_scan:autoboot_keeper_scan ->
  ?phase_snapshot:keeper_phase_snapshot ->
  execution_snapshot:keeper_execution_snapshot ->
  ?base_path:string ->
  ?reaction_capacity_names:string list ->
  ?keeper_bootstrap_enabled:bool ->
  phase_counts:keeper_phase_counts ->
  paused_keepers_json:Yojson.Safe.t ->
  unit ->
  Yojson.Safe.t
