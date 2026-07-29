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

val handle_keeper_board_attention_quarantine_recovery_post :
  Mcp_server.server_state ->
  string ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  keeper_name:string ->
  raw_partition_id:string ->
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

(** [context_shrink_of_patch ~meta fields] is [Some (previous_display, new_value)]
    when the config patch reduces the keeper's context window below its current
    setting (introduces a cap where there was none, or lowers an existing cap),
    else [None]. Used by {!handle_keeper_config_post} to require an explicit
    [confirm_context_shrink] acknowledgement before applying a shrink. *)
val context_shrink_of_patch :
  meta:Keeper_meta_contract.keeper_meta ->
  (string * Yojson.Safe.t) list ->
  (string * int) option

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
(** A resume body requires [owner_nonce] and a stable
    [operator_operation_id]; raw action-only resume is rejected. *)

val handle_keeper_bulk_directive_post :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Time.clock ->
  Mcp_server.server_state ->
  string ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  string ->
  unit
(** Pause/wakeup accept a [names] list. Resume accepts a [targets] list whose
    entries carry [name], [owner_nonce], and [operator_operation_id]. *)

module For_testing : sig
  val parse_resume_request :
    Yojson.Safe.t -> (int * string, string) result

  val parse_bulk_resume_requests :
    Yojson.Safe.t -> ((string * int * string) list, string) result
end
