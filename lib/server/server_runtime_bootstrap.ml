
open Server_auth
open Server_routes_http

module Mcp_server = Mcp_server
module Mcp_eio = Mcp_server_eio
module Config_root_bootstrap = Server_runtime_config_root_bootstrap

let config_bootstrap_mode = Config_root_bootstrap.config_bootstrap_mode
let bootstrap_base_path_config_root = Config_root_bootstrap.bootstrap_base_path_config_root
let startup_config_resolution = Config_root_bootstrap.startup_config_resolution

type model_catalog_env_resolution =
  { path : string
  ; source : model_catalog_env_source
  }

and model_catalog_env_source =
  | Env_var of model_catalog_env_var
  | Config_root_catalog_file of string
  | Parent_file of
      { origin : model_catalog_parent_origin
      ; filename : string
      }

and model_catalog_env_var =
  | Oas_model_catalog
  | Masc_model_catalog

and model_catalog_parent_origin =
  | Cwd_parent
  | Argv0_parent

let model_catalog_env_var_name = function
  | Oas_model_catalog -> "OAS_MODEL_CATALOG"
  | Masc_model_catalog -> "MASC_MODEL_CATALOG"

let model_catalog_parent_origin_label = function
  | Cwd_parent -> "cwd-parent"
  | Argv0_parent -> "argv0-parent"

let model_catalog_env_source_to_string = function
  | Env_var var -> model_catalog_env_var_name var
  | Config_root_catalog_file filename -> Printf.sprintf "config-root:%s" filename
  | Parent_file { origin; filename } ->
    Printf.sprintf "%s:%s" (model_catalog_parent_origin_label origin) filename

let models_toml_filename = "models.toml"
let oas_models_toml_filename = "oas-models.toml"

let nonempty_env env name =
  match env name with
  | Some value ->
    let value = String.trim value in
    if String.equal value "" then None else Some value
  | None -> None

let existing_file path =
  let path = String.trim path in
  if String.equal path "" then
    None
  else
    try
      if Sys.file_exists path && not (Sys.is_directory path) then Some path else None
    with
    | Sys_error _ -> None

let rec find_in_parents filename dir depth =
  if depth <= 0 then
    None
  else
      let path = Filename.concat dir filename in
      match existing_file path with
      | Some _ as found -> found
      | None ->
        let parent = Filename.dirname dir in
        if String.equal parent dir then None else find_in_parents filename parent (depth - 1)

let find_catalog_in_parents ~origin dir =
  match find_in_parents models_toml_filename dir 10 with
  | Some path ->
    Some { path; source = Parent_file { origin; filename = models_toml_filename } }
  | None ->
    (match find_in_parents oas_models_toml_filename dir 10 with
     | Some path ->
       Some { path; source = Parent_file { origin; filename = oas_models_toml_filename } }
     | None -> None)

let find_catalog_in_config_root config_root =
  let catalog_file filename =
    let candidate = Filename.concat config_root filename in
    match existing_file candidate with
    | Some path -> Some { path; source = Config_root_catalog_file filename }
    | None -> None
  in
  match catalog_file models_toml_filename with
  | Some _ as found -> found
  | None -> catalog_file oas_models_toml_filename

let absolute_or_cwd ~cwd path =
  let path = String.trim path in
  if String.equal path "" then
    None
  else if String.length path > 0 && Char.equal path.[0] '/' then
    Some path
  else
    Some (Filename.concat cwd path)

let argv0_parent_dir ~cwd argv0 =
  match absolute_or_cwd ~cwd argv0 with
  | None -> None
  | Some path -> Some (Filename.dirname path)

let resolve_oas_model_catalog_path
      ?(env = Sys.getenv_opt)
      ?config_root
      ?cwd
      ?argv0
      ()
  =
  match nonempty_env env (model_catalog_env_var_name Oas_model_catalog) with
  | Some path -> Some { path; source = Env_var Oas_model_catalog }
  | None ->
    (match nonempty_env env (model_catalog_env_var_name Masc_model_catalog) with
     | Some path -> Some { path; source = Env_var Masc_model_catalog }
     | None ->
       let search_cwd =
         match cwd with
         | Some cwd when String.trim cwd <> "" -> cwd
         | _ -> Config_dir_resolver.base_path_or_cwd ()
       in
       let process_cwd =
         try Sys.getcwd () with Sys_error _ -> search_cwd
       in
       let argv0 =
         match argv0 with
         | Some argv0 -> argv0
         | None ->
           (match Array.to_list Sys.argv with
           | head :: _ -> head
           | [] -> "")
       in
       (match
          config_root
          |> Option.map String.trim
          |> (fun opt ->
               match opt with
               | Some value when not (String.equal value "") -> Some value
               | _ -> None)
          |> (fun root -> Option.bind root find_catalog_in_config_root)
        with
        | Some _ as found -> found
        | None ->
          (match find_catalog_in_parents ~origin:Cwd_parent search_cwd with
           | Some _ as found -> found
           | None ->
             (match argv0_parent_dir ~cwd:process_cwd argv0 with
              | Some dir -> find_catalog_in_parents ~origin:Argv0_parent dir
              | None -> None))))

let install_runtime_model_catalog_override ~load_catalog ~set_catalog path =
  match load_catalog path with
  | Ok catalog -> set_catalog catalog
  | Error detail ->
    raise (Env_config_core.Config_error (Printf.sprintf "catalog %s: %s" path detail))

let configure_oas_model_catalog_env
      ?(env = Sys.getenv_opt)
      ?config_root
      ?cwd
      ?argv0
      ?(putenv = Unix.putenv)
      ?(agent_sdk_catalog = Llm_provider.Model_catalog.global)
      ?(load_catalog = Llm_provider.Model_catalog.load_file)
      ?(set_catalog = Llm_provider.Model_catalog.set_global)
      ()
  =
  match resolve_oas_model_catalog_path ~env ?config_root ?cwd ?argv0 () with
  | Some { source = Env_var Oas_model_catalog; path } as resolution ->
    install_runtime_model_catalog_override ~load_catalog ~set_catalog path;
    Log.Misc.info
      "model_catalog: OAS_MODEL_CATALOG=%s already configured and loaded"
      path;
    resolution
  | Some { source; path } as resolution ->
    putenv (model_catalog_env_var_name Oas_model_catalog) path;
    install_runtime_model_catalog_override ~load_catalog ~set_catalog path;
    Log.Misc.info
      "model_catalog: OAS_MODEL_CATALOG=%s resolved from %s and loaded"
      path
      (model_catalog_env_source_to_string source);
    resolution
  | None ->
    (match agent_sdk_catalog () with
     | Some _ ->
       Log.Misc.info
         "model_catalog: no explicit catalog path resolved; using agent_sdk ambient \
          model catalog"
     | None ->
       raise (Env_config_core.Config_error "model_catalog: OAS embedded model catalog is unavailable"));
    None

(* GC tuning for long-running server with bursty allocation.

   Dashboard refresh loops create 2GB+ transient allocations per cycle.
   With aggressive GC (space_overhead=40), major GC slices walk
   MADV_FREE'd pages on macOS, triggering page faults that freeze the
   Eio event loop — blocking /health and all HTTP endpoints.

   Only apply defaults when OCAMLRUNPARAM is not set, so operators
   can override at launch without code changes. *)
