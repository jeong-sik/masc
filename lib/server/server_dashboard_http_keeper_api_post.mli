(** Keeper HTTP API POST handlers and runtime-trace helpers. *)

module Http = Http_server_eio

include module type of Server_dashboard_http_keeper_api_types

val json_list_length : Yojson.Safe.t -> int

val respond_error :
  ?status:Httpun.Status.t ->
  ?request:Httpun.Request.t ->
  ?ok:bool ->
  Httpun.Reqd.t ->
  string ->
  unit

(** Operator-initiated deliberation on behalf of [keeper]. The run is owned by
    the keeper named in the route, so its wake, board post and chat delivery
    are indistinguishable from a self-initiated run; the prompt, preset and
    topology come from the request body. Omitted preset/topology fall back to
    the tool's own defaults; validation stays in the tool so this endpoint
    cannot drift from what a keeper-side call would accept. *)
val handle_keeper_fusion_post :
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> string -> unit

val handle_keeper_operator_note_post :
  Mcp_server.server_state ->
  string ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
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
val agent_core_checkpoint_summary_json :
  source_kind:string ->
  snapshot_id:string ->
  path:string ->
  is_current:bool ->
  Agent_core.Checkpoint.t ->
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
  config:Workspace_utils.config ->
  name:String.t ->
  Keeper_lifecycle_events.lifecycle_event ->
  unit
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

(** Pure validation of a dashboard config patch body: duplicate keys, the
    allowed-field list, and per-field types/contracts (including the shared
    autonomous wake-prompt contract). [remote_endpoint] is checked for shape
    only -- a non-blank string, or null to detach it; whether the name is
    declared under [exec.ssh.endpoints] and whether the profile admits an
    endpoint at all are decided by [Keeper_turn_up_args.parse] on the apply
    path. [Ok ()] means {!handle_keeper_config_post} would proceed to apply
    it. *)
val validate_dashboard_config_patch :
  meta:Keeper_meta_contract.keeper_meta ->
  (string * Yojson.Safe.t) list ->
  (unit, string) result

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

val handle_keeper_github_login_post :
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> unit

val handle_keeper_oauth_login_post :
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> string -> unit

val handle_keeper_identity_refresh_post :
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> string -> unit

val handle_keeper_identity_switch_post :
  Mcp_server.server_state ->
  actor:string ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  string ->
  unit

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
(** A resume body requires a stable [operator_operation_id]; raw
    action-only resume is rejected. *)

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
    entries carry [name] and [operator_operation_id]. *)

module For_testing : sig
  val respond_config_reconciliation :
    request:Httpun.Request.t ->
    Httpun.Reqd.t ->
    name:string ->
    error:Yojson.Safe.t ->
    unit

  val github_login_stream_headers : string -> Httpun.Headers.t
  val github_login_stream_send_with :
    write:(string -> unit) ->
    flush:(unit -> unit) ->
    string ->
    Yojson.Safe.t ->
    unit

  val parse_resume_request :
    Yojson.Safe.t -> (string, string) result

  val parse_bulk_resume_requests :
    Yojson.Safe.t -> ((string * string) list, string) result
end
