(** Setup helpers consumed by the dashboard route builder. *)

module Http = Http_server_eio
module Provider_logs = Server_routes_http_dashboard_provider_logs
module Keeper_api = Server_dashboard_http_keeper_api

val dashboard_logs_store_path : masc_root:string -> string
val dashboard_logs_json :
  config:Workspace.config ->
  limit:int ->
  level_filter:string ->
  applied_level:Log.level ->
  min_level:int ->
  module_filter:string ->
  since_seq:int option ->
  before_seq:int option ->
  category_filter:string option ->
  exclude_category:string list option ->
  Log.Ring.entry list ->
  Yojson.Safe.t

val trimmed_query_param : Httpun.Request.t -> string -> string option
val oas_telemetry_limit_param : Httpun.Request.t -> int
val oas_telemetry_provider_param : Httpun.Request.t -> string option

(** Effective entry limit for /api/v1/dashboard/telemetry. Absent or
    unparseable [n_param] -> bounded default (windowed vs not); explicit
    n=0 preserved. Exposed for the freeze-guard test. *)
val resolve_telemetry_n : has_time_window:bool -> n_param:string option -> int

val handle_broadcast :
  Mcp_server.server_state -> string -> Httpun.Reqd.t -> string -> unit
val handle_dashboard_link_previews :
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> string -> unit
val handle_dashboard_task_history :
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> unit
val handle_dashboard_workspace :
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> unit
val handle_telemetry : Httpun.Request.t -> Httpun.Reqd.t -> unit