let () =
  ignore (Dashboard.force_link, Operator_tool.force_link);
  Transport_read_model.register_grpc_service_name Masc_grpc_service.service_name;
  Transport_read_model.register_grpc_health_service_name Masc_grpc_server.health_service_name;
  Transport_read_model.register_webrtc_status (fun () ->
    { ice_server_urls = Server_webrtc_transport.configured_ice_server_urls ()
    ; pending_offers = Server_webrtc_transport.pending_offer_count ()
    ; active_peers = Server_webrtc_transport.active_peer_count ()
    ; live_connections = Server_webrtc_transport.live_webrtc_count ()
    ; connected_channels = Server_webrtc_transport.connected_channel_count ()
    });
  Dashboard_snapshot.register_dashboard_tools_http_json Server_dashboard_http_runtime_info.dashboard_tools_http_json;
  Dashboard_snapshot.register_namespace_truth_snapshot Server_dashboard_http_namespace_truth.namespace_truth_snapshot_from_caches;
  if Option.is_none (Sys.getenv_opt "OCAMLRUNPARAM") then begin
    let open Gc in
    (* Route through the validated helper: a malformed value (e.g.
       MASC_GC_SPACE_OVERHEAD=abc) previously raised [Failure] -- the
       hand-rolled [with Not_found] only caught the unset case, so a typo
       in this env var crashed server bootstrap. [get_int_nonneg] also
       maps a negative value to the default. *)
    let gc_space_overhead =
      Env_config_core.get_int_nonneg ~default:100 "MASC_GC_SPACE_OVERHEAD"
    in
    let ctrl = get () in
    set { ctrl with
      (* minor_heap_size is intentionally not set here. [main_eio.ml]
         sets it to 4M words (32 MiB) to cut stop-the-world minor-GC
         pressure from JSON parsing and metric encoding; a second 2M
         setting here would either be dead (if main_eio runs later) or
         override the intended 4M (if it runs first), depending on init
         order. Keep a single source in main_eio.ml. *)
      space_overhead = gc_space_overhead;  (* default 120. Configurable via MASC_GC_SPACE_OVERHEAD.
                                             100 = triggers major GC when free > live (was 200/3x).
                                             Lower = shorter individual pauses, more frequent slices.
                                             P0 allocation fixes (PR #20965) reduced broadcast hot-path
                                             allocation by ~97%, so the increased frequency has negligible
                                             throughput impact. *)
      max_overhead = 500;                 (* compaction triggers when free memory exceeds 500% of live data *)
    }
  end


let init_runtime_context env =
  let clock = Eio.Stdenv.clock env in
  let mono_clock = Eio.Stdenv.mono_clock env in
  let net = Eio.Stdenv.net env in
  let domain_mgr = Eio.Stdenv.domain_mgr env in
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let fs = Eio.Stdenv.fs env in
  (clock, mono_clock, net, domain_mgr, proc_mgr, fs)

let metric_keeper_runtime_config_load_failures =
  "masc_keeper_runtime_config_load_failures_total"

let () =
  Otel_metric_store.register_counter
    ~name:metric_keeper_runtime_config_load_failures
    ~help:
      "Total Keeper_runtime_config.load_and_apply failures. Bootstrap logs WARN; \
       this counter exposes the same event to monitoring aggregation. Labels: \
       reason in {read_error | parse_error}."
    ()

let record_runtime_toml_load_failure msg =
  let reason =
    if String.starts_with ~prefix:"read " msg
    then Some "read_error"
    else if String.starts_with ~prefix:"parse " msg
    then Some "parse_error"
    else None
  in
  Option.iter
    (fun reason ->
       Otel_metric_store.inc_counter
         metric_keeper_runtime_config_load_failures
         ~labels:[ "reason", reason ]
      ())
    reason

let thompson_shutdown_hook_registered = Atomic.make false

let ensure_thompson_persistence ~base_path =
  Thompson_sampling.set_base_path base_path;
  Thompson_sampling.load_stats ();
  if Atomic.compare_and_set thompson_shutdown_hook_registered false true then
    Shutdown.register ~name:"thompson_sampling_save" ~priority:24 (fun () ->
      Thompson_sampling.save_stats ())

let create_server_state ~sw ~base_path ?input_base_path ~clock ~mono_clock ~net
    ~proc_mgr ~fs ?env ()
    : Mcp_server.server_state =
  let input_base_path =
    (* DET-OK: absent transport input selects the explicit owner BasePath;
       normalization below remains the sole interpretation boundary. *)
    match String.trim (Option.value input_base_path ~default:base_path) with
    | "" -> None
    | raw -> Some raw
  in
  let base_path = Env_config_core.normalize_masc_base_path_input base_path in
  Runtime_params.initialize ~base_path;
  Fs_compat.set_fs fs;
  (* RFC-0266 §7 Phase D: replay persisted fusion run history into the
     process-wide registry so in-progress + recently-completed runs survive
     server restart. Missing files yield an empty registry; malformed replay
     lines are logged and skipped. *)
  let registry_path =
    Filename.concat (Common.masc_dir_from_base_path ~base_path) "fusion-runs.jsonl"
  in
  Fusion_run_registry.set_global (Fusion_run_registry.replay registry_path);
  (* Product-neutral completion addresses and unacknowledged payloads hydrate
     before any upper MASC delivery adapter can drain them. *)
  let completion_outbox_path =
    Filename.concat
      (Common.masc_dir_from_base_path ~base_path)
      "fusion-completion-outbox.jsonl"
  in
  Fusion_completion_outbox.set_global
    (Fusion_completion_outbox.replay completion_outbox_path);
  ignore (Fusion_wake_route.drain_all ~base_dir:base_path);
  Mcp_eio.set_net net;
  Mcp_eio.set_clock clock;
  Eio_context.set_switch sw;
  Eio_context.set_net net;
  Eio_context.set_clock clock;
  Eio_context.set_mono_clock mono_clock;
  Masc_eio_env.init ~sw ~net ~clock ();
  (* RFC-0257: own detached per-keeper memory-lane fibers on the server root
     switch. After [set_switch] so the lane and provider calls it forks share
     the same long-lived switch (cancelled together at shutdown). *)
  Keeper_memory_lane.init ~sw;
  (* RFC-0107 Phase D.2c — record full Eio.Stdenv for piaf-backed
     Pool in Masc_http_client.  Optional: tests / pre-bootstrap
     callers may omit [env], in which case Pool falls back to a
     stub (request returns Error). *)
  Option.iter Eio_context.set_env env;
  Process_eio.init ~cwd_default:Eio.Path.(fs / base_path) ~proc_mgr ~clock;
  Exec_tap.install_from_env ();
  Unix.putenv
    Env_config_core.base_path_input_env_key
    (Option.value ~default:"" input_base_path);
  Unix.putenv Env_config_core.base_path_env_key base_path;
  ensure_thompson_persistence ~base_path;
  bootstrap_base_path_config_root ~base_path;
  let config_root = (startup_config_resolution ~base_path).config_root.path in
  let (_ : model_catalog_env_resolution option) =
    configure_oas_model_catalog_env ~config_root ()
  in
  (* Apply keeper runtime overrides from the resolved config root's
     runtime.toml. Must run before any module that reads
     [Env_config_keeper.KeeperKeepalive] env vars at init time. Existing
     process env vars take precedence — TOML only fills unset slots. *)
  (match Keeper_runtime_config.load_and_apply ~base_path with
   | Ok 0 -> ()
   | Ok n ->
       Log.Server.info "runtime.toml: applied %d override(s)" n
   | Error msg ->
       record_runtime_toml_load_failure msg;
       Log.Server.error "runtime.toml load failed: %s" msg;
       raise (Env_config_core.Config_error msg));
  Keeper_runtime_resolved.init ();
  Keeper_task_owner_backend.install_hooks ();
  let state =
    Mcp_eio.create_state_eio ~sw ~proc_mgr ~fs ~clock
      ~mono_clock ~net
      ~base_path
  in
  let config_resolution =
    startup_config_resolution ~base_path |> Config_dir_resolver.to_json
  in
  let config = Mcp_server.workspace_config state in
  let path_diagnostics =
    Server_base_path_diagnostics.detect
      ?input_base_path
      ?env_masc_base_path:((Host_config.from_env ()).base_path_raw)
      ~effective_base_path:config.base_path
      ~effective_masc_root:(Workspace.masc_root_dir config)
      ()
    |> Server_base_path_diagnostics.to_yojson
  in
  Server_startup_state.note_runtime_resolution ~path_diagnostics
    ~config_resolution;
  (* RFC-0107 Phase D.4 — wire piaf connection pool Otel_metric_store exporter.
     Metric registration itself runs at [Otel_metric_store] module load; this
     call is the explicit dependency-order anchor and warms the snapshot
     accessor so a misconfigured pool surfaces here rather than at first
     telemetry export. *)
  Pool_metrics.register ();
  state

let runtime_path_diagnostics ?input_base_path (state : Mcp_server.server_state) =
  let config = Mcp_server.workspace_config state in
  Server_base_path_diagnostics.detect
    ?input_base_path
    ?env_masc_base_path:((Host_config.from_env ()).base_path_raw)
    ~effective_base_path:config.base_path
    ~effective_masc_root:(Workspace.masc_root_dir config)
    ()

let restore_persisted_sessions (state : Mcp_server.server_state) =
  Session.restore_from_disk state.session_registry
    ~agents_path:(Workspace.agents_dir (Mcp_server.workspace_config state))

let reconcile_active_agents_gauge (state : Mcp_server.server_state) =
  Otel_metric_store.reconcile_active_agents_gauge (Workspace.masc_dir (Mcp_server.workspace_config state))


(* Startup maintenance extracted to
   [Server_runtime_startup_maintenance] (godfile decomp). *)
include Server_runtime_startup_maintenance

(* Credential sync and egress audit extracted to
   [Server_runtime_startup_credentials] (godfile decomp). *)
include Server_runtime_startup_credentials

let bootstrap_server_state_blocking (state : Mcp_server.server_state) =
  (* [create_server_state] normally resets this after config bootstrap, but
     direct state constructors used by tests and execute contexts can leave a
     stale process-global config resolution in place. *)
  Config_dir_resolver.reset ();
  let (_init_msg : string) = Workspace.init (Mcp_server.workspace_config state) ~agent_name:None in
  Mcp_server.set_sse_callback state Sse.broadcast


type lazy_startup_execution =
  | Parallel
  | Serial

type lazy_startup_group = {
  group_name : string;
  execution : lazy_startup_execution;
  task_names : string list;
}

let lazy_startup_plan () =
  let initial_groups =
    [
      {
        group_name = "initialize";
        execution = Parallel;
        task_names =
          [
            "restore_sessions";
            "reconcile_active_agents";
            "prompt_bootstrap";
            "keeper_history_migration";
          ];
      };
      {
        group_name = "tool_state";
        execution = Serial;
        task_names = [ "telemetry_warmup"; "tool_metrics_restore" ];
      };
    ]
  in
  let cleanup_groups =
    [
      {
        group_name = "cleanup";
        execution = Serial;
        task_names = [ "jsonl_prune" ];
      };
    ]
  in
  initial_groups @ cleanup_groups

let lazy_startup_task_names () =
  lazy_startup_plan ()
  |> List.concat_map (fun group -> group.task_names)

type startup_failure_disposition =
  | Fatal_pre_ready
  | Degraded_after_ready

let startup_failure_disposition ~state_ready =
  if state_ready then Degraded_after_ready else Fatal_pre_ready

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

type initialized_owner_state =
  { state : Mcp_server.server_state
  ; path_diagnostics : Server_base_path_diagnostics.t
  ; prepared_keeper_persistence : Server_bootstrap_loops.prepared_keeper_persistence
  ; domain_pool : Domain_pool.t
  }

type activated_owner_state =
  { state : Mcp_server.server_state
  ; path_diagnostics : Server_base_path_diagnostics.t
  ; domain_pool : Domain_pool.t
  }

let owner_initialization_error_to_string = function
  | Runtime_config_path_unavailable ->
    "no runtime config path; cannot initialize the default Runtime"
  | Runtime_default_initialization_failed error ->
    "Runtime.init_default_degraded failed: "
    ^ Runtime.strict_init_error_to_string error
  | Keeper_persistence_preparation_failed error ->
    "Keeper persistence preparation failed: "
    ^ Server_bootstrap_loops.keeper_persistence_prepare_error_to_string error
  | Keeper_persistence_claim_failed error ->
    "Keeper persistence claim failed: "
    ^ Server_bootstrap_loops.keeper_persistence_claim_error_to_string error
  | Keeper_persistence_start_failed error ->
    "Keeper persistence Keeper-loop start failed: "
    ^ Server_bootstrap_loops.keeper_persistence_start_error_to_string error
  | Startup_path_guard_rejected diagnostics ->
    Option.value
      diagnostics.Server_base_path_diagnostics.warning
      ~default:"startup path guard rejected malformed runtime state"
  | Strict_path_guard_rejected diagnostics ->
    Option.value
      diagnostics.Server_base_path_diagnostics.warning
      ~default:"strict BasePath guard rejected the runtime path configuration"
  | Lazy_startup_barrier_failed error ->
    Server_startup_state.lazy_prepare_error_to_string error
  | Readiness_transition_failed error ->
    Server_startup_state.state_ready_error_to_string error
  | Readiness_publication_failed
      { expected_backend_mode; observed_backend_mode; observed_phase } ->
    Printf.sprintf
      "owner readiness publication failed for backend=%s (observed_backend=%s observed_phase=%s)"
      expected_backend_mode
      observed_backend_mode
      (Server_startup_state.phase_to_string observed_phase)

let initialize_owner_state_blocking
      ~sw
      ~env
      ~base_path
      ?input_base_path
      ~clock
      ~mono_clock
      ~net
      ~domain_mgr
      ~proc_mgr
      ~fs
      ()
  =
  (* DET-OK: the optional transport spelling and the required owner BasePath
     denote the same requested path when the former is absent. *)
  let requested_base_path = Option.value input_base_path ~default:base_path in
  let base_path =
    match Eio_unix.run_in_systhread (fun () -> Unix.realpath base_path) with
    | canonical -> canonical
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
    | exception ((Unix.Unix_error _ | Sys_error _) as exception_) ->
      let backtrace = Printexc.get_raw_backtrace () in
      let failure : Server_bootstrap_loops.keeper_persistence_failure =
        { phase = Server_bootstrap_loops.Resolving_base_path
        ; base_path
        ; cause =
            Server_bootstrap_loops.Base_path_identity_unavailable_cause
              { exception_; backtrace }
        }
      in
      raise
        (Owner_initialization_failed
           (Keeper_persistence_preparation_failed
              (Server_bootstrap_loops.Preparation_base_path_identity_unavailable
                 failure)))
  in
  let path_diagnostics =
    Server_base_path_diagnostics.detect
      ~input_base_path:requested_base_path
      ?env_masc_base_path:((Host_config.from_env ()).base_path_raw)
      ~effective_base_path:base_path
      ~effective_masc_root:(Common.masc_dir_from_base_path ~base_path)
      ()
  in
  Server_base_path_diagnostics.log_startup_warning path_diagnostics;
  if Server_base_path_diagnostics.startup_should_abort path_diagnostics
  then
    raise
      (Owner_initialization_failed
         (Startup_path_guard_rejected path_diagnostics));
  if Server_base_path_diagnostics.strict_violation path_diagnostics
  then
    raise
      (Owner_initialization_failed
         (Strict_path_guard_rejected path_diagnostics));
  (* [main_eio] caches the normalized operator input before entering Eio.
     Replace that preflight value with the canonical owner identity before
     [Workspace.default_config_eio] constructs its backend, otherwise the
     config record says canonical while its backend still follows an alias. *)
  Workspace_utils_backend_setup.cache_resolved_base_path base_path;
  Discovery_cache.set_env ~sw ~net;
  Discovery_cache.set_base_path base_path;
  Gc_sampler.run ~sw ~clock ~interval:30.0;
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      Eio.Time.sleep clock 5.0;
      (try Keeper_registry_tool_usage_persistence.flush_all_dirty () with
       | Eio.Cancel.Cancelled _ as exn -> raise exn
       | exn ->
         Log.Keeper.warn
           "tool_usage flush_all_dirty failed: %s"
           (Printexc.to_string exn));
      loop ()
    in
    loop ());
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      Eio.Time.sleep clock 2.0;
      (try Trajectory.flush_all_pending () with
       | Eio.Cancel.Cancelled _ as exn -> raise exn
       | exn ->
         Log.Keeper.warn
           "trajectory flush_all_pending failed: %s"
           (Printexc.to_string exn));
      loop ()
    in
    loop ());
  let t0 = Eio.Time.now clock in
  Llm_metric_bridge.install ();
  Llm_metric_bridge.init ~base_path;
  Log.Server.info
    "Llm_metric_bridge installed (masc_llm_provider_http_status_total, inference-events JSONL)";
  Backend.FileSystem.set_mutex_observers
    ~acquire:(fun ~op ~seconds ->
      Otel_metric_store.observe_histogram
        Otel_metric_store.metric_backend_mutex_acquire_sec
        ~labels:[ "op", op ]
        seconds)
    ~held:(fun ~op ~seconds ->
      Otel_metric_store.observe_histogram
        Otel_metric_store.metric_backend_mutex_held_sec
        ~labels:[ "op", op ]
        seconds);
  Log.Server.info "Backend_mutex_metrics installed (masc_backend_mutex_* metrics)";
  Fd_accountant.install_observers
    ~nofile_soft_limit:Keeper_fd_pressure.process_nofile_soft_limit
    ~on_resource_error:(fun ~kind error exn ->
      let kind_name = Fd_accountant.kind_to_string kind in
      let error_name = Fd_accountant.resource_error_to_string error in
      let site = "fd_accountant." ^ kind_name in
      Log.Server.error
        "Fd_accountant observed OS resource error kind=%s error=%s exception=%s"
        kind_name
        error_name
        (Printexc.to_string exn);
      match error with
      | Fd_accountant.Process_fd_exhausted
      | Fd_accountant.System_fd_exhausted ->
        Keeper_fd_pressure.note_exception ~site exn
      | Fd_accountant.Storage_space_exhausted ->
        Keeper_disk_pressure.note_exception ~site exn);
  Log.Server.info "Fd_accountant OS resource observers installed";
  Agent_sdk_log_bridge.install ();
  Log.Server.info
    "Agent_sdk_log_bridge installed (agent_sdk.Log -> masc structured log)";
  let state =
    create_server_state
      ~sw
      ~base_path
      ~input_base_path:requested_base_path
      ~clock
      ~mono_clock
      ~net
      ~proc_mgr
      ~fs
      ~env
      ()
  in
  (match Runtime.config_path () with
   | None ->
     raise (Owner_initialization_failed Runtime_config_path_unavailable)
   | Some config_path ->
     (match Runtime.init_default_degraded_report ~config_path with
      | Ok Runtime.Initialized ->
        Log.Server.info
          "Runtime default initialized: %s"
          (Runtime.get_default_runtime_id ())
      | Ok (Runtime.Initialized_degraded degradation) ->
        Log.Server.warn
          "Runtime default initialized in degraded catalog mode: %s"
          (Runtime.startup_degradation_to_string degradation);
        Log.Server.warn
          "Runtime degraded effective default: %s"
          (Runtime.get_default_runtime_id ())
      | Error error ->
        raise
          (Owner_initialization_failed
             (Runtime_default_initialization_failed error))));
  let t1 = Eio.Time.now clock in
  Log.Server.info "State created (runtime state) in %.1fs" (t1 -. t0);
  bootstrap_server_state_blocking state;
  startup_recover_keeper_lifecycle_transactions state;
  startup_migrate_retired_keeper_meta_keys state;
  sync_admin_token_env state;
  sync_internal_keeper_token_env state;
  sync_bootable_keeper_credentials state;
  let prepared_keeper_persistence =
    match
      Server_bootstrap_loops.prepare_keeper_persistence
        ~requested_base_path
        ~config:(Mcp_server.workspace_config state)
        ()
    with
    | Ok prepared -> prepared
    | Error error ->
      raise
        (Owner_initialization_failed
           (Keeper_persistence_preparation_failed error))
  in
  Runtime_settings.ensure_init ();
  Runtime_params.restore ~base_path;
  Log.Server.info "Runtime_params restored from %s" base_path;
  Keeper_crash_persistence.start_drain_fiber ~sw ~clock;
  (try
     Auth.audit_token_uniqueness base_path
     |> List.iter (fun (token_hash_prefix, agent_names) ->
       Otel_metric_store.inc_counter
         Otel_metric_store.metric_auth_credential_token_duplicate
         ~labels:[ "token_hash_prefix", token_hash_prefix ]
         ();
       Log.Server.warn
         "#9786 credential token shared by %d agents [%s] (token_hash_prefix=%s) — rotate via Auth.create_token to prevent bearer-token routing ambiguity"
         (List.length agent_names)
         (String.concat ", " agent_names)
         token_hash_prefix)
   with
   | Eio.Cancel.Cancelled _ as exn -> raise exn
   | exn ->
     Log.Server.error
       "boot: credential token uniqueness audit failed: %s"
       (Printexc.to_string exn));
  Log.Server.info "Bootstrap completed in %.1fs" (Eio.Time.now clock -. t1);
  let stale_threshold_hours = 12 in
  let build = Build_identity.current () in
  (match build.binary_commit, build.binary_commit_age_seconds with
   | Some binary_commit, Some age
     when age > stale_threshold_hours * Masc_time_constants.hour_int ->
     let hours = age / Masc_time_constants.hour_int in
     Log.Server.warn
       "Server binary commit %s is %d hours old (>%dh threshold). Rebuild + restart recommended to pick up newer fixes; see /health build.binary_commit_age_seconds."
       binary_commit
       hours
       stale_threshold_hours
   | _ -> ());
  let domain_pool =
    Domain_pool.create
      ~sw
      ?domain_count:(Env_config.Executor.domain_count_override ())
      domain_mgr
  in
  Domain_pool_ref.set domain_pool;
  Log.Server.info
    "Domain_pool created (%d domains) for dashboard/keeper compute"
    (Domain_pool.domain_count domain_pool);
  { state; path_diagnostics; prepared_keeper_persistence; domain_pool }

