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

type telemetry_limit_error =
  | Telemetry_limit_not_an_integer of string
  | Telemetry_limit_not_positive of int
  | Telemetry_limit_exceeds_page_size of
      { requested : int
      ; maximum : int
      }

val telemetry_limit_error_to_string : telemetry_limit_error -> string

(** Effective page size for /api/v1/dashboard/telemetry. Absent [n_param]
    selects the bounded windowed/non-windowed default. A supplied malformed,
    non-positive, or oversized value is an explicit error; unlimited reads and
    silent clamps are not part of the HTTP contract. *)
val resolve_telemetry_n :
  has_time_window:bool ->
  n_param:string option ->
  (int, telemetry_limit_error) result

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
