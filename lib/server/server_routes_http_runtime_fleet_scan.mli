type paused_keeper_scan = {
  names : string list;
  autoboot_enabled_names : string list;
  details : Yojson.Safe.t list;
  read_errors : (string * string) list;
}
val empty_paused_keeper_scan : paused_keeper_scan
val sorted_unique_strings : String.t list -> String.t list
val json_float_opt : 'a option -> [> `Float of 'a | `Null ]
val json_string_opt : 'a option -> [> `Null | `String of 'a ]
val effective_autoboot_enabled :
  string ->
  Server_routes_http_common.Keeper_types.keeper_meta -> bool
val pause_elapsed_sec :
  float ->
  Server_routes_http_common.Keeper_types.keeper_meta -> float option
val pause_kind :
  Server_routes_http_common.Keeper_types.keeper_meta -> string
val pause_auto_resume_source :
  Server_routes_http_common.Keeper_types.keeper_meta ->
  string option
val paused_keeper_detail_json :
  now:float ->
  name:string ->
  autoboot_enabled:bool ->
  Server_routes_http_common.Keeper_types.keeper_meta ->
  [> `Assoc of (string * Yojson.Safe.t) list ]
val running_paused_keeper_names : unit -> String.t list
val durable_paused_keeper_scan :
  ?include_details:bool -> Coord.config -> paused_keeper_scan
val paused_keepers_health_json_of_scan :
  running_names:String.t list ->
  paused_keeper_scan ->
  [> `Assoc of (string * [> `Int of int | `List of Yojson.Safe.t list ]) list
  ]
val paused_keepers_health_json :
  unit ->
  [> `Assoc of (string * [> `Int of int | `List of Yojson.Safe.t list ]) list
  ]
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
  Coord.config -> keeper_fleet_meta_scan
val autoboot_enabled_keeper_scan :
  Coord.config -> autoboot_keeper_scan
type keeper_phase_counts = {
  running : int;
  failing : int;
  recovering : int;
  executable : int;
}
val keeper_phase_counts : ?base_path:string -> unit -> keeper_phase_counts
val keeper_fleet_safety_health_json :
  ?bootable_names:string list ->
  ?autoboot_scan:autoboot_keeper_scan ->
  phase_counts:keeper_phase_counts ->
  paused_keepers_json:[> `Assoc of (string * [> `Int of int ]) list ] ->
  unit ->
  [> `Assoc of
       (string *
        [> `Bool of bool
         | `Int of int
         | `List of
             [> `Assoc of (string * [> `String of string ]) list
              | `String of string ]
             list
         | `Null
         | `String of string ])
       list ]
