
open Server_auth
open Server_routes_http

module Mcp_server = Mcp_server
module Mcp_eio = Mcp_server_eio
module Config_root_bootstrap = Server_runtime_config_root_bootstrap

let force_jsonl_fallback_env () =
  Unix.putenv Env_config_core.storage_type_env_key "filesystem"

let requested_backend_mode () =
  Env_config_core.storage_type ()

let storage_enforcement_fallback_reason ~requested ~effective =
  let requested = requested |> String.trim |> String.lowercase_ascii in
  let effective = effective |> String.trim |> String.lowercase_ascii in
  if requested = "" || String.equal requested effective then
    None
  else
    Some
      (Printf.sprintf
         "MASC_STORAGE_TYPE=%s requested; filesystem-only bootstrap enforced as %s"
         requested effective)

let note_storage_enforcement_fallback ~requested ~effective =
  match storage_enforcement_fallback_reason ~requested ~effective with
  | Some reason -> Server_startup_state.note_fallback reason
  | None -> ()

let config_bootstrap_mode = Config_root_bootstrap.config_bootstrap_mode
let bootstrap_base_path_config_root = Config_root_bootstrap.bootstrap_base_path_config_root
let startup_config_resolution = Config_root_bootstrap.startup_config_resolution

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
    let gc_space_overhead =
      try int_of_string (Sys.getenv "MASC_GC_SPACE_OVERHEAD")
      with Not_found -> 100
    in
    let ctrl = get () in
    set { ctrl with
      minor_heap_size = 2 * 1024 * 1024;  (* 2M words = 16MB on 64-bit; reduces minor->major promotion rate *)
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
  (* MASC_MODEL_CATALOG as convenience alias for OAS_MODEL_CATALOG.
     OAS auto-discovers from ~/.masc/config/models.toml, cwd parents,
     and $OAS_MODEL_CATALOG. Setting MASC_MODEL_CATALOG forwards it
     so masc operators don't need to know OAS internals.
     OAS lazily loads the catalog on first model capability query. *)
  (match Sys.getenv_opt "MASC_MODEL_CATALOG" with
   | Some path when Sys.getenv_opt "OAS_MODEL_CATALOG" = None ->
     Unix.putenv "OAS_MODEL_CATALOG" path;
     Log.Misc.info "model_catalog: MASC_MODEL_CATALOG=%s forwarded to OAS" path
   | Some _ ->
     Log.Misc.info "model_catalog: OAS_MODEL_CATALOG already set, MASC_MODEL_CATALOG ignored"
   | None ->
     ());
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

let create_server_state ~sw ~base_path ~clock ~mono_clock ~net ~proc_mgr ~fs
    ?env ()
    : Mcp_server.server_state =
  let input_base_path =
    match String.trim base_path with
    | "" -> None
    | raw -> Some raw
  in
  let base_path = Env_config_core.normalize_masc_base_path_input base_path in
  Fs_compat.set_fs fs;
  Mcp_eio.set_net net;
  Mcp_eio.set_clock clock;
  Eio_context.set_switch sw;
  Eio_context.set_net net;
  Eio_context.set_clock clock;
  Eio_context.set_mono_clock mono_clock;
  (* RFC-0107 Phase D.2c — record full Eio.Stdenv for piaf-backed
     Pool in Masc_http_client.  Optional: tests / pre-bootstrap
     callers may omit [env], in which case Pool falls back to a
     stub (request returns Error). *)
  Option.iter Eio_context.set_env env;
  force_jsonl_fallback_env ();
  Process_eio.init ~cwd_default:Eio.Path.(fs / base_path) ~proc_mgr ~clock;
  Exec_tap.install_from_env ();
  Unix.putenv
    Env_config_core.base_path_input_env_key
    (Option.value ~default:"" input_base_path);
  Unix.putenv Env_config_core.base_path_env_key base_path;
  bootstrap_base_path_config_root ~base_path;
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
       Log.Server.warn "runtime.toml load failed: %s (continuing with env defaults)" msg);
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
  let path_diagnostics =
    Server_base_path_diagnostics.detect
      ?input_base_path
      ?env_masc_base_path:((Host_config.from_env ()).base_path_raw)
      ~effective_base_path:state.workspace_config.base_path
      ~effective_masc_root:(Workspace.masc_root_dir state.workspace_config)
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
  Server_base_path_diagnostics.detect
    ?input_base_path
    ?env_masc_base_path:((Host_config.from_env ()).base_path_raw)
    ~effective_base_path:state.workspace_config.base_path
    ~effective_masc_root:(Workspace.masc_root_dir state.workspace_config)
    ()

