(** Runtime-lens gap rendering and swimlane helpers. *)

type runtime_lens_gap =
  { code : string
  ; severity : string
  ; lane : string
  ; detail : string option
  }

val runtime_lens_gap_json : runtime_lens_gap -> Yojson.Safe.t

val runtime_lens_gap_codes_for_lane :
  runtime_lens_gap list -> string -> string list

val runtime_lens_event_count :
  Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan ->
  Keeper_runtime_manifest.event_kind ->
  int

val runtime_lens_events_json :
  Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan ->
  Keeper_runtime_manifest.event_kind list ->
  Yojson.Safe.t

val runtime_lens_swimlane_json :
  Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan ->
  runtime_lens_gap list ->
  lane:string ->
  label:string ->
  events:Keeper_runtime_manifest.event_kind list ->
  terminal_status:string ->
  Yojson.Safe.t

val runtime_lens_keeper_terminal_status :
  terminal_event_present:bool ->
  Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan ->
  string

val runtime_lens_provider_terminal_status :
  Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan -> string

val runtime_lens_memory_terminal_status :
  Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan -> string

type lane_policy =
  { lane : string
  ; mandatory_events : Keeper_runtime_manifest.event_kind list
  ; terminal_events : Keeper_runtime_manifest.event_kind list
  }

val lane_policies : lane_policy list
val event_lane : Keeper_runtime_manifest.event_kind -> string
val lane_mandatory_event_codes : string -> string list
val lane_terminal_event_codes : string -> string list
val lane_mandatory_events_present :
  Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan -> string -> bool
val lane_terminal_event_present :
  Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan -> string -> bool
val runtime_lens_swimlane_completeness :
  Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan -> string -> string
