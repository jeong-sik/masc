(** Runtime-lens tool surface extraction and gap detection. *)

val runtime_lens_tool_surface_parts :
  Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan ->
  Yojson.Safe.t
  * Yojson.Safe.t
  * string list
  * string list
  * string list
  * string list

val runtime_lens_gaps :
  terminal_event_present:bool ->
  claim_scope:Yojson.Safe.t ->
  config_drift:Yojson.Safe.t ->
  Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan ->
  Server_dashboard_http_keeper_runtime_lens_swimlane.runtime_lens_gap list
