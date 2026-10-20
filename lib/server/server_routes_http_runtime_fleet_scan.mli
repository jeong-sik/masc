type paused_keeper_scan = {
  names : string list;
  autoboot_enabled_names : string list;
  details : Yojson.Safe.t list;
  read_errors : (string * string) list;
}
val sorted_unique_strings : String.t list -> String.t list
val effective_autoboot_enabled :
  ?profile_snapshot:Keeper_types_profile.keeper_profile_snapshot ->
  Workspace.config ->
  string ->
  Keeper_meta_contract.keeper_meta -> bool
type pause_kind = Keeper_activation_readiness.pause_kind =
  | Active
  | Operator_paused
  | Unclassified_paused

type keeper_meta_reading
val read_keeper_metas :
  ?profile_snapshot:Keeper_types_profile.keeper_profile_snapshot ->
  Workspace.config -> keeper_meta_reading
(** One read of every Keeper's durable metadata for one fleet projection:
    the declared and persisted Keepers, and the registered or queue-holding
    owners. A name in more than one population is read once. The meta scan,
    {!boot_path_bootable_names}, the execution snapshot and the active-task
    bindings answer from it, so across those sections a projection decodes
    each metadata file once and they agree on one observation. Profile
    defaults come from [profile_snapshot] when given, otherwise from each
    Keeper's live profile load. *)

val boot_path_bootable_names : keeper_meta_reading -> string list
(** Declared Keepers the boot path does not exclude and whose profile loads.
    For a reading taken without a profile snapshot ([read_keeper_metas] with
    no [profile_snapshot]) this is the set [Keeper_runtime.bootable_keeper_names]
    answers, in sorted order; with a snapshot the profiles come from it
    instead of each Keeper's live load. Unlike the meta scan's
    [bootable_names], a Keeper whose metadata file is unreadable counts only
    when its profile loads. *)

val pause_kind : Keeper_meta_contract.keeper_meta -> pause_kind
val pause_kind_to_wire : pause_kind -> string
val registry_paused_keeper_names : unit -> String.t list
val empty_paused_keeper_scan : paused_keeper_scan
val paused_keepers_health_json_of_scan :
  registry_paused_names:String.t list ->
  paused_keeper_scan ->
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
  keeper_meta_reading -> keeper_fleet_meta_scan
val keeper_identity_drift_health_json : Workspace.config -> Yojson.Safe.t
type keeper_phase_counts = {
  running : int;
  failing : int;
  recovering : int;
}
type keeper_phase_snapshot = {
  counts : keeper_phase_counts;
  running_names : string list;
  recovering_names : string list;
  configuration_blocked_names : string list;
  official_client_recovery_required_names : string list;
}
val keeper_phase_snapshot : ?base_path:string -> unit -> keeper_phase_snapshot
val keeper_phase_counts : ?base_path:string -> unit -> keeper_phase_counts
type keeper_execution_owner = {
  keeper_name : string;
  truth : Keeper_activation_readiness.owner_execution_truth;
}
type keeper_execution_snapshot = {
  owners : keeper_execution_owner list;
  executable_names : string list;
}
val empty_keeper_execution_snapshot : keeper_execution_snapshot
val keeper_execution_snapshot :
  keeper_meta_reading -> keeper_execution_snapshot
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
  meta_reading:keeper_meta_reading option ->
  bootable_names:string list ->
  autoboot_scan:autoboot_keeper_scan ->
  ?phase_snapshot:keeper_phase_snapshot ->
  execution_snapshot:keeper_execution_snapshot ->
  ?base_path:string ->
  ?reaction_capacity_names:string list ->
  ?keeper_bootstrap_enabled:bool ->
  phase_counts:keeper_phase_counts ->
  paused_keepers_json:Yojson.Safe.t ->
  unit ->
  Yojson.Safe.t
(** The active-task owner scan answers from [meta_reading]. [None] is a
    server with no workspace state, which has no backlog to scan. *)