let restore_persisted_sessions (state : Mcp_server.server_state) =
  Session.restore_from_disk state.session_registry
    ~agents_path:(Workspace.agents_dir state.workspace_config)

let reconcile_active_agents_gauge (state : Mcp_server.server_state) =
  Otel_metric_store.reconcile_active_agents_gauge (Workspace.masc_dir state.workspace_config)


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
  let (_init_msg : string) = Workspace.init state.workspace_config ~agent_name:None in
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
        task_names =
          [
            "jsonl_prune";
            "auth_archive_prune";
          ];
      };
    ]
  in
  initial_groups @ cleanup_groups

let lazy_startup_task_names () =
  lazy_startup_plan ()
  |> List.concat_map (fun group -> group.task_names)

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
  Config_dir_resolver.log_warnings ~context:"ServerBootstrap" ();
  Config_dir_resolver.log_resolution ~context:"ServerBootstrap" ();
  (* Converge runtime prompt markdown onto the binary-embedded assets
     before the registry scans the directory (#20929: merged prompt edits
     never reached the runtime dir otherwise). *)
  sync_prompt_assets_from_binary ();
  (* Initialize prompt registry with defaults and restore saved overrides *)
  let prompt_markdown_dir =
    Prompt_defaults.bootstrap_runtime
      ~workspace_path:state.workspace_config.workspace_path
      ~base_path:state.workspace_config.base_path
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
       Telemetry_eio.summarize_tool_usage state.workspace_config
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
       ~base_path:state.workspace_config.base_path in
     if n > 0 then
       Log.Misc.info "tool metrics: restored %d records from disk" n
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     Log.Misc.warn "tool metrics restore failed: %s (metrics empty until next emission)"
       (Printexc.to_string exn))

(* bootstrap_keepers removed: the keeper_autoboot subsystem in
   start_keeper_loops now handles keeper startup in a dedicated
   fiber with a 5-second delay, avoiding runtime bootstrap contention with
   the 7+ dashboard refresh loops that start alongside it. *)

