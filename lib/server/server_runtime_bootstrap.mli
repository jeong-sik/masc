(** Server_runtime_bootstrap — Server lifecycle orchestrator.

    Initializes the Eio runtime, creates server state, bootstraps
    subsystems (keepers, PG schemas), and runs the HTTP
    accept loop with auto-detect HTTP/1.1 + HTTP/2. *)

(** {1 Environment} *)

val config_bootstrap_mode : unit -> [ `Auto | `Empty | `Skip ]
val bootstrap_base_path_config_root : base_path:string -> unit
val startup_config_resolution : base_path:string -> Config_dir_resolver.resolution

type model_catalog_env_resolution =
  { path : string
  ; source : model_catalog_env_source
  }

and capability_manifest_env_resolution =
  { path : string
  ; source : capability_manifest_env_source
  }

and model_catalog_env_source =
  | Env_var of model_catalog_env_var
  | Config_root_catalog_file of string
  | Parent_file of
      { origin : model_catalog_parent_origin
      ; filename : string
      }

and capability_manifest_env_source =
  | Capability_manifest_env_var
  | Config_root_file of string

and model_catalog_env_var =
  | Oas_model_catalog
  | Masc_model_catalog

and model_catalog_parent_origin =
  | Cwd_parent
  | Argv0_parent

val model_catalog_env_source_to_string : model_catalog_env_source -> string
val capability_manifest_env_source_to_string : capability_manifest_env_source -> string

val resolve_oas_model_catalog_path :
  ?env:(string -> string option) ->
  ?config_root:string ->
  ?cwd:string ->
  ?argv0:string ->
  unit ->
  model_catalog_env_resolution option

val resolve_oas_capability_manifest_path :
  ?env:(string -> string option) ->
  config_root:string ->
  unit ->
  capability_manifest_env_resolution option

val configure_oas_model_catalog_env :
  ?env:(string -> string option) ->
  ?config_root:string ->
  ?cwd:string ->
  ?argv0:string ->
  ?putenv:(string -> string -> unit) ->
  ?preload_agent_sdk_catalog:(unit -> unit) ->
  ?agent_sdk_catalog:(unit -> Llm_provider.Model_catalog.t option) ->
  ?clear_catalog:(unit -> unit) ->
  ?load_catalog:(string -> Llm_provider.Model_catalog.t option) ->
  ?set_catalog:(Llm_provider.Model_catalog.t -> unit) ->
  unit ->
  model_catalog_env_resolution option

val configure_oas_capability_manifest_env :
  ?env:(string -> string option) ->
  config_root:string ->
  ?putenv:(string -> string -> unit) ->
  ?clear_manifest:(unit -> unit) ->
  ?load_manifest:(string -> Llm_provider.Capability_manifest.t option) ->
  ?set_manifest:(Llm_provider.Capability_manifest.t -> unit) ->
  unit ->
  capability_manifest_env_resolution option

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
  net:[ `Generic | `Unix] Eio.Net.ty Eio.Resource.t ->
  proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t ->
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  ?env:Eio_unix.Stdenv.base ->
  unit ->
  Mcp_server.server_state
(** [env] is optional for backwards compatibility with existing
    [create_server_state] callers (tests, MCP execute contexts);
    when supplied (server bootstrap path), it is recorded into
    [Eio_context.set_env] so long-lived HTTP consumers like
    [Masc_http_client.Pool] can lazy-init with the full
    {!Eio_unix.Stdenv.base}.  RFC-0107 Phase D.2c. *)

val runtime_path_diagnostics :
  ?input_base_path:string ->
  Mcp_server.server_state ->
  Server_base_path_diagnostics.t

val restore_persisted_sessions : Mcp_server.server_state -> unit
val reconcile_active_agents_gauge : Mcp_server.server_state -> unit
val bootstrap_server_state_blocking : Mcp_server.server_state -> unit
val initialize_memory_lane :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Mcp_server.server_state ->
  (Keeper_memory_lane.init_report, string) result
val bootstrap_prompt_state : Mcp_server.server_state -> unit

(** {1 Startup Tasks} *)

val warm_tool_registry_from_telemetry : Mcp_server.server_state -> unit
val startup_prune_jsonl : Mcp_server.server_state -> unit
val startup_migrate_keeper_histories : Mcp_server.server_state -> unit
val sync_bootable_keeper_credentials : Mcp_server.server_state -> unit

type lazy_startup_execution =
  | Parallel
  | Serial

type lazy_startup_group = {
  group_name : string;
  execution : lazy_startup_execution;
  task_names : string list;
}

val lazy_startup_plan : unit -> lazy_startup_group list
(** Deterministic startup task grouping.  [Parallel] groups contain only
    tasks whose stores are independent; [Serial] groups preserve ordering for
    shared tool state and cleanup phases. *)

val lazy_startup_task_names : unit -> string list
(** Flattened task names in the same dependency order used to activate
    {!Server_startup_state}'s lazy task queue. *)

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