(* Cap the per-boot file list in the sync log line; full counts are always
   logged, names are illustrative. *)
let max_logged_prompt_sync_entries = 10

let sync_prompt_assets_from_binary () =
  let sync =
    Prompt_defaults.sync_prompt_assets
      ~read:Embedded_config.read
      ~files:Embedded_config.file_list
      ~prompts_dir:(Config_dir_resolver.prompts_dir ())
      ()
  in
  (match sync.Prompt_defaults.copied, sync.Prompt_defaults.overwritten with
   | [], [] -> ()
   | copied, overwritten ->
       let names = copied @ overwritten in
       let shown =
         List.filteri (fun i _ -> i < max_logged_prompt_sync_entries) names
       in
       Log.Misc.info
         "prompt assets synced from binary: %d copied, %d overwritten [%s%s]"
         (List.length copied) (List.length overwritten)
         (String.concat ", " shown)
         (if List.length names > max_logged_prompt_sync_entries then ", …"
          else ""));
  List.iter
    (fun (rel, msg) -> Log.Misc.warn "prompt asset sync failed: %s: %s" rel msg)
    sync.Prompt_defaults.failed

let bootstrap_prompt_state (state : Mcp_server.server_state) =
  let config = Mcp_server.workspace_config state in
  Config_dir_resolver.log_warnings ~context:"ServerBootstrap" ();
  Config_dir_resolver.log_resolution ~context:"ServerBootstrap" ();
  (* Converge runtime prompt markdown onto the binary-embedded assets
     before the registry scans the directory (#20929: merged prompt edits
     never reached the runtime dir otherwise). *)
  sync_prompt_assets_from_binary ();
  (* Initialize prompt registry with defaults and restore saved overrides *)
  let prompt_markdown_dir =
    Prompt_defaults.bootstrap_runtime
      ~workspace_path:config.workspace_path
      ~base_path:config.base_path
  in
  let expected_prompt_dir = Config_dir_resolver.prompts_dir () in
  if prompt_markdown_dir <> expected_prompt_dir then
    Log.Misc.warn
      "prompt markdown dir diverges from resolved config root: %s (expected %s)"
      prompt_markdown_dir expected_prompt_dir;
  let missing_prompt_files = Prompt_registry.validate_required_prompt_files () in
  if missing_prompt_files <> [] then
    begin
    Otel_metric_store.inc_counter Otel_metric_store.metric_error_events ~labels:[("type", Error_event_type.(to_label Missing_config))] ();
    Log.Misc.error "required prompt files missing: %s"
      (missing_prompt_files
      |> List.map (fun (key, path) -> Printf.sprintf "%s -> %s" key path)
      |> String.concat ", ");
  end;
  let invalid_prompt_templates = Prompt_registry.validate_prompt_templates () in
  if invalid_prompt_templates <> [] then
    begin
    Otel_metric_store.inc_counter Otel_metric_store.metric_error_events ~labels:[("type", Error_event_type.(to_label Missing_config))] ();
    Log.Misc.error "prompt templates use unknown variables: %s"
      (invalid_prompt_templates
      |> List.map (fun (key, variable) -> Printf.sprintf "%s -> %s" key variable)
      |> String.concat ", ")
  end

