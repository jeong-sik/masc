(** Server_runtime_bootstrap — Server lifecycle orchestrator.

    Initializes the Eio runtime, creates server state, bootstraps
    subsystems (keepers, PG schemas), and runs the HTTP
    accept loop with auto-detect HTTP/1.1 + HTTP/2. *)

(** {1 Environment} *)

val force_jsonl_fallback_env : unit -> unit
val requested_backend_mode : unit -> string
val ensure_default_oas_cascade_timeout_env : unit -> unit
val config_bootstrap_mode : unit -> [> `Auto | `Empty | `Skip ]
val bootstrap_base_path_config_root : base_path:string -> unit
val startup_config_resolution : base_path:string -> Config_dir_resolver.resolution

(** {1 Runtime Context}

    Extracts Eio resources from the standard environment.
    Returns (clock, mono_clock, net, domain_mgr, proc_mgr, fs). *)

val init_runtime_context :
  < clock : ([> float Eio.Time.clock_ty] as 'a) Eio.Resource.t;
    mono_clock : ([> Eio.Time.Mono.ty] as 'b) Eio.Resource.t;
    net : ([> [> `Generic] Eio.Net.ty] as 'c) Eio.Resource.t;
    domain_mgr : ([> Eio.Domain_manager.ty] as 'd) Eio.Resource.t;
    process_mgr : ([> [> `Generic] Eio.Process.mgr_ty] as 'e) Eio.Resource.t;
    fs : ([> Eio.Fs.dir_ty] as 'f) Eio.Path.t;
    .. > ->
  'a Eio.Resource.t * 'b Eio.Resource.t * 'c Eio.Resource.t *
  'd Eio.Resource.t * 'e Eio.Resource.t * 'f Eio.Path.t

(** {1 Server State Lifecycle} *)

val create_server_state :
  sw:Eio.Switch.t ->
  base_path:string ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  mono_clock:Eio.Time.Mono.ty Eio.Resource.t ->
  net:[> `Generic | `Unix] Eio.Net.ty Eio.Resource.t ->
  proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t ->
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  Mcp_server.server_state

val runtime_path_diagnostics :
  ?input_base_path:string ->
  Mcp_server.server_state ->
  Server_base_path_diagnostics.t

val restore_persisted_sessions : Mcp_server.server_state -> unit
val reconcile_active_agents_gauge : Mcp_server.server_state -> unit
val bootstrap_server_state_blocking : Mcp_server.server_state -> unit
val bootstrap_prompt_state : Mcp_server.server_state -> unit

(** {1 Startup Tasks} *)

val warm_tool_registry_from_telemetry : Mcp_server.server_state -> unit
val migrate_legacy_dirs : Mcp_server.server_state -> unit
val startup_prune_jsonl : Mcp_server.server_state -> unit
val startup_prune_keeper_checkpoints : Mcp_server.server_state -> unit
val startup_migrate_keeper_histories : Mcp_server.server_state -> unit
val sync_bootable_keeper_credentials : Mcp_server.server_state -> unit

(** {2 Codex MCP Client Auth} *)

type codex_mcp_config_sync_status =
  | Codex_mcp_config_updated
  | Codex_mcp_config_unchanged
  | Codex_mcp_config_server_missing
  | Codex_mcp_config_header_missing

val sync_codex_mcp_auth_header_content :
  raw_token:string -> string -> string * codex_mcp_config_sync_status

(** {1 Main Entry Point} *)

val run :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  host:string ->
  port:int ->
  base_path:string ->
  make_routes:(port:int -> host:string -> sw:Eio.Switch.t ->
               clock:float Eio.Time.clock_ty Eio.Resource.t -> 'a) ->
  make_request_handler:('a ->
                        Eio.Net.Sockaddr.stream ->
                        Httpun.Reqd.t Gluten.Reqd.t -> unit) ->
  make_h2_request_handler:(sw:Eio.Switch.t ->
                           clock:float Eio.Time.clock_ty Eio.Resource.t ->
                           server_start_time:float ->
                           Eio.Net.Sockaddr.stream ->
                           H2.Reqd.t -> unit) ->
  make_h2_error_handler:(unit ->
                         Eio.Net.Sockaddr.stream ->
                         H2.Server_connection.error_handler) ->
  unit
