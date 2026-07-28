(** Memory subsystem dashboard HTTP JSON helpers. *)

val dashboard_memory_subsystems_http_json :
  config:Workspace_utils.config ->
  Httpun.Request.t ->
  Yojson.Safe.t
