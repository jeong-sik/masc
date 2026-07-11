type paused_keeper_scan = {
  names : string list;
  autoboot_enabled_names : string list;
  details : Yojson.Safe.t list;
  read_errors : (string * string) list;
}
val empty_paused_keeper_scan : paused_keeper_scan
val sorted_unique_strings : String.t list -> String.t list
val effective_autoboot_enabled :
  Workspace.config ->
  string ->
  Keeper_meta_contract.keeper_meta -> bool
val pause_elapsed_sec :
  float ->
  Keeper_meta_contract.keeper_meta -> float option
type pause_kind = Keeper_activation_readiness.pause_kind =
  | Active
  | Reconcile_gated
  | Auto_recoverable
  | Operator_paused
  | Latched_paused
  | Unclassified_paused
  | Dead_tombstone

val pause_kind : Keeper_meta_contract.keeper_meta -> pause_kind
val pause_kind_to_wire : pause_kind -> string
val pause_auto_resume_source :
  Keeper_meta_contract.keeper_meta ->
  string option
val paused_keeper_detail_json :
  now:float ->
  name:string ->
  autoboot_enabled:bool ->
  Keeper_meta_contract.keeper_meta ->
  [> `Assoc of (string * Yojson.Safe.t) list ]
val registry_paused_keeper_names : unit -> String.t list
val running_paused_keeper_names : unit -> String.t list
val durable_paused_keeper_scan :
  ?include_details:bool -> Workspace.config -> paused_keeper_scan
val paused_keepers_health_json_of_scan :
  running_names:String.t list ->
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
val sort_paused_keeper_details :
  ([> `Assoc of (string * [> `String of String.t ]) list ] as 'a) list ->
  'a list
val keeper_fleet_meta_scan :
  ?include_paused_details:bool ->
  Workspace.config -> keeper_fleet_meta_scan
val configured_keeper_is_materializable : Workspace.config -> string -> bool
val keeper_identity_drift_scan : Workspace.config -> keeper_identity_drift_scan
val keeper_identity_drift_health_json_of_scan :
  keeper_identity_drift_scan -> Yojson.Safe.t
val keeper_identity_drift_health_json : Workspace.config -> Yojson.Safe.t
val autoboot_enabled_keeper_scan :
  Workspace.config -> autoboot_keeper_scan
type keeper_phase_counts = {
  running : int;
  failing : int;
  recovering : int;
  executable : int;
}
type keeper_phase_detail = {
  phase : string;
  last_failure_reason : string option;
  last_error : string option;
  restart_count : int;
  dead_since_ts : float option;
  latest_crash_at : float option;
  latest_crash_reason : string option;
}
type keeper_phase_snapshot = {
  counts : keeper_phase_counts;
  running_names : string list;
  recovering_names : string list;
  executable_names : string list;
  phase_values : (string * Keeper_state_machine.phase) list;
  phase_details : (string * keeper_phase_detail) list;
}
val keeper_phase_snapshot : ?base_path:string -> unit -> keeper_phase_snapshot
val keeper_phase_counts : ?base_path:string -> unit -> keeper_phase_counts
val active_task_owner_fiber_scan_semantics : string
val keeper_fleet_safety_health_json :
  ?bootable_names:string list ->
  ?autoboot_scan:autoboot_keeper_scan ->
  ?phase_snapshot:keeper_phase_snapshot ->
  ?base_path:string ->
  ?reaction_capacity_names:string list ->
  ?keeper_bootstrap_enabled:bool ->
  phase_counts:keeper_phase_counts ->
  paused_keepers_json:Yojson.Safe.t ->
  unit ->
  Yojson.Safe.t
