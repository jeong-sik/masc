(** Memory subsystem dashboard HTTP JSON helpers. *)

val dashboard_memory_subsystems_include_entries :
  Httpun.Request.t -> bool

val dashboard_memory_subsystems_http_json :
  config:Coord_utils.config ->
  ?include_memory_entries:bool ->
  Httpun.Request.t ->
  Yojson.Safe.t