let warm_tool_registry_from_telemetry (state : Mcp_server.server_state) =
  (try
     let summary =
       Telemetry_eio.summarize_tool_usage (Mcp_server.workspace_config state)
     in
     if summary.telemetry_available then
       (* PR-S3: project the persisted Telemetry_eio summary into the registry's
          neutral [warm_up_stats] shape at the composition root, so
          [Tool_registry] (lib/tool/, masc_tool_dispatch) does not code-depend
          on the telemetry persistence layer. *)
       let stats_by_tool =
         Hashtbl.fold
           (fun tool_name (stats : Telemetry_eio.tool_usage_stats) acc ->
              ( tool_name
              , { Tool_registry.count = stats.count
                ; success_count = stats.success_count
                ; failure_count = stats.failure_count
                ; last_used_at = stats.last_used_at
                } )
              :: acc)
           summary.stats_by_tool
           []
       in
       let n = Tool_registry.warm_up stats_by_tool in
       Log.Misc.info "tool registry: warmed up %d tools (%d calls) from telemetry"
         n summary.total_calls
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     Log.Misc.warn "tool registry warm-up failed: %s (lazy init on first call)"
       (Printexc.to_string exn))

let restore_tool_metrics_from_disk (state : Mcp_server.server_state) =
  (try
     let n = Tool_metrics_persist.restore
       ~base_path:(Mcp_server.workspace_config state).base_path in
     if n > 0 then
       Log.Misc.info "tool metrics: restored %d records from disk" n
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     Log.Misc.warn "tool metrics restore failed: %s (metrics empty until next emission)"
       (Printexc.to_string exn))