let run ~sw ~env ~host ~port ~base_path ~make_routes ~make_request_handler
    ~make_h2_request_handler ~make_h2_error_handler =
  let clock, mono_clock, net, domain_mgr, proc_mgr, fs =
    init_runtime_context env
  in

  (* Initialize Eio environment for MODEL HTTP calls (cohttp-eio via OAS Provider) *)
  Masc_eio_env.init ~sw ~net ~clock ();
  Discovery_cache.set_env ~sw ~net;
  Discovery_cache.set_base_path base_path;
  (* Start global rate-limit bucket cleanup loop to prevent unbounded growth of
     per-client buckets.  The loop is a background fiber that wakes periodically
     and removes stale entries according to MASC_RATE_LIMIT_ENTRY_MAX_AGE_SEC. *)
  Rate_limit.start_global_cleanup_loop ~sw ~clock;
  (* PR-0.2.D: OCaml runtime GC sampler.  Polls Gc.quick_stat every
     30s and writes six masc_gc_* gauges so the telemetry backend can
     answer GC pressure questions without a separate dump endpoint.
     quick_stat does not walk the heap, so the call cost stays
     bounded next to the request path. *)
  Gc_sampler.run ~sw ~clock ~interval:30.0;
  (* Background fiber: flush dirty tool-usage persistence every 5 seconds.
     Avoids per-tool-call disk I/O in the hot path. *)
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      Eio.Time.sleep clock 5.0;
      (try Keeper_registry_tool_usage_persistence.flush_all_dirty ()
       with Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Log.Keeper.warn "tool_usage flush_all_dirty failed: %s"
           (Printexc.to_string exn));
      loop ()
    in
    loop ());
  (* Background fiber: flush pending trajectory entries every 2 seconds.
     Batches per-tool-call JSONL writes to reduce disk I/O. *)
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      Eio.Time.sleep clock 2.0;
      (try Trajectory.flush_all_pending ()
       with Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Log.Keeper.warn "trajectory flush_all_pending failed: %s"
           (Printexc.to_string exn));
      loop ()
    in
    loop ());
  (* 1. HTTP socket first — Railway healthcheck can reach /health immediately *)
  let config = Server_bootstrap_http.make_http_config ~host ~port in
  let routes = make_routes ~port:config.port ~host:config.host ~sw ~clock in
  let request_handler = make_request_handler routes in
  let h2_request_handler =
    make_h2_request_handler ~sw ~clock ~server_start_time
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
  let requested_backend_mode_before_enforcement = requested_backend_mode () in
  force_jsonl_fallback_env ();
  let initial_backend_mode = requested_backend_mode () in
  server_state := None;
  Server_startup_state.reset ~backend_mode:initial_backend_mode ();
  note_storage_enforcement_fallback
    ~requested:requested_backend_mode_before_enforcement
    ~effective:initial_backend_mode;

  (* 2. All init in background fiber — protected so failures don't kill HTTP *)
  Eio.Fiber.fork ~sw (fun () ->
    let governance_level = Env_config_core.governance_level () in
    let init_state_blocking () =
      let t0 = Eio.Time.now clock in
      (* Install the LLM provider metrics bridge BEFORE any subsystem
         that might issue an LLM call.  Placed here — before server
         state creation — so it is impossible for an init-time LLM
         call (e.g. a warmup probe, early keeper fiber) to capture
         the default noop sink instead of the Otel_metric_store-backed one. *)
      Llm_metric_bridge.install ();
      Llm_metric_bridge.init ~base_path;
      Log.Server.info "Llm_metric_bridge installed (masc_llm_provider_http_status_total, inference-events JSONL)";
      (* #13885: install backend mutex observers from the top-level
         masc layer.  Backend/workspace sub-libraries cannot depend on
         Otel_metric_store without creating dependency cycles, but the global
         observer refs can be wired before any FileSystem backend writes. *)
      Backend.FileSystem.set_mutex_observers
        ~acquire:(fun ~op ~seconds ->
          Otel_metric_store.observe_histogram
            Otel_metric_store.metric_backend_mutex_acquire_sec
            ~labels:[ ("op", op) ]
            seconds)
        ~held:(fun ~op ~seconds ->
          Otel_metric_store.observe_histogram
            Otel_metric_store.metric_backend_mutex_held_sec
            ~labels:[ ("op", op) ]
            seconds);
      Log.Server.info "Backend_mutex_metrics installed (masc_backend_mutex_* metrics)";
      Fd_accountant.set_pressure_hooks
        ~active:Keeper_fd_pressure.active
        ~nofile_soft_limit:Keeper_fd_pressure.process_nofile_soft_limit;
      Log.Server.info "Fd_accountant pressure hooks installed";
      (* Forward Agent_sdk.Log records (per-turn timing from oas#816 and
         any subsequent structured emits) into the masc log ring so
         they land in <base_path>/.masc/logs/system_log_*.jsonl alongside
         masc's own records.  Without this, OAS's structured Log
         global sink registry is empty and every Log.info inside
         agent_sdk is a silent drop. *)
      Agent_sdk_log_bridge.install ();
      Log.Server.info "Agent_sdk_log_bridge installed (agent_sdk.Log -> masc structured log)";
      let state =
        create_server_state ~sw ~base_path ~clock ~mono_clock ~net ~proc_mgr
          ~fs ~env ()
      in
      (* Initialize the default Runtime singleton from runtime TOML.
         Must happen after Config_dir_resolver is set up (inside
         create_server_state) and before any runtime name resolution.

         fail-fast: a missing config path or a missing/broken [runtime].default
         is fatal — the server cannot route turns without a default Runtime, so
         booting into a half-configured state only defers the failure to the
         first turn (runtime→Runtime vision: no silent fallback). *)
      (match Runtime.config_path () with
       | Some config_path ->
         (match Runtime.init_default ~config_path with
          | Ok () ->
            Log.Server.info "Runtime default initialized: %s"
              (Runtime.get_default_runtime_id ())
          | Error msg ->
            Log.Server.error
              "Runtime.init_default failed (fatal, refusing to boot): %s" msg;
            exit 1)
       | None ->
         Log.Server.error
           "No runtime config path; cannot initialize default Runtime \
            (fatal, refusing to boot)";
         exit 1);
      let t1 = Eio.Time.now clock in
      Log.Server.info "State created (runtime state) in %.1fs" (t1 -. t0);
      bootstrap_server_state_blocking state;
      sync_admin_token_env state;
      sync_internal_keeper_token_env state;
      sync_bootable_keeper_credentials state;
      let path_diagnostics =
        runtime_path_diagnostics ~input_base_path:base_path state
      in
      Server_base_path_diagnostics.log_startup_warning path_diagnostics;
      if Server_base_path_diagnostics.startup_should_abort path_diagnostics then begin
        Log.Server.error "%s\nStartup guard rejected malformed runtime state."
          (Option.value path_diagnostics.warning
             ~default:
               "startup guard triggered without a diagnostic warning");
        exit 1
      end;
      if Server_base_path_diagnostics.strict_violation path_diagnostics then begin
        Log.Server.error "%s\nBase-path strict mode rejected the resolved runtime path configuration."
          (Option.value path_diagnostics.warning
             ~default:
               "strict base-path guard triggered without a diagnostic warning");
        exit 1
      end;
      Governance_registry.ensure_init ();
      Runtime_params.restore ~base_path;
      Log.Server.info "Runtime_params restored from %s" base_path;
      Keeper_crash_persistence.start_drain_fiber ~sw ~clock;
      (* #10130: sweep [save_file_atomic] orphan temp files left by
         SIGKILL'd or ENFILE-crashed prior processes.  Zero-byte
         orphans are deleted; non-zero orphans (evidence of silent
         atomic-save data loss) are preserved in
         [<base_path>/.recovered/] for forensic inspection.  Always
         runs at boot so each restart publishes fresh cleanup
         counters.

         #10205 finding 5: the sweep walks every keeper subdirectory
         under [base_path] ([Sys.readdir] per directory + [Unix.stat]
         per orphan candidate).  It does NOT need to gate
         [install_tooling] or the [Bootstrap completed] log line —
         the sweep results are advisory diagnostics, not a
         precondition for serving.  Fork it into a background fiber
         so the boot hot path completes immediately; the counter
         and WARN publish asynchronously, which is the right shape
         for operator dashboards (delta-from-zero, not synchronous
         readback). *)
      Eio.Fiber.fork ~sw (fun () ->
        try
          let deleted, preserved =
            Fs_compat.cleanup_atomic_orphans ~base_path ()
          in
          if deleted > 0 then
            Otel_metric_store.inc_counter
              Otel_metric_store.metric_fs_atomic_orphans_cleaned
              ~labels:[ ("size_class", Atomic_orphan_size_class.(to_label Empty)) ]
              ~delta:(float_of_int deleted)
              ();
          if preserved > 0 then
            Otel_metric_store.inc_counter
              Otel_metric_store.metric_fs_atomic_orphans_cleaned
              ~labels:[ ("size_class", Atomic_orphan_size_class.(to_label With_data)) ]
              ~delta:(float_of_int preserved)
              ();
          if deleted + preserved > 0 then
            Log.Server.warn
              "boot: cleaned %d save_file_atomic orphans (%d empty, \
               %d preserved with data in .recovered/ — see #10130)"
              (deleted + preserved) deleted preserved
        with Eio.Cancel.Cancelled _ as e -> raise e
           | exn ->
             Log.Server.error
               "boot: atomic orphan sweep failed: %s"
               (Printexc.to_string exn));
      (* #9786: audit credential store for shared bearer tokens.
         When two credentials hash to the same token,
         [find_credential_by_token] silently routes to the FIRST
         match — which is exactly the [bearer token belongs to X]
         rejection observed when the second agent's name does not
         match the first agent's credential.  Surface the
         duplicate at boot so operators can rotate tokens before
         requests start failing. *)
      (try
         let groups = Auth.audit_token_uniqueness base_path in
         List.iter
           (fun (token_hash_prefix, agent_names) ->
             Otel_metric_store.inc_counter
               Otel_metric_store.metric_auth_credential_token_duplicate
               ~labels:[ ("token_hash_prefix", token_hash_prefix) ]
               ();
             Log.Server.warn
               "#9786 credential token shared by %d agents \
                [%s] (token_hash_prefix=%s) — rotate via \
                Auth.create_token to prevent bearer-token routing \
                ambiguity"
               (List.length agent_names)
               (String.concat ", " agent_names)
               token_hash_prefix)
           groups
       with Eio.Cancel.Cancelled _ as e -> raise e
          | exn ->
            Log.Server.error
              "boot: credential token uniqueness audit failed: %s"
              (Printexc.to_string exn));
      let t2 = Eio.Time.now clock in
      Log.Server.info "Bootstrap completed in %.1fs" (t2 -. t1);
      (* 2026-05-05 deploy-gap audit (#12943 follow-up): warn loudly when
         the running binary is more than [stale_threshold_hours] behind
         the build-env commit timestamp.  Runtime repo HEAD is intentionally
         ignored here: it is checkout truth, not proof that this executable
         was rebuilt from that commit. *)
      let stale_threshold_hours = 12 in
      let build = Build_identity.current () in
      (match build.binary_commit, build.binary_commit_age_seconds with
       | Some binary_commit, Some age
         when age > stale_threshold_hours * Masc_time_constants.hour_int ->
         let hours = age / Masc_time_constants.hour_int in
         Log.Server.warn
           "Server binary commit %s is %d hours old (>%dh threshold). \
            Rebuild + restart recommended to pick up newer fixes; see \
            /health build.binary_commit_age_seconds."
           binary_commit
           hours stale_threshold_hours
       | _ -> ());
      Server_bootstrap_loops.install_tooling ~governance_level state;
      Log.Server.info "Tooling + schemas in %.1fs" (Eio.Time.now clock -. t2);
      (state, path_diagnostics)
    in
    let run_lazy_task (task_name, task_fn) =
      Log.Server.info "lazy_task: starting %s" task_name;
      try
        task_fn ();
        Log.Server.info "lazy_task: finished %s" task_name;
        Server_startup_state.finish_lazy_task ~task:task_name
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
          let error = Printexc.to_string exn in
          Log.Server.error "lazy startup task %s failed: %s" task_name error;
          Server_startup_state.fail_lazy_task ~task:task_name ~error
    in
    let start_lazy_startup state =
      let task_fn = function
        | "restore_sessions" -> fun () -> restore_persisted_sessions state
        | "reconcile_active_agents" -> fun () ->
            reconcile_active_agents_gauge state
        | "prompt_bootstrap" -> fun () -> bootstrap_prompt_state state
        | "keeper_history_migration" -> fun () ->
            startup_migrate_keeper_histories state
        | "telemetry_warmup" -> fun () ->
            warm_tool_registry_from_telemetry state
        | "tool_metrics_restore" -> fun () ->
            restore_tool_metrics_from_disk state
        | "jsonl_prune" -> fun () -> startup_prune_jsonl state
        | "auth_archive_prune" -> fun () -> startup_prune_auth_archive state
        | task_name ->
            raise
              (Invalid_argument
                 (Printf.sprintf "unknown lazy startup task: %s" task_name))
      in
      let task_names = lazy_startup_task_names () in
      let task_groups =
        lazy_startup_plan ()
        |> List.map (fun group ->
               (group, List.map (fun name -> (name, task_fn name)) group.task_names))
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
             Eio.Fiber.all
               (List.map (fun task () -> run_lazy_task task) tasks)
             |> ignore
         | Serial -> List.iter run_lazy_task tasks);
        Log.Server.info "lazy_task_group: finished %s" group.group_name
      in
      Server_startup_state.activate_lazy
        ~backend_mode:(Workspace.backend_name state.workspace_config)
        ~tasks:task_names;
      Eio.Fiber.fork ~sw (fun () -> List.iter run_lazy_task_group task_groups)
    in
    try
      Server_startup_state.mark_blocking ~backend_mode:initial_backend_mode;
      let state, path_diagnostics =
        init_state_blocking ()
      in
      server_state := Some state;
      Server_startup_state.mark_state_ready
        ~backend_mode:(Workspace.backend_name state.workspace_config);
      let resolved_base, masc_dir =
        Server_bootstrap_loops.start_background_maintenance ~sw ~clock ~env state
      in
      (* RFC-0203 Phase 3: in-process Discord gateway replaces the
         deleted sidecars/discord-bot/ Python connector. Always-on:
         if DISCORD_BOT_TOKEN is unset the start function logs a
         warning and skips, leaving the server otherwise unaffected. *)
      Server_discord_in_process_gateway.start ~sw ~env ~clock ~state;
      Server_bootstrap_http.print_startup_banner ~config ~resolved_base ~base_path
        ~masc_dir ~path_diagnostics;
      (* Create the shared Domain_pool for dashboard compute and optional
         keeper offload.  The raw Executor_pool reference remains available
         for existing dashboard call sites, but new runtime call sites should
         go through Domain_pool_ref to preserve IO/CPU weight policy. *)
      let domain_pool =
        Domain_pool.create
          ~sw
          ?domain_count:(Env_config.Executor.domain_count_override ())
          domain_mgr
      in
      Domain_pool_ref.set domain_pool;
      Server_dashboard_http.set_executor_pool (Domain_pool.executor_pool domain_pool);
      Log.Server.info
        "Domain_pool created (%d domains) for dashboard/keeper compute"
        (Domain_pool.domain_count domain_pool);
      (* Start auxiliary transports before optional warmups and keeper loops.
         Otherwise HTTP can report ready while gRPC/WS startup is still stuck
         behind heavier startup work. *)
      (* gRPC workspace transport (default-on, opt-out via MASC_GRPC_ENABLED=0) *)
      let tool_dispatcher tool_name args_json =
        let arguments =
          try Yojson.Safe.from_string args_json
          with Yojson.Json_error _ -> `Assoc []
        in
        let result =
          Mcp_server_eio_execute.execute_tool_eio ~sw ~clock state
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
      Masc_grpc_server.start ~sw ~env ~workspace_config:state.workspace_config
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
                 state.Mcp_server.workspace_config)
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
                 ~config:state.Mcp_server.workspace_config ())
        | "board" ->
            Some
              (Server_dashboard_http.dashboard_board_json
                 ~sort_by:Board_dispatch.Recent ~exclude_system:true
                 ~limit:100 ~offset:0 ())
        | "goals" ->
            Some
              (Server_dashboard_http.dashboard_goals_snapshot_json
                 ~config:state.Mcp_server.workspace_config)
        | "ide" ->
            Some
              (Server_dashboard_http.dashboard_ide_snapshot_json
                 ~config:state.Mcp_server.workspace_config)
        | _ ->
            None);
      (* Standalone WebSocket transport (enabled by default, opt-out via MASC_WS_ENABLED=0) *)
      Server_ws_standalone.start ~sw ~env
        ~on_message:(fun ws_session_id body_str ->
          Eio.Fiber.fork ~sw (fun () ->
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
              Log.Server.warn "WS dispatch error %s: %s" ws_session_id (Printexc.to_string exn)));
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
      Server_dashboard_http.start_mission_refresh_loop ~state ~sw ~clock;
      Server_dashboard_http.start_operator_snapshot_refresh_loop ~state ~sw ~clock;
      Server_dashboard_http.start_operator_digest_refresh_loop ~state ~sw ~clock;
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
        Server_routes_http_runtime.start_full_health_snapshot_refresh_loop ~sw ~clock);
      start_lazy_startup state;
      (* RFC-0206: runtime catalog startup validation removed; Runtime.init_default
         already fail-fasts on an invalid runtime config at boot. *)
      Server_bootstrap_loops.start_keeper_loops ~sw ~clock ~net ~domain_mgr ~proc_mgr state
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Server_startup_state.mark_degraded ~error:(Printexc.to_string exn);
      Log.Server.error "Background init failed (HTTP still serving): %s"
        (Printexc.to_string exn));

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
