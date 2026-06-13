(** Runtime-lens gap detection. *)

val runtime_lens_gaps :
  terminal_event_present:bool ->
  claim_scope:Yojson.Safe.t ->
  config_drift:Yojson.Safe.t ->
  Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan ->
  Server_dashboard_http_keeper_runtime_lens_swimlane.runtime_lens_gap list