let start_owner_lazy_tasks ~sw state =
  let run_lazy_task (task_name, task_fn) =
    Log.Server.info "lazy_task: starting %s" task_name;
    try
      task_fn ();
      Log.Server.info "lazy_task: finished %s" task_name;
      Server_startup_state.finish_lazy_task ~task:task_name
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
      let error = Printexc.to_string exn in
      Log.Server.error "lazy startup task %s failed: %s" task_name error;
      Server_startup_state.fail_lazy_task ~task:task_name ~error
  in
  let task_fn = function
    | "restore_sessions" -> fun () -> restore_persisted_sessions state
    | "reconcile_active_agents" -> fun () -> reconcile_active_agents_gauge state
    | "prompt_bootstrap" -> fun () -> bootstrap_prompt_state state
    | "keeper_history_migration" -> fun () -> startup_migrate_keeper_histories state
    | "telemetry_warmup" -> fun () -> warm_tool_registry_from_telemetry state
    | "tool_metrics_restore" -> fun () -> restore_tool_metrics_from_disk state
    | "jsonl_prune" -> fun () -> startup_prune_jsonl state
    | task_name ->
      raise
        (Invalid_argument
           (Printf.sprintf "unknown lazy startup task: %s" task_name))
  in
  let task_names = lazy_startup_task_names () in
  let task_groups =
    lazy_startup_plan ()
    |> List.map (fun group ->
      group, List.map (fun name -> name, task_fn name) group.task_names)
  in
  let execution_to_string = function
    | Parallel -> "parallel"
    | Serial -> "serial"
  in
  let run_lazy_task_group (group, tasks) =
    Log.Server.info
      "lazy_task_group: starting %s (%s, %d tasks)"
      group.group_name
      (execution_to_string group.execution)
      (List.length tasks);
    (match group.execution with
     | Parallel ->
       Eio.Fiber.all (List.map (fun task () -> run_lazy_task task) tasks)
       |> ignore
     | Serial -> List.iter run_lazy_task tasks);
    Log.Server.info "lazy_task_group: finished %s" group.group_name
  in
  (match Server_startup_state.prepare_lazy_tasks ~tasks:task_names with
   | Ok () -> ()
   | Error error ->
     raise (Owner_initialization_failed (Lazy_startup_barrier_failed error)));
  Eio.Fiber.fork ~sw (fun () -> List.iter run_lazy_task_group task_groups)

let claim_and_start_keeper_persistence
      ~prepared_persistence
      ~sw
      ~clock
      ~net
      ~domain_mgr
      ~proc_mgr
      state
  =
  let claimed_persistence =
    match
      Server_bootstrap_loops.claim_prepared_keeper_persistence
        ~config:(Mcp_server.workspace_config state)
        prepared_persistence
    with
    | Ok claimed -> claimed
    | Error error ->
      raise
        (Owner_initialization_failed
           (Keeper_persistence_claim_failed error))
  in
  try
    Server_bootstrap_loops.start_keeper_loops
      ~claimed_persistence
      ~sw
      ~clock
      ~net
      ~domain_mgr
      ~proc_mgr
      state
  with
  | Server_bootstrap_loops.Keeper_persistence_start_failed error ->
    raise
      (Owner_initialization_failed
         (Keeper_persistence_start_failed error))
;;

let mark_owner_state_ready state =
  let backend =
    match (Mcp_server.workspace_config state).Workspace.backend with
    | Workspace.Memory _ -> Server_startup_state.Memory_backend
    | Workspace.FileSystem _ -> Server_startup_state.Filesystem_backend
  in
  let expected_backend_mode = Server_startup_state.ready_backend_to_string backend in
  match Server_startup_state.mark_state_ready ~backend with
  | Error error -> Error (Readiness_transition_failed error)
  | Ok () ->
    let observed = Server_startup_state.(!state) in
    if
      observed.state_ready
      && String.equal observed.backend_mode expected_backend_mode
    then Ok ()
    else
      Error
        (Readiness_publication_failed
           { expected_backend_mode
           ; observed_backend_mode = observed.backend_mode
           ; observed_phase = observed.phase
           })

