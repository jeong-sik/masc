(** Runtime event-bus and memory summary JSON helpers. *)

val event_bus_summary_json :
  Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan ->
  Yojson.Safe.t

val memory_summary_json :
  Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan ->
  Yojson.Safe.t
