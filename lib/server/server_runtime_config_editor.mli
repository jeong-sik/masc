(** Server_runtime_config_editor — what the Setup routes and the runtime
    config routes share when they write runtime.toml. *)

(** What one runtime.toml write was. The audit row records it and the commit
    answer names it. *)
type runtime_config_write_operation =
  | Runtime_config_raw_save
  | Runtime_config_routing of
      Server_dashboard_runtime_request.runtime_route_lane * string option
  | Runtime_config_routing_list of
      Server_dashboard_runtime_request.runtime_route_lane * string list
  | Runtime_config_lane_created of string * string list
  | Runtime_config_lane_removed of string
  | Runtime_config_lane_renamed of string * string
  | Runtime_config_exact_slot_appended of Runtime.exact_lane * string
  | Runtime_config_exact_slot_dropped of Runtime.exact_lane * string
  | Runtime_config_exact_slot_replaced of Runtime.exact_lane * string * string
  | Runtime_config_exact_slot_moved of
      Runtime.exact_lane * string * Runtime.exact_slot_move
  | Runtime_config_assignment of string * string option
  | Runtime_config_fusion of string
  | Runtime_config_account_removal of string
  | Runtime_config_tui_preference of Tui_preference.change

val runtime_config_raw_json :
  ?commit:Runtime.config_commit_receipt ->
  ?skill_application:
    ( Server_skill_snapshot_runtime.commit_application
    , Server_skill_snapshot_runtime.error )
    result ->
  source_revision:Runtime.config_source_revision ->
  path:string ->
  source_text:string ->
  operation:string ->
  routing_applied_at:string option ->
  unit ->
  Yojson.Safe.t
(** The runtime.toml editor payload: the source text with its revision and
    path, the validation report, the Keeper settings and the provider
    protocols. The preparation runs as an IO job; the caller writes the
    response. With [commit] the payload also carries the commit receipt. *)

val audit_runtime_config_write :
  Mcp_server.server_state ->
  string ->
  ?path:string ->
  ?receipt:Runtime.config_commit_receipt ->
  ?skill_application:
    ( Server_skill_snapshot_runtime.commit_application
    , Server_skill_snapshot_runtime.error )
    result ->
  operation:runtime_config_write_operation ->
  text:string ->
  outcome:Audit_log.outcome ->
  unit ->
  unit
(** Append the [RuntimeConfigWrite] audit row for [operation]. Of [text] the
    row carries the byte and line count only. A failure to write the row is
    logged and not raised. *)

val respond_runtime_config_commit :
  Mcp_server.server_state ->
  string ->
  operation:runtime_config_write_operation ->
  receipt:Runtime.config_commit_receipt ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  unit
(** Answer a committed write: apply the receipt to the Skill snapshot, audit
    the write as a success, and send the editor payload. *)
