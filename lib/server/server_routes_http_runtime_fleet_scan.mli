type paused_keeper_scan = {
  names : string list;
  autoboot_enabled_names : string list;
  details : Yojson.Safe.t list;
  read_errors : (string * string) list;
}
val empty_paused_keeper_scan : paused_keeper_scan
val sorted_unique_strings : String.t list -> String.t list
val effective_autoboot_enabled :
  string ->
  Keeper_meta_contract.keeper_meta -> bool
val pause_elapsed_sec :
  float ->
  Keeper_meta_contract.keeper_meta -> float option
val pause_kind :
  Keeper_meta_contract.keeper_meta -> string
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
val sort_paused_keeper_details :
  ([> `Assoc of (string * [> `String of String.t ]) list ] as 'a) list ->
  'a list
val keeper_fleet_meta_scan :
  ?include_paused_details:bool ->
  Workspace.config -> keeper_fleet_meta_scan
val autoboot_enabled_keeper_scan :
  Workspace.config -> autoboot_keeper_scan
type keeper_phase_counts = {
  running : int;
  failing : int;
  recovering : int;
  executable : int;
}
type keeper_phase_snapshot = {
  counts : keeper_phase_counts;
  running_names : string list;
  recovering_names : string list;
  executable_names : string list;
}
val keeper_phase_snapshot : ?base_path:string -> unit -> keeper_phase_snapshot
val keeper_phase_counts : ?base_path:string -> unit -> keeper_phase_counts
val keeper_fleet_safety_health_json :
  ?bootable_names:string list ->
  ?autoboot_scan:autoboot_keeper_scan ->
  ?phase_snapshot:keeper_phase_snapshot ->
  phase_counts:keeper_phase_counts ->
  paused_keepers_json:Yojson.Safe.t ->
  unit ->
  Yojson.Safe.t
