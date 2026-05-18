(** Runtime-trace summary JSON helpers for keeper dashboard API. *)

val provider_attempts_summary_json :
  Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan ->
  Yojson.Safe.t

val turn_identity_summary_json :
  ?turn_id:int ->
  Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan ->
  Yojson.Safe.t list ->
  Yojson.Safe.t
