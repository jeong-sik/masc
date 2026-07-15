(** Server_runtime_bootstrap — Server lifecycle orchestrator.

    Initializes the Eio runtime, creates server state, bootstraps
    subsystems (keepers, PG schemas), and runs the HTTP
    accept loop with auto-detect HTTP/1.1 + HTTP/2. *)

(** {1 Environment} *)

val config_bootstrap_mode : unit -> [ `Auto | `Empty | `Skip ]
val bootstrap_base_path_config_root : base_path:string -> unit
val startup_config_resolution : base_path:string -> Config_dir_resolver.resolution

val configure_oas_model_catalog_env :
  ?env:(string -> string option) ->
  ?agent_sdk_catalog:(unit -> Llm_provider.Model_catalog.t option) ->
  ?load_catalog:(string -> (Llm_provider.Model_catalog.t, string) result) ->
  ?set_catalog:(Llm_provider.Model_catalog.t -> unit) ->
  unit ->
  string option
(** Install only an operator-supplied [OAS_MODEL_CATALOG] as a full catalog
    replacement. Without it, require OAS's packaged catalog and leave it
    eligible for the deployment overlay. Config-root and executable-parent
    full catalogs are deliberately not discovered (RFC-0342 D1). *)

val configure_oas_model_catalog_overlay :
  ?config_root:string ->
  ?load_catalog:(string -> (Llm_provider.Model_catalog.t, string) result) ->
  ?set_overlay:(Llm_provider.Model_catalog.t -> unit) ->
  unit ->
  string option
(** Install the deployment capability overlay (RFC-0342 D1 / RFC-OAS-036).
    Resolves config-root [oas-models-overlay.toml] only; there is no parent
    or env fallback. When present, the parsed overlay is installed with
    [Model_catalog.set_global_overlay], so [Model_catalog.global] serves the
    embedded catalog merged with the deployment's delta rows. An explicit
    [OAS_MODEL_CATALOG] installed by {!configure_oas_model_catalog_env} keeps
    replacement precedence over the overlay. Returns the installed overlay path. An
    unreadable or invalid overlay raises [Env_config_core.Config_error]
    (fail-loud at boot, same as the full-catalog path). *)

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
  ?input_base_path:string ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  mono_clock:Eio.Time.Mono.ty Eio.Resource.t ->
  net:[ `Generic | `Unix] Eio.Net.ty Eio.Resource.t ->
  proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t ->
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  ?env:Eio_unix.Stdenv.base ->
  unit ->
  Mcp_server.server_state
(** [input_base_path] preserves the operator's pre-canonical path for
    diagnostics while [base_path] remains the sole effective runtime path.
    [env] is optional for backwards compatibility with existing
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
val bootstrap_prompt_state : Mcp_server.server_state -> unit

(** {1 Startup Tasks} *)

val warm_tool_registry_from_telemetry : Mcp_server.server_state -> unit
val startup_prune_jsonl : Mcp_server.server_state -> unit
val startup_migrate_keeper_histories : Mcp_server.server_state -> unit
val sync_bootable_keeper_credentials : Mcp_server.server_state -> unit
val sync_startup_credentials : Mcp_server.server_state -> unit

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

type startup_failure_disposition =
  | Fatal_pre_ready
  | Degraded_after_ready

val startup_failure_disposition : state_ready:bool -> startup_failure_disposition
(** Classify an exception from the initialization subtree. Before readiness,
    continuing would leave an unpublished partial owner mutating the
    workspace, so the only valid disposition is fatal. Degraded serving is
    available only after readiness has been published. *)

type owner_initialization_error =
  | Runtime_config_path_unavailable
  | Runtime_default_initialization_failed of Runtime.strict_init_error
  | Keeper_persistence_preparation_failed of
      Server_bootstrap_loops.keeper_persistence_prepare_error
  | Keeper_persistence_claim_failed of
      Server_bootstrap_loops.keeper_persistence_claim_error
  | Keeper_persistence_start_failed of
      Server_bootstrap_loops.keeper_persistence_start_error
  | Startup_path_guard_rejected of Server_base_path_diagnostics.t
  | Strict_path_guard_rejected of Server_base_path_diagnostics.t
  | Lazy_startup_barrier_failed of Server_startup_state.lazy_prepare_error
  | Readiness_transition_failed of Server_startup_state.state_ready_error
  | Readiness_publication_failed of
      { expected_backend_mode : string
      ; observed_backend_mode : string
      ; observed_phase : Server_startup_state.phase
      }

exception Owner_initialization_failed of owner_initialization_error

val owner_initialization_error_to_string : owner_initialization_error -> string

type initialized_owner_state

type activated_owner_state =
  { state : Mcp_server.server_state
  ; path_diagnostics : Server_base_path_diagnostics.t
  ; domain_pool : Domain_pool.t
  }

val initialize_owner_state_blocking
  :  sw:Eio.Switch.t
  -> env:Eio_unix.Stdenv.base
  -> base_path:string
  -> ?input_base_path:string
  -> clock:float Eio.Time.clock_ty Eio.Resource.t
  -> mono_clock:Eio.Time.Mono.ty Eio.Resource.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> domain_mgr:[> Eio.Domain_manager.ty ] Eio.Domain_manager.t
  -> proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t
  -> fs:Eio.Fs.dir_ty Eio.Path.t
  -> unit
  -> initialized_owner_state
(** Complete every transport-neutral, fallible owner-initialization step and
    return the still-unclaimed persistence preparation. A transport must
    pass this opaque value directly to {!activate_owner_state}; the prepared
    ownership token is intentionally not exposed to transports. *)

val activate_owner_state
  :  sw:Eio.Switch.t
  -> clock:float Eio.Time.clock_ty Eio.Resource.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> domain_mgr:[> Eio.Domain_manager.ty ] Eio.Domain_manager.t
  -> proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t
  -> initialized_owner_state
  -> activated_owner_state
(** Shared HTTP/stdio commit protocol: restore the durable Gate, schedule the
    bounded legacy-temp migration in an observed maintenance fiber under the
    exclusive BasePath lease, publish the lazy-task barrier, claim canonical
    persistence ownership, then immediately start the affine Keeper token.
    Current request writers use a disjoint staging namespace, so forensic
    cleanup cannot hold readiness. Readiness remains an explicit transport
    commit after its required surfaces are installed. *)

val mark_owner_state_ready
  :  Mcp_server.server_state
  -> (unit, owner_initialization_error) result
(** Publish and verify readiness after the transport has installed every
    surface required by its own serving contract. *)

(** {1 Main Entry Point} *)

val run :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  host:string ->
  port:int ->
  base_path:string ->
  ?input_base_path:string ->
  make_routes:(port:int -> host:string -> sw:Eio.Switch.t ->
               clock:float Eio.Time.clock_ty Eio.Resource.t -> 'a) ->
  make_request_handler:(trust_policy:Server_request_authority.trust_policy ->
                        'a ->
                        Eio.Net.Sockaddr.stream ->
                        Httpun.Reqd.t Gluten.Reqd.t -> unit) ->
  make_h2_request_handler:(trust_policy:Server_request_authority.trust_policy ->
                           sw:Eio.Switch.t ->
                           clock:float Eio.Time.clock_ty Eio.Resource.t ->
                           server_start_time:float ->
                           Eio.Net.Sockaddr.stream ->
                           H2.Reqd.t -> unit) ->
  make_h2_error_handler:(unit ->
                         Eio.Net.Sockaddr.stream ->
                         H2.Server_connection.error_handler) ->
  unit ->
  unit
