(** Keeper HTTP API POST handlers and runtime-trace helpers. *)

module Http = Http_server_eio

include module type of Server_dashboard_http_keeper_api_types

val json_list_length : Yojson.Safe.t -> int
val trajectory_line_ts : Trajectory.trajectory_line -> float
val dedupe_thinking_lines :
  Trajectory.trajectory_line list -> Trajectory.trajectory_line list
val read_internal_history_lines :
  config:Workspace.config -> trace_id:string -> Trajectory.trajectory_line list
val merge_keeper_trace_lines :
  config:Workspace.config ->
  trace_id:string ->
  Trajectory.trajectory_line list ->
  Trajectory.trajectory_line list

val error_json : ?ok:bool -> string -> Yojson.Safe.t
val respond_error :
  ?status:Httpun.Status.t ->
  ?request:Httpun.Request.t ->
  ?ok:bool ->
  Httpun.Reqd.t ->
  string ->
  unit

val handle_keeper_catchup_judge_post :
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> string -> unit

val handle_keeper_chat_recovery_post :
  Mcp_server.server_state ->
  string ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  keeper_name:string ->
  raw_receipt_id:string ->
  string ->
  unit

val stat_json_of_path : string -> Yojson.Safe.t
val oas_checkpoint_summary_json :
  source_kind:string ->
  snapshot_id:string ->
  path:string ->
  is_current:bool ->
  fallback_generation:int ->
  Agent_sdk.Checkpoint.t ->
  Yojson.Safe.t
val keeper_checkpoint_inventory_json :
  Workspace.config -> string -> [ `Not_found | `OK ] * Yojson.Safe.t

include module type of Server_dashboard_http_keeper_runtime_manifest_scan

val keeper_runtime_trace_json :
  Workspace.config ->
  string ->
  ?trace_id:string ->
  ?turn_id:int ->
  ?limit:int ->
  unit ->
  [ `Not_found | `OK ] * Yojson.Safe.t

val handle_keeper_checkpoints_post :
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> string -> unit

val refresh_keeper_execution_surfaces :
  config:Workspace_utils.config -> name:String.t -> string -> unit
val invalidate_keeper_execution_surfaces :
  config:Workspace_utils.config -> unit -> unit

type resume_registration =
  | Already_registered
  | Booted_missing_registry

type paused_state_persist_plan =
  | Persist_paused_state of bool
  | Skip_paused_state_persist

val paused_state_persist_plan :
  Keeper_directive.t -> resume_registration -> paused_state_persist_plan

val handle_keeper_config_post :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Time.clock ->
  Mcp_server.server_state ->
  string ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  string ->
  unit

val handle_keeper_secrets_post :
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> string -> unit

val handle_keeper_lifecycle_post :
  ?body_str:string ->
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Time.clock ->
  tool_name:string ->
  action:String.t ->
  Mcp_server.server_state ->
  string ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  unit

val handle_keeper_directive_post :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Time.clock ->
  Mcp_server.server_state ->
  string ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  string ->
  unit

val handle_keeper_bulk_directive_post :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Time.clock ->
  Mcp_server.server_state ->
  string ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  string ->
  unit