let install_keeper_gate_persistence state =
  let base_path = (Mcp_server.workspace_config state).base_path in
  match Keeper_approval_queue.install_persistence ~base_path with
  | Error error ->
    (* Gate persistence is lane-local. Keep unrelated server subsystems
       available, but surface the unavailable Gate explicitly instead of
       treating a malformed durable queue as empty. *)
    Log.Server.error
      "keeper_gate: durable queue install failed base_path=%s error=%s"
      base_path
      (Keeper_approval_queue.install_error_to_string error)
  | Ok report ->
    Log.Server.info
      "keeper_gate: installed durable queue base_path=%s pending=%d replayed=%d replay_failed=%d"
      base_path
      report.loaded_pending
      report.replayed_deliveries
      (List.length report.delivery_replay_failures);
    List.iter
      (fun (failure : Keeper_approval_queue.delivery_replay_failure) ->
         Log.Server.error
           "keeper_gate: durable delivery replay failed approval=%s error=%s"
           failure.approval_id
           failure.reason)
      report.delivery_replay_failures;
    let resume_report = Keeper_gate.resume_persisted_auto_judges ~base_path in
    Log.Server.info
      "keeper_gate: recovered Auto Judge work requested=%d started=%d finalized=%d skipped=%d failed=%d"
      resume_report.requested
      (List.length resume_report.started_ids)
      (List.length resume_report.finalized_ids)
      (List.length resume_report.skipped_ids)
      (List.length resume_report.failures);
    List.iter
      (fun approval_id ->
         Log.Server.warn
           "keeper_gate: recovered Auto Judge no longer startable approval=%s"
           approval_id)
      resume_report.skipped_ids;
    List.iter
      (fun (failure : Keeper_gate.auto_judge_resume_failure) ->
         Log.Server.error
           "keeper_gate: recovered Auto Judge start failed approval=%s error=%s"
           failure.approval_id
           failure.reason)
      resume_report.failures
;;

let activate_owner_state
      ~sw
      ~clock
      ~net
      ~domain_mgr
      ~proc_mgr
      (initialized : initialized_owner_state)
  =
  let state = initialized.state in
  (* Establish the complete barrier before the irreversible ownership commit.
     Gate restore, claim, and start stay ordered inside one transport-neutral
     function. Each composition root publishes readiness only after its own
     required transport surfaces are installed. *)
  install_keeper_gate_persistence state;
  start_owner_lazy_tasks ~sw state;
  claim_and_start_keeper_persistence
    ~prepared_persistence:initialized.prepared_keeper_persistence
    ~sw
    ~clock
    ~net
    ~domain_mgr
    ~proc_mgr
    state;
  let base_dir = (Mcp_server.workspace_config state).base_path in
  (match Fusion_config_loader.load ~base_path:base_dir with
   | Error detail ->
     Log.Server.error "fusion recovery policy unavailable: %s" detail
   | Ok policy ->
     let report = Fusion_tool.recover_required ~sw ~net ~base_dir ~policy in
     Log.Server.info "fusion recovery started=%d failed=%d" report.started
       (List.length report.failures);
     List.iter
       (fun (operation_id, error) ->
          Log.Server.error "fusion recovery operation=%s error=%s" operation_id
            (Fusion_tool.recovery_failure_to_string error))
       report.failures);
  { state
  ; path_diagnostics = initialized.path_diagnostics
  ; domain_pool = initialized.domain_pool
  }
;;

(* bootstrap_keepers removed: the keeper_autoboot subsystem in
   start_keeper_loops now handles keeper startup in a dedicated
   fiber with a 5-second delay, avoiding runtime bootstrap contention with
   the 7+ dashboard refresh loops that start alongside it. *)

