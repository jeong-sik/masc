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
  Log.Ring.entry list ->
  Yojson.Safe.t

val trimmed_query_param : Httpun.Request.t -> string -> string option
val oas_telemetry_limit_param : Httpun.Request.t -> int
val oas_telemetry_provider_param : Httpun.Request.t -> string option

val dashboard_dev_token_path : string -> string
val ensure_dashboard_dev_token : string -> (string, string) result

val handle_broadcast :
  Mcp_server.server_state -> string -> Httpun.Reqd.t -> string -> unit
val handle_dashboard_link_previews :
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> string -> unit
val handle_dashboard_task_history :
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> unit
val handle_dashboard_workspace :
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> unit
val handle_telemetry : Httpun.Request.t -> Httpun.Reqd.t -> unit