let run ~sw ~env ~host ~port ~base_path ?input_base_path ~make_routes ~make_request_handler
    ~make_h2_request_handler ~make_h2_error_handler () =
  let clock, mono_clock, net, domain_mgr, proc_mgr, fs =
    init_runtime_context env
  in
  Rate_limit.start_global_cleanup_loop ~sw ~clock;
  (* 1. HTTP socket first — Railway healthcheck can reach /health immediately *)
  let config = Server_bootstrap_http.make_http_config ~host ~port in
  (* The listener identity comes only from the effective CLI/bootstrap config
     above.  A public identity is additional trust only when the operator
     explicitly configured MASC_HTTP_BASE_URL; deriving it again from env
     MASC_HOST/MASC_HTTP_PORT would diverge from CLI overrides and could admit
     a host/port on which this process is not listening. *)
  let explicit_base_url = Env_config_core.masc_http_base_url_opt () in
  let request_trust_policy =
    match
      Server_request_authority.make_trust_policy
        ~bind_host:config.host
        ~bind_port:config.port
        ~explicit_base_url
    with
    | Ok policy -> policy
    | Error error ->
      raise
        (Env_config_core.Config_error
           (Server_request_authority.trust_policy_error_to_string error))
  in
  let background_request_authority =
    Server_request_authority.projection_context request_trust_policy
  in
  let routes = make_routes ~port:config.port ~host:config.host ~sw ~clock in
  let request_handler = make_request_handler ~trust_policy:request_trust_policy routes in
  let h2_request_handler =
    make_h2_request_handler
      ~trust_policy:request_trust_policy
      ~sw
      ~clock
      ~server_start_time
  in
  let h2_error_handler = make_h2_error_handler () in
  let http_mode =
    match Env_config.Transport.use_h2 () with
    | Env_config.Transport.H2_only -> `H2_only
    | Env_config.Transport.H1_only -> `H1_only
    | Env_config.Transport.Auto
    | Env_config.Transport.Unknown_h2_mode _ -> `Auto
  in
  let socket = Server_bootstrap_http.listen_socket ~sw ~net config in
  let initial_backend_mode = "filesystem" in
  Transport_metrics.set_ws_same_origin_runtime_ready false;
  server_state := None;
  Server_startup_state.reset ~backend_mode:initial_backend_mode ();

  (* 2. Run owner initialization outside the accept loop. The state and
     long-lived owner fibers attach to the parent switch because HTTP request
     handlers use them after this setup fiber returns. A pre-readiness failure
     exits immediately rather than leaving that partial owner alive; only an
     auxiliary failure after readiness may continue as degraded serving. *)
  Eio.Fiber.fork ~sw (fun () ->
    let handle_initialization_failure error =
      match
        startup_failure_disposition
          ~state_ready:Server_startup_state.(!state).state_ready
      with
      | Fatal_pre_ready ->
        Log.Server.error
          "[FATAL] Critical startup failed before readiness; refusing partial BasePath ownership: %s"
          error;
        exit 1
      | Degraded_after_ready ->
        Server_startup_state.mark_degraded ~error;
        Log.Server.error
          "Auxiliary initialization failed after readiness (HTTP remains available in degraded state): %s"
          error
    in
    try
      Server_startup_state.mark_blocking ~backend_mode:initial_backend_mode;
      let initialized_owner =
        initialize_owner_state_blocking ~sw ~env ~base_path ?input_base_path
          ~clock ~mono_clock ~net ~domain_mgr ~proc_mgr ~fs ()
      in
      let activated_owner =
        activate_owner_state
        ~sw
        ~clock
        ~net
        ~domain_mgr
        ~proc_mgr
        initialized_owner
      in
      let state = activated_owner.state in
      (* Authentication wrappers treat [server_state = Some _] as the mutation
         capability boundary. Publish only after transport-neutral activation
         has restored Gate state and started the owner persistence lanes. *)
      server_state := Some state;
      (* Global readiness is the transport-neutral owner capability, not a
         quorum over optional transports. Mark it before starting fallible
         Discord/gRPC/WS/WebRTC/dashboard auxiliaries so one transport cannot
         turn an already-published HTTP owner into a process-wide fatal
         pre-readiness failure. Each auxiliary owns its typed health state. *)
      (match mark_owner_state_ready state with
       | Ok () -> ()
       | Error error -> raise (Owner_initialization_failed error));
      let path_diagnostics = activated_owner.path_diagnostics in
      let resolved_base, masc_dir =
        Server_bootstrap_loops.start_background_maintenance ~sw ~clock ~env state
      in
      (* RFC-0203 Phase 3: in-process Discord gateway replaces the
         deleted sidecars/discord-bot/ Python connector. Always-on:
         if DISCORD_BOT_TOKEN is unset the start function logs a
         warning and skips, leaving the server otherwise unaffected. *)
      Server_discord_in_process_gateway.start ~sw ~env ~clock ~state;
      (* RFC-0317 PR-3: in-process Slack Socket Mode gateway, mirroring the
         Discord one. Off unless SLACK_APP_TOKEN is set; the start function
         logs a warning and skips otherwise, leaving the server unaffected. *)
      Server_slack_in_process_gateway.start ~sw ~env ~state;
      Server_bootstrap_http.print_startup_banner ~config ~resolved_base ~base_path
        ~masc_dir ~path_diagnostics;
      (* Dashboard owns only its executor projection; the shared pool itself
         belongs to the transport-neutral owner bootstrap so stdio Keepers get
         the same offload behavior. *)
      Server_dashboard_http.set_executor_pool
        (Domain_pool.executor_pool activated_owner.domain_pool);
      (* Auxiliary transports start after owner readiness and report their own
         availability. They must not gain lifecycle authority over HTTP or
         unrelated Keeper lanes. *)
      (* gRPC workspace transport (default-on, opt-out via MASC_GRPC_ENABLED=0) *)
      let tool_dispatcher tool_name args_json =
        let arguments =
          try Yojson.Safe.from_string args_json
          with Yojson.Json_error _ -> `Assoc []
        in
        let workspace_scope = Mcp_server.workspace_scope state in
        let result =
          Mcp_server_eio_execute.execute_tool_eio
            ~sw
            ~clock
            ~workspace_scope
            state
            ~name:tool_name ~arguments
        in
        let success = Tool_result.is_success result
        and result_str = Tool_result.message result
        in
        if not success then
          Log.Server.error "gRPC tool call failed: tool=%s error_bytes=%d"
            tool_name (String.length result_str);
        if success then Ok result_str else Error result_str
      in
      Masc_grpc_server.start ~sw ~env ~workspace_config:(Mcp_server.workspace_config state)
        ~tool_dispatcher;
      (* Initialize gRPC client for keeper heartbeat when transport is gRPC *)
      (match Masc_grpc_transport.from_env () with
       | Masc_grpc_transport.Grpc ->
           (try
              let client = Masc_grpc_client.create_from_env ~sw ~env in
              Keeper_grpc_heartbeat.set_grpc_client ~env client;
              Log.Server.info "gRPC keeper client initialized"
            with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
              Log.Server.warn "gRPC keeper client init failed: %s"
                (Printexc.to_string exn))
       | Http | Ws | Webrtc | Local -> ());
      Server_mcp_transport_ws.set_dashboard_snapshot_provider (function
        | "shell" ->
            Some
              (Server_dashboard_http.dashboard_shell_payload_json ~light:true
                 (Mcp_server.workspace_config state))
        | "execution" ->
            Some (Server_dashboard_http.dashboard_execution_snapshot_json ())
        | "operator" ->
            Some
              (`Assoc
                [
                  ( "snapshot",
                    Server_dashboard_http.cached_surface_json
                      Server_dashboard_http.operator_snapshot_cache );
                  ( "digest",
                    Server_dashboard_http.cached_surface_json
                      Server_dashboard_http.operator_digest_cache );
                ])
        | "transport" ->
            Some (Server_dashboard_http.dashboard_transport_health_snapshot_json ())
        | "namespace" ->
            Server_dashboard_http.namespace_truth_snapshot_from_caches state
        | "composite" ->
            Some
              (Server_dashboard_http.dashboard_fleet_composite_json
                 ~config:(Mcp_server.workspace_config state) ())
        | "board" ->
            Some
              (Server_dashboard_http.dashboard_board_json
                 ~sort_by:Board_dispatch.Recent ~exclude_system:true
                 ~limit:100 ~offset:0 ())
        | "goals" ->
            Some
              (Server_dashboard_http.dashboard_goals_snapshot_json
                 ~config:(Mcp_server.workspace_config state))
        | "ide" ->
            Some
              (Server_dashboard_http.dashboard_ide_snapshot_json
                 ~config:(Mcp_server.workspace_config state))
        | _ ->
            None);
      let dispatch_ws_inbound_message ws_session_id body_str =
          let jsonrpc_id_opt body =
            match Yojson.Safe.from_string body with
            | `Assoc fields -> (
                match List.assoc_opt "id" fields with
                | Some ((`Int _ | `String _ | `Null) as id) -> Some id
                | Some _ -> Some `Null
                | None -> None)
            | _ -> None
            | exception _ -> None
          in
          let send_overloaded_response rejection =
            Log.Server.debug
              "WS inbound dispatch rejected: session=%s reason=%s in_flight=%d limit=%d"
              ws_session_id
              rejection.Server_mcp_transport_ws.reason
              rejection.in_flight
              rejection.limit;
            match jsonrpc_id_opt body_str with
            | None -> ()
            | Some id ->
                let response_json =
                  `Assoc
                    [
                      ("jsonrpc", `String "2.0");
                      ("id", id);
                      ( "error",
                        `Assoc
                          [
                            ("code", `Int (-32000));
                            ( "message",
                              `String
                                "WebSocket inbound dispatch limit exceeded" );
                            ( "data",
                              `Assoc
                                [
                                  ("reason", `String rejection.reason);
                                  ("limit", `Int rejection.limit);
                                  ("in_flight", `Int rejection.in_flight);
                                ] );
                          ] );
                    ]
                in
                let response_str = Yojson.Safe.to_string response_json in
                ignore
                  (Server_mcp_transport_ws.send_to_session_result
                     ws_session_id response_str)
          in
          match Server_mcp_transport_ws.try_begin_inbound_dispatch ws_session_id with
          | Server_mcp_transport_ws.Inbound_dispatch_session_gone ->
              Log.Server.debug
                "WS inbound dispatch dropped: session=%s gone before dispatch"
                ws_session_id
          | Server_mcp_transport_ws.Inbound_dispatch_rejected rejection ->
              send_overloaded_response rejection
          | Server_mcp_transport_ws.Inbound_dispatch_admitted session ->
              Eio.Fiber.fork ~sw (fun () ->
                Eio_guard.protect
                  ~finally:(fun () ->
                    Server_mcp_transport_ws.finish_inbound_dispatch session)
                  (fun () ->
                    try
                      let response_json =
                        Mcp_eio.handle_request ~clock ~sw
                          ~mcp_session_id:ws_session_id state body_str
                      in
                      let response_str = Yojson.Safe.to_string response_json in
                      if response_str <> "null" then begin
                        (* #10648: split the single conflated WARN into two paths so
                           operators can distinguish "client disconnected" (expected,
                           noise) from "transport write failed" (real bug warranting
                           attention). *)
                        match
                          Server_mcp_transport_ws.send_to_session_result
                            ws_session_id response_str
                        with
                        | Sent -> ()
                        | Session_gone ->
                            Log.Server.debug
                              "WS send dropped: session=%s gone (client disconnected, \
                               expected)"
                              ws_session_id
                        | Send_failed ->
                            Log.Server.warn
                              "WS send_to_session WRITE FAILED for session=%s \
                               (transport-side error; session cleaned up)"
                              ws_session_id
                      end
                    with
                    | Eio.Cancel.Cancelled _ as e -> raise e
                    | exn ->
                      Log.Server.warn "WS dispatch error %s: %s" ws_session_id (Printexc.to_string exn)))
      in
      Server_mcp_transport_ws.set_inbound_message_handler
        dispatch_ws_inbound_message;
      Transport_metrics.set_ws_same_origin_runtime_ready true;
      (* Standalone WebSocket transport (enabled by default, opt-out via MASC_WS_ENABLED=0) *)
      Server_ws_standalone.start ~sw ~env
        ~on_message:Server_mcp_transport_ws.dispatch_inbound_message;
      (* WebRTC DataChannel transport (enabled by default, opt-out via MASC_WEBRTC_ENABLED=0) *)
      if Server_webrtc_transport.is_enabled () then (
        Log.Server.info "WebRTC DataChannel transport enabled";
        Server_webrtc_transport.set_message_handler
          (fun peer_id body_str ->
            Eio.Fiber.fork ~sw (fun () ->
              try
                let response_json =
                  Mcp_eio.handle_request ~clock ~sw
                    ~mcp_session_id:peer_id state body_str
                in
                let response_str = Yojson.Safe.to_string response_json in
                if response_str <> "null" then begin
                  match
                    Server_webrtc_transport.send_to_peer peer_id response_str
                  with
                  | Ok _bytes -> ()
                  | Error e ->
                    Log.Server.warn
                      "WebRTC send_to_peer dropped response for peer=%s: %s"
                      peer_id e
                end
              with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | exn ->
                Log.Server.warn "WebRTC dispatch error %s: %s"
                  peer_id (Printexc.to_string exn)));
        Server_webrtc_transport.set_connection_starter
          (fun peer_id ->
            Server_webrtc_transport.start_webrtc_connection ~sw ~env peer_id));
      (* Register transport providers for unified bridge *)
      Transport_bridge.register_provider (module struct
        let name = "sse"
        let protocol = Transport.Sse
        let is_enabled () = true  (* SSE is always enabled *)
        let session_count () = Sse.client_count ()
        let status_json () = `Assoc [
          "clients", `Int (Sse.client_count ());
          "external_subscribers", `Int (Sse.external_subscriber_count ());
        ]
        let reap_stale () = List.length (Sse.cleanup_stale ())
      end);
      Transport_bridge.register_provider (module struct
        let name = "ws"
        let protocol = Transport.Ws
        let is_enabled () = Server_ws_standalone.is_enabled ()
        let session_count () = Server_mcp_transport_ws.session_count ()
        let status_json () = `Assoc [
          "port", `Int (Server_ws_standalone.configured_port ());
          "sessions", `Int (Server_mcp_transport_ws.session_count ());
        ]
        let reap_stale () = 0  (* WS sessions self-clean on disconnect *)
      end);
      Transport_bridge.register_provider (module struct
        let name = "grpc"
        let protocol = Transport.Grpc
        let is_enabled () = Masc_grpc_server.is_enabled ()
        let session_count () = 0  (* gRPC uses per-call, no persistent sessions *)
        let status_json () = `Assoc [
          "port", `Int (Masc_grpc_server.configured_port ());
          "service", `String Masc_grpc_service.service_name;
        ]
        let reap_stale () = 0
      end);
      Transport_bridge.register_provider (module struct
        let name = "webrtc"
        let protocol = Transport.Webrtc
        let is_enabled () = Server_webrtc_transport.is_enabled ()
        let session_count () = Server_webrtc_transport.live_webrtc_count ()
        let status_json () = `Assoc [
          "active_peers", `Int (Server_webrtc_transport.active_peer_count ());
          "live_connections", `Int (Server_webrtc_transport.live_webrtc_count ());
          "connected_channels", `Int (Server_webrtc_transport.connected_channel_count ());
        ]
        let reap_stale () = 0  (* WebRTC has its own ICE timeout *)
      end);
      Transport_bridge.seal ();
      (* Cold-start warm-cache stagger is handled by warm_delay_s in each
         Proactive_refresh config. Heavy surfaces delay their initial warm
         compute to avoid concurrent CPU/PG contention.  Lightweight surfaces
         (execution, transport_health) start immediately. *)
      Server_dashboard_http.start_execution_refresh_loop ~state ~sw ~clock ~net ~mono_clock;
      Server_dashboard_http.start_transport_health_refresh_loop ~state ~sw ~clock;
      Server_dashboard_http.start_execution_trust_refresh_loop ~state ~sw ~clock;
      Server_dashboard_http.start_mission_refresh_loop ~state ~sw ~clock;
      Server_dashboard_http.start_operator_snapshot_refresh_loop ~state ~sw ~clock;
      Server_dashboard_http.start_operator_digest_refresh_loop ~state ~sw ~clock;
      (* RFC-0284: push goal-loop OODA status over SSE on change so the panel
         stops polling. The worker is out-of-process (Python), so the trigger
         is this server-side tick reading the cached status.json. *)
      Server_dashboard_http_goal_loop_broadcast.start_goal_loop_refresh_loop
        ~state ~sw ~clock;
      (* Pre-warm shell cache in a separate fiber so it cannot block
         lazy startup tasks or later keeper loop startup
         (#keeper-bootstrap-stuck). *)
      Atomic.set Server_dashboard_http.shell_warming true;
      Eio.Fiber.fork ~sw (fun () ->
        let outer_timeout_sec =
          Env_config_runtime.Dashboard.shell_prewarm_outer_timeout_sec
        in
        (try
           match Eio.Time.with_timeout clock outer_timeout_sec (fun () ->
             Server_dashboard_http.warm_shell_cache state;
             Ok ())
           with
           | Ok () -> ()
           | Error `Timeout ->
             Log.Dashboard.warn "shell cache pre-warm timed out (%.1fs)"
               outer_timeout_sec
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
             Log.Dashboard.warn "shell cache pre-warm failed: %s"
             (Printexc.to_string exn));
        (* Full-health scans are heavier than the probe path. Start them after
           shell prewarm has either succeeded or exhausted its own budget so
           cold-start diagnostics do not contend with the shell's first render. *)
        Server_routes_http_runtime.start_full_health_snapshot_refresh_loop
          ~sw
          ~clock
          ~request_authority:background_request_authority);
      ()
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | Owner_initialization_failed error ->
      handle_initialization_failure (owner_initialization_error_to_string error)
    | exn ->
      handle_initialization_failure (Printexc.to_string exn));

  (* 2b. Startup watchdog: if init does not reach state_ready within timeout,
     log and exit so external process managers can restart the server.
     Prevents zombie-listener state where the socket is open but HTTP
     requests hang because init is stuck. *)
  Eio.Fiber.fork ~sw (fun () ->
    try
      let timeout_sec = Server_startup_state.watchdog_timeout_sec () in
      Eio.Time.sleep clock timeout_sec;
      let current = Server_startup_state.(!state) in
      if not current.state_ready then (
        let elapsed = Server_startup_state.elapsed_since_start () in
        Log.Server.error
          "[watchdog] Server init did not complete within %.0fs (elapsed=%.1fs, phase=%s, backend=%s). Exiting."
          timeout_sec elapsed
          (Server_startup_state.phase_to_string current.phase)
          current.backend_mode;
        exit 1)
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Server.error "startup watchdog fiber failed: %s"
        (Printexc.to_string exn));

  (* 3. Start serving -- /health responds before init completes *)
  let addr_label = Printf.sprintf "%s:%d" config.host config.port in
  match http_mode with
  | `H2_only ->
    Server_bootstrap_http.serve_h2 ~sw ~clock ~socket ~addr_label
      ~h2_request_handler ~h2_error_handler
  | `H1_only ->
    Server_bootstrap_http.serve ~sw ~clock ~socket ~addr_label ~request_handler
  | `Auto ->
    Server_bootstrap_http.serve_auto ~sw ~clock ~socket ~addr_label
      ~request_handler ~h2_request_handler ~h2_error_handler
