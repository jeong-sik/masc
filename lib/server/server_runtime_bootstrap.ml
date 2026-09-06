
open Server_auth
open Server_routes_http

module Mcp_server = Mcp_server
module Mcp_eio = Mcp_server_eio
module Config_root_bootstrap = Server_runtime_config_root_bootstrap
module Exact_output = Agent_core.Exact_output

let config_bootstrap_mode = Config_root_bootstrap.config_bootstrap_mode
let bootstrap_base_path_config_root = Config_root_bootstrap.bootstrap_base_path_config_root
let startup_config_resolution = Config_root_bootstrap.startup_config_resolution

let agent_core_model_catalog_env_var_name = "AGENT_CORE_MODEL_CATALOG"
let agent_core_models_overlay_toml_filename = "agent-core-models-overlay.toml"

(* Seconds withheld from tool-blob maintenance so the boot stages that follow
   it (Runtime_params restore, credential audit, Domain_pool, Keeper gate
   replay, lazy task groups, Discord/Slack/gRPC/WebSocket listeners) still fit
   inside the startup watchdog. Those stages took ~2s on an idle host; the
   reserve carries them at the ~10x slowdown observed when a concurrent build
   saturates the disk, which is the condition under which maintenance
   overran its host's watchdog. *)
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

let install_runtime_model_catalog_override ~load_catalog ~set_catalog path =
  match load_catalog path with
  | Ok catalog -> set_catalog catalog
  | Error detail ->
    raise (Env_config_core.Config_error (Printf.sprintf "catalog %s: %s" path detail))

let configure_agent_core_model_catalog_env
      ?(env = Sys.getenv_opt)
      ?(agent_core_catalog = Llm_provider.Model_catalog.global)
      ?(load_catalog = Llm_provider.Model_catalog.load_file)
      ?(set_catalog = Llm_provider.Model_catalog.set_global)
      ()
  =
  match nonempty_env env agent_core_model_catalog_env_var_name with
  | Some path ->
    install_runtime_model_catalog_override ~load_catalog ~set_catalog path;
    Log.Misc.info
      "model_catalog: AGENT_CORE_MODEL_CATALOG=%s already configured and loaded"
      path;
    Some path
  | None ->
    (match agent_core_catalog () with
     | Some _ ->
       Log.Misc.info
         "model_catalog: no explicit catalog path resolved; using agent_core ambient \
          model catalog"
     | None ->
       raise (Env_config_core.Config_error "model_catalog: AGENT_CORE embedded model catalog is unavailable"));
    None

let warn_ignored_config_root_full_catalogs
      ?(env = Sys.getenv_opt)
      ~config_root
      ()
  =
  if Option.is_none (nonempty_env env agent_core_model_catalog_env_var_name)
  then
    [ "models.toml"; "agent-core-models.toml" ]
    |> List.iter (fun filename ->
      let path = Filename.concat config_root filename in
      if Option.is_some (existing_file path)
      then
        Log.Misc.warn
          "model_catalog: ignoring retired config-root full catalog %s; AGENT_CORE embedded catalog plus agent-core-models-overlay.toml is the deployment SSOT (set AGENT_CORE_MODEL_CATALOG explicitly only for a deliberate full replacement)"
          path)

(* RFC-0342 D1 / Agent Core contract: deployment-local capability deltas live in a
   config-root overlay merged onto the embedded catalog
   ([Model_catalog.set_global_overlay]), instead of a full-catalog fork that
   shadows every embedded row and goes stale on each AGENT_CORE release. Only an
   operator-supplied [AGENT_CORE_MODEL_CATALOG] keeps full-replacement precedence. *)
let resolve_agent_core_model_catalog_overlay_path ?config_root () =
  match config_root with
  | None -> None
  | Some root ->
    let root = String.trim root in
    if String.equal root "" then
      None
    else
      existing_file (Filename.concat root agent_core_models_overlay_toml_filename)

let configure_agent_core_model_catalog_overlay
      ?config_root
      ?(load_catalog = Llm_provider.Model_catalog.load_file)
      ?(set_overlay = Llm_provider.Model_catalog.set_global_overlay)
      ()
  =
  match resolve_agent_core_model_catalog_overlay_path ?config_root () with
  | None -> None
  | Some path ->
    (match load_catalog path with
     | Ok overlay ->
       set_overlay overlay;
       Log.Misc.info
         "model_catalog: deployment overlay %s installed onto embedded catalog"
         path;
       Some path
     | Error detail ->
       raise
         (Env_config_core.Config_error
            (Printf.sprintf "catalog overlay %s: %s" path detail)))

let exact_output_catalog_source_to_string = function
  | Exact_output.Embedded_catalog -> "embedded"
  | Exact_output.Full_replacement_catalog -> "full replacement"
  | Exact_output.Overlay_catalog -> "overlay"
;;

let exact_output_collision_to_string = function
  | Exact_output.Duplicate_provider_identity -> "duplicate provider identity"
  | Exact_output.Duplicate_model_identity -> "duplicate model identity"
  | Exact_output.Duplicate_target_identity -> "duplicate target identity"
  | Exact_output.Provider_alias_shadow -> "provider alias shadow"
  | Exact_output.Target_identity_shadow -> "target identity shadow"
  | Exact_output.Model_identity_shadow -> "model identity shadow"
;;

let exact_output_binding_component_to_string = function
  | Exact_output.Target_provider -> "provider"
  | Exact_output.Target_model -> "model"
;;

let exact_output_endpoint_error_to_string = function
  | Exact_output.Malformed_base_url -> "malformed base URL"
  | Exact_output.Base_url_userinfo_not_allowed -> "base URL userinfo is not allowed"
  | Exact_output.Base_url_query_not_allowed -> "base URL query is not allowed"
  | Exact_output.Base_url_fragment_not_allowed -> "base URL fragment is not allowed"
  | Exact_output.Invalid_request_path -> "invalid request path"
  | Exact_output.Unsupported_gemini_request_path ->
    "Gemini exact targets require the generated endpoint surface"
  | Exact_output.Invalid_gemini_model_path -> "invalid Gemini model path"
;;

let exact_output_snapshot_error_to_string = function
  | Exact_output.Catalog_read_failed { path; detail } ->
    Printf.sprintf "catalog read failed (%s): %s" path detail
  | Exact_output.Catalog_parse_failed { source; detail } ->
    Printf.sprintf
      "%s catalog parse failed: %s"
      (exact_output_catalog_source_to_string source)
      detail
  | Exact_output.Target_catalog_invalid { source; detail } ->
    Printf.sprintf
      "%s target catalog is invalid: %s"
      (exact_output_catalog_source_to_string source)
      detail
  | Exact_output.Catalog_collision collision ->
    exact_output_collision_to_string collision
  | Exact_output.Target_binding_missing { target_ref; component } ->
    Printf.sprintf
      "target %S is missing its %s binding"
      target_ref
      (exact_output_binding_component_to_string component)
  | Exact_output.Target_endpoint_invalid { target_ref; cause } ->
    Printf.sprintf
      "target %S endpoint is invalid: %s"
      target_ref
      (exact_output_endpoint_error_to_string cause)
  | Exact_output.Environment_read_failed { environment_variable } ->
    Printf.sprintf "failed to read environment variable %s" environment_variable
;;

let read_exact_output_overlay path =
  try Ok (In_channel.with_open_bin path In_channel.input_all) with
  | Sys_error detail -> Error detail
;;

let load_exact_output_lane_declarations ?config_root () =
  let runtime_config_path =
    match config_root with
    | Some config_root ->
      let path =
        Filename.concat config_root Config_dir_resolver.runtime_toml_filename
      in
      if Sys.file_exists path then Some path else None
    | None -> Runtime.config_path ()
  in
  match runtime_config_path with
  | None ->
    raise
      (Env_config_core.Config_error
         "exact-output registry: runtime.toml path is unavailable")
  | Some config_path ->
    (match Runtime_toml.parse_file config_path with
     | Error errors ->
       raise
         (Env_config_core.Config_error
            (Printf.sprintf
               "exact-output registry: runtime config parse failed (%s): %d error(s)"
               config_path
               (List.length errors)))
     | Ok (config : Runtime_schema.config) ->
       ( config_path
       , config.exact_output_lane_decls ))
;;

let mandatory_exact_output_lane_ids =
  [ Hitl_summary_worker.lane_id; Keeper_board_attention_exact_flow.lane_id ]
;;

let require_explicit_mandatory_exact_output_lanes ~config_path lanes =
  List.iter
    (fun lane_id ->
       match
         List.find_opt
           (fun (lane : Runtime_schema.exact_output_lane_decl) ->
              String.equal lane.id lane_id)
           lanes
       with
       | None ->
         raise
           (Env_config_core.Config_error
              (Printf.sprintf
                 "exact-output registry: mandatory lane %S is missing in %s; add \
                  [runtime.exact_output_lanes.%s] with a non-empty slots array \
                  of AGENT_CORE target refs, or reset the preserved runtime.toml and \
                  restart so MASC can reseed it; existing runtime configs are \
                  never migrated automatically"
                 lane_id
                 config_path
                 lane_id))
       | Some { slot_ids = []; _ } ->
         raise
           (Env_config_core.Config_error
              (Printf.sprintf
                 "exact-output registry: mandatory lane %S has no slots in %s; \
                  configure at least one AGENT_CORE target ref or reset the preserved \
                  runtime.toml and restart so MASC can reseed it; existing \
                  runtime configs are never migrated automatically"
                 lane_id
                 config_path))
       | Some { slot_ids = _ :: _; _ } -> ())
    mandatory_exact_output_lane_ids
;;

let warn_rejected_exact_output_slots registry =
  let rejected = Runtime_exact_output_registry.rejected_slots registry in
  let configured_runtime slot_id =
    Option.map
      (fun (rt : Runtime.t) ->
         rt.Runtime.provider.Runtime_schema.id, rt.Runtime.model.Runtime_schema.api_name)
      (Runtime.get_runtime_by_id slot_id)
  in
  let diagnoses =
    List.map
      (fun (slot : Runtime_exact_output_registry.rejected_slot) ->
         ( slot
         , Runtime_exact_output_registry.diagnose_rejected_slot
             registry
             slot
             ~configured_runtime ))
      rejected
  in
  List.iter
    (fun ((slot : Runtime_exact_output_registry.rejected_slot), diagnosis) ->
       match diagnosis with
       | Runtime_exact_output_registry.Declared_target_binding_rejected ->
         Log.Server.warn
           "exact_output: lane %S slot %d (%S) ignored because the overlay declares that target but its provider binding was rejected (see the target binding report above); fix the binding, the slot needs no change"
           slot.lane_id
           slot.position
           slot.slot_id
       | Runtime_exact_output_registry.Configured_runtime_only { provider_id; api_name }
         when String.equal slot.lane_id Runtime.verifier_exact_lane_id ->
         (* verifier_exact admits slots here but dispatches them through
            Runtime.resolve_assignment, so its ids must exist in both
            registries; #32653 measured the catalog-id form failing at
            dispatch 27 times on 2026-08-29. *)
         Log.Server.warn
           "exact_output: lane %S slot %d (%S) ignored because it is a runtime.toml runtime id (provider %S, api-name %S) with no overlay [[targets]] row of the same id; this lane dispatches by configured runtime id, so keep the id and add an overlay target with the same id for model %S"
           slot.lane_id
           slot.position
           slot.slot_id
           provider_id
           api_name
           api_name
       | Runtime_exact_output_registry.Configured_runtime_only { provider_id; api_name } ->
         Log.Server.warn
           "exact_output: lane %S slot %d (%S) ignored because it is a runtime.toml runtime id (provider %S, api-name %S), not an exact-output target; this lane dispatches by admitted target, so name the overlay [[targets]] id that declares model %S"
           slot.lane_id
           slot.position
           slot.slot_id
           provider_id
           api_name
           api_name
       | Runtime_exact_output_registry.Unknown_to_both_registries ->
         Log.Server.warn
           "exact_output: lane %S slot %d (%S) ignored because it is neither an overlay target nor an enabled configured runtime; the catalog moved on, the runtime is disabled, or the id is mistyped"
           slot.lane_id
           slot.position
           slot.slot_id)
    diagnoses;
  (* One consolidated line at ERROR, because per-slot WARNs read as
     tolerable degradation and get discounted: four lanes carried retired
     targets for days on 2026-08-28 while the warnings repeated unread. The
     count per cause and the lane list make the standing config debt visible
     once per publish. *)
  (match rejected with
   | [] -> ()
   | rejected ->
     let lanes =
       rejected
       |> List.map (fun (slot : Runtime_exact_output_registry.rejected_slot) ->
              slot.lane_id)
       |> List.sort_uniq String.compare
     in
     let count predicate =
       List.length (List.filter (fun (_, diagnosis) -> predicate diagnosis) diagnoses)
     in
     Log.Server.error
       "exact_output: %d slot(s) ignored across %d lane(s) (%s): %d unknown to both registries, %d runtime.toml runtime id(s) without a same-id overlay target, %d declared target(s) whose binding was rejected — fix runtime.toml or the overlay"
       (List.length rejected)
       (List.length lanes)
       (String.concat ", " lanes)
       (count (function
          | Runtime_exact_output_registry.Unknown_to_both_registries -> true
          | Runtime_exact_output_registry.Configured_runtime_only _
          | Runtime_exact_output_registry.Declared_target_binding_rejected -> false))
       (count (function
          | Runtime_exact_output_registry.Configured_runtime_only _ -> true
          | Runtime_exact_output_registry.Unknown_to_both_registries
          | Runtime_exact_output_registry.Declared_target_binding_rejected -> false))
       (count (function
          | Runtime_exact_output_registry.Declared_target_binding_rejected -> true
          | Runtime_exact_output_registry.Unknown_to_both_registries
          | Runtime_exact_output_registry.Configured_runtime_only _ -> false)))
;;

(* Retracted (2026-08-28, hours after #31445): the classifier reuses
   Exact_output.admit_target_ref, whose authority is exact-output LANE
   admission. Keeper turn assignments resolve through a different path —
   the [runtime] provider/model bindings — and keepers flagged by the
   catalog predicate (codex_subscription.gpt-5.6-luna, ollama_cloud
   targets, …) were measured running on exactly their assigned runtimes
   the same day. The boot ERROR named ten false positives before it was
   pulled. A correct assignment-liveness check must read the binding
   resolver, not the frozen catalog. *)

let warn_catalog_absent_keeper_assignments _resolver_snapshot = ()
;;

let warn_rejected_exact_output_bindings resolver_snapshot =
  List.iter
    (fun (binding : Exact_output.rejected_target_binding) ->
       Log.Server.warn
         "exact_output: target %S excluded from the frozen resolver because its %s binding is missing; lane admission will decide whether required targets remain"
         binding.target_ref
         (exact_output_binding_component_to_string binding.component))
    (Exact_output.resolver_rejected_target_bindings resolver_snapshot)
;;

let warn_optional_exact_output_lane registry ~lane_id ~feature =
  match Runtime_exact_output_registry.resolve_lane registry ~lane_id with
  | Ok { selected_slots = _ :: _; _ } -> ()
  | Ok { selected_slots = []; _ }
  | Error (Runtime_exact_output_registry.No_admitted_lane_slots _) ->
    Log.Server.warn
      "exact_output: %s is degraded because lane %S has no admitted target in the frozen catalog"
      feature
      lane_id
  | Error (Runtime_exact_output_registry.Exact_lane_unconfigured _) ->
    Log.Server.warn
      "exact_output: %s is degraded until [runtime.exact_output_lanes.%s] is configured with AGENT_CORE target refs"
      feature
      lane_id
;;

let configure_exact_output_registry ?config_root () =
  let config_path, lanes =
    load_exact_output_lane_declarations ?config_root ()
  in
  require_explicit_mandatory_exact_output_lanes ~config_path lanes;
  let catalog, catalog_description =
    match nonempty_env Sys.getenv_opt agent_core_model_catalog_env_var_name with
    | Some path -> Exact_output.Full_replacement_file path, " from full replacement " ^ path
    | None ->
      (match resolve_agent_core_model_catalog_overlay_path ?config_root () with
       | None -> Exact_output.Embedded_default, " from AGENT_CORE embedded catalog"
       | Some path ->
         (match read_exact_output_overlay path with
          | Ok contents ->
            ( Exact_output.Embedded_with_overlay { source = path; contents }
            , " with deployment overlay " ^ path )
          | Error detail ->
            raise
              (Env_config_core.Config_error
                 (Printf.sprintf "exact-output catalog overlay %s: %s" path detail))))
  in
  let io : Exact_output.resolver_io =
    { getenv =
        (fun name ->
          try Ok (Sys.getenv_opt name) with
          | Sys_error _ | Invalid_argument _ -> Error ())
    }
  in
  match
    Exact_output.load_resolver_snapshot
      ~io
      ~target_binding_policy:Exact_output.Exclude_unbound_targets
      ~catalog
      ()
  with
  | Error error ->
    raise
      (Env_config_core.Config_error
         ("exact-output resolver snapshot: "
          ^ exact_output_snapshot_error_to_string error))
  | Ok resolver_snapshot ->
    warn_rejected_exact_output_bindings resolver_snapshot;
    (match
       Runtime.publish_exact_output_registry
         ~required_lane_ids:mandatory_exact_output_lane_ids
         ~lanes
         resolver_snapshot
     with
     | Error detail ->
       raise
         (Env_config_core.Config_error
            ("exact-output resolver-and-lane registry: " ^ detail))
     | Ok registry ->
       warn_rejected_exact_output_slots registry;
       warn_catalog_absent_keeper_assignments resolver_snapshot;
       Log.Misc.info
         "exact_output: immutable resolver-and-lane registry published%s"
         catalog_description;
       warn_optional_exact_output_lane
         registry
         ~lane_id:"librarian_exact"
         ~feature:"librarian";
       warn_optional_exact_output_lane
         registry
         ~lane_id:Runtime.verifier_exact_lane_id
         ~feature:"completion authority")
;;

let install_domain_pool_references domain_pool =
  Domain_pool_ref.set domain_pool;
  Executor_pool_ref.set (Domain_pool.executor_pool domain_pool)
;;

module For_testing = struct
  let configure_exact_output_registry = configure_exact_output_registry
  let install_domain_pool_references = install_domain_pool_references
end

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
      Env_config_core.get_int_nonneg
        ~default:(Env_setting.Int_knob.default Gc_space_overhead)
        (Env_setting.Int_knob.env_name Gc_space_overhead)
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
  (* Children start with posix_spawn(2), not eio_posix's fork(): on macOS the
     parent side of a fork locks every malloc zone and held the main domain
     about 141 ms per spawn with this process's heap (RFC
     main-domain-scheduler-latency §8.8). *)
  let proc_mgr = Posix_spawn_process_mgr.mgr in
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
       reason in {read_error | parse_error | validate_error}, derived from \
       Keeper_runtime_config.load_failure_kind."
    ()

let record_runtime_toml_load_failure (failure : Keeper_runtime_config.load_failure) =
  Otel_metric_store.inc_counter
    metric_keeper_runtime_config_load_failures
    ~labels:
      [ "reason", Keeper_runtime_config.load_failure_kind_label failure.kind ]
    ()

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
  bootstrap_base_path_config_root ~base_path;
  let config_root = (startup_config_resolution ~base_path).config_root.path in
  warn_ignored_config_root_full_catalogs ~config_root ();
  let (_ : string option) = configure_agent_core_model_catalog_env () in
  let (_ : string option) = configure_agent_core_model_catalog_overlay ~config_root () in
  (* Apply keeper runtime overrides from the resolved config root's
     runtime.toml. Must run before any module that reads
     [Env_config_keeper.KeeperKeepalive] env vars at init time. Existing
     process env vars take precedence — TOML only fills unset slots. *)
  (match Keeper_runtime_config.load_and_apply ~base_path with
   | Ok 0 -> ()
   | Ok n ->
       Log.Server.info "runtime.toml: applied %d override(s)" n
   | Error failure ->
       record_runtime_toml_load_failure failure;
       let msg = Keeper_runtime_config.load_failure_to_string failure in
       Log.Server.error "runtime.toml load failed: %s" msg;
       raise (Env_config_core.Config_error msg));
  Keeper_runtime_resolved.init ();
  (* Boot-time observability: emit the resolved runtime knobs once, right after
     they freeze. Without this line a knob that is CONFIGURED in runtime.toml but
     did not reach Keeper_runtime_resolved is indistinguishable at runtime from an
     unset one — the exact ambiguity that blocked diagnosing #25128 (idle timeout
     configured yet never observed to fire). The body-timeout override is None
     when unset; stream_idle_timeout_sec now resolves to the RFC-0345 fail-safe
     floor when unset (stated on the dedicated line below). No existing surface
     exposes the resolved value. *)
  Log.Runtime.info
    ~category:Log.Boundary
    "resolved runtime config: %s"
    (Yojson.Safe.to_string
       (Keeper_runtime_resolved.to_yojson (Keeper_runtime_resolved.current ())));
  (* RFC-0345 (#25128): state the effective streaming idle timeout and whether it
     came from an operator value (env/toml) or the fail-safe floor, so operators
     can see the floor is active and raise it if their provider legitimately
     idles longer. The resolver always yields [Some] after the floor; the [None]
     arm is retained as total handling and reports the pre-floor freeze-risk
     posture should the floor ever be removed. *)
  Keeper_runtime_resolved.(
    let idle = (current ()).stream_idle_timeout_sec in
    match idle.value with
    | Some seconds ->
      Log.Runtime.info
        ~category:Log.Boundary
        "keeper stream idle timeout resolved: %.1fs (source: %s)"
        seconds
        (source_to_string idle.source)
    | None ->
      Log.Runtime.info
        ~category:Log.Boundary
        "keeper stream idle timeout resolved: disabled (no inter-line idle bound)");
  (* RFC-AC-037: same boot observability for the first-event (TTFT/prefill)
     budget — configured-vs-effective must stay distinguishable at runtime,
     the exact ambiguity #25128 hit for the idle knob. *)
  Keeper_runtime_resolved.(
    let first_event = (current ()).first_event_timeout_sec in
    match first_event.value with
    | Some seconds ->
      Log.Runtime.info
        ~category:Log.Boundary
        "keeper first-event (TTFT/prefill) timeout resolved: %.1fs (source: %s)"
        seconds
        (source_to_string first_event.source)
    | None ->
      Log.Runtime.info
        ~category:Log.Boundary
        "keeper first-event timeout resolved: disabled (no first-event bound)");
  Keeper_task_owner_backend.install_hooks ();
  Server_dashboard_http_execution_surfaces.install_task_mutation_cache_invalidation
    ~invalidate_full_health_snapshot:
      Server_routes_http_runtime.invalidate_full_health_snapshot
    ();
  Keeper_registry.install_state_change_observer
    Server_routes_http_runtime.invalidate_full_health_snapshot;
  Keeper_owner.install_state_change_observer
    Server_routes_http_runtime.invalidate_full_health_snapshot;
  Keeper_reaction_ledger.install_state_change_observer
    Server_routes_http_runtime.invalidate_full_health_snapshot;
  Keeper_event_queue_persistence.install_state_change_observer
    Server_routes_http_runtime.invalidate_full_health_snapshot;
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

let restore_persisted_sessions (state : Mcp_server.server_state) =
  Session.restore_from_disk state.session_registry
    ~agents_path:(Workspace.agents_dir (Mcp_server.workspace_config state))

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
        task_names = [ "restore_sessions" ];
      };
    ]
  in
  let cleanup_groups =
    [
      {
        group_name = "cleanup";
        (* Parallel, because removing a guest is a VM shutdown at roughly a
           minute each and jsonl_prune finishes in milliseconds. Run serially
           the sweep held the whole group, and keeper boot waits for the
           group: measured on 2026-08-28, autoboot logged
           "waiting for lazy startup tasks" for 30s behind a single guest.

           Boot is still the right moment. The sweep only removes guests
           whose owning server is gone, and this process owns none yet, so
           every candidate belongs to an earlier server -- one still running
           keeps its own pid alive and its guests are not candidates. *)
        execution = Parallel;
        task_names = [ "jsonl_prune"; "microvm_guest_sweep" ];
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
  | Runtime_config_read_failed of string
  | Run_registry_already_installed of
      [ `Exact_lane | `Fusion | `Goal_verification | `Verification ]
  | Runtime_default_initialization_failed of Runtime.strict_init_error
  | Keeper_persistence_preparation_failed of
      Server_bootstrap_loops.keeper_persistence_prepare_error
  | Keeper_persistence_claim_failed of
      Server_bootstrap_loops.keeper_persistence_claim_error
  | Keeper_persistence_start_failed of
      Server_bootstrap_loops.keeper_persistence_start_error
  | Startup_path_guard_rejected of Server_base_path_diagnostics.t
  | Lazy_startup_barrier_failed of Server_startup_state.lazy_prepare_error
  | Readiness_transition_failed of Server_startup_state.state_ready_error
  | Readiness_publication_failed of
      { observed_phase : Server_startup_state.phase
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
    "no runtime config path; cannot initialize the default Runtime. Seed one \
     with `masc init --base-path <dir>`, or point MASC_CONFIG_DIR at a config \
     root that holds runtime.toml"
  | Runtime_config_read_failed detail ->
    "runtime config observation failed: " ^ detail
  | Run_registry_already_installed `Fusion ->
    "Fusion run registry already has a process owner"
  | Run_registry_already_installed `Verification ->
    "Verification run registry already has a process owner"
  | Run_registry_already_installed `Goal_verification ->
    "Goal verification run registry already has a process owner"
  | Run_registry_already_installed `Exact_lane ->
    "Exact lane run registry already has a process owner"
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
  | Lazy_startup_barrier_failed error ->
    Server_startup_state.lazy_prepare_error_to_string error
  | Readiness_transition_failed error ->
    Server_startup_state.state_ready_error_to_string error
  | Readiness_publication_failed { observed_phase } ->
    Printf.sprintf
      "owner readiness publication failed (observed_phase=%s)"
      (Server_startup_state.phase_to_string observed_phase)

let initialize_owner_state_blocking
      ~sw
      ~env
      ~base_path
      ?input_base_path
      ~accept_store_quarantine
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
  Fs_compat.set_fs fs;
  let masc_dir = Common.masc_dir_from_base_path ~base_path in
  let fusion_registry =
    Filename.concat masc_dir Fusion_run_registry.storage_filename
    |> Fusion_run_registry.replay
  in
  (match Fusion_run_registry.install_global fusion_registry with
   | Ok () -> ()
   | Error Fusion_run_registry.Already_installed ->
     raise
       (Owner_initialization_failed
          (Run_registry_already_installed `Fusion)));
  let verification_registry =
    Filename.concat masc_dir Verification_run_registry.storage_filename
    |> Verification_run_registry.replay
  in
  (match Verification_run_registry.install_global verification_registry with
   | Ok () -> ()
   | Error Verification_run_registry.Already_installed ->
     raise
       (Owner_initialization_failed
          (Run_registry_already_installed `Verification)));
  let goal_verification_registry =
    Filename.concat masc_dir Goal_verification_run_registry.storage_filename
    |> Goal_verification_run_registry.replay
  in
  (match
     Goal_verification_run_registry.install_global goal_verification_registry
   with
   | Ok () -> ()
   | Error Goal_verification_run_registry.Already_installed ->
     raise
       (Owner_initialization_failed
          (Run_registry_already_installed `Goal_verification)));
  let exact_lane_registry =
    Filename.concat masc_dir Exact_lane_run_registry.storage_filename
    |> Exact_lane_run_registry.replay
  in
  (match Exact_lane_run_registry.install_global exact_lane_registry with
   | Ok () -> ()
   | Error Exact_lane_run_registry.Already_installed ->
     raise
       (Owner_initialization_failed
          (Run_registry_already_installed `Exact_lane)));
  let broadcast_internal_agent_runs_changed () =
    Sse.broadcast (`Assoc [ "type", `String "internal_agent_runs_changed" ])
  in
  Atomic.set
    Verification_run_registry.change_observer_fn
    broadcast_internal_agent_runs_changed;
  Atomic.set
    Goal_verification_run_registry.change_observer_fn
    broadcast_internal_agent_runs_changed;
  Atomic.set
    Exact_lane_run_registry.change_observer_fn
    broadcast_internal_agent_runs_changed;
  (* [main_eio] caches the normalized operator input before entering Eio.
     Replace that preflight value with the canonical owner identity before
     [Workspace.default_config_uncached] constructs its backend, otherwise the
     config record says canonical while its backend still follows an alias. *)
  Workspace_utils_backend_setup.cache_resolved_base_path base_path;
  Discovery_cache.set_env ~sw ~net;
  Gc_sampler.run ~sw ~clock ~interval:30.0;
  (* The activity-events parse cache alongside the heap gauges: it is retained
     for the life of each day file, so its size is a steady state rather than
     churn, and 30s is often enough to see it move when retention sweeps.
     Sampled here rather than inside [Gc_sampler] so neither that module nor
     [Activity_graph] gains a dependency on the other. *)
  (* The maintenance loops open their named switch once per iteration, not
     once per fiber: the runtime-events ring keeps a name only until it is
     overwritten, so a tracer attached later sees the per-iteration names. *)
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      Eio.Switch.run ~name:"activity-cache-gauges" (fun _ ->
      (try
         let stats = Activity_graph.cache_stats () in
         Otel_metric_store.set_gauge
           Otel_metric_store.metric_activity_cache_files
           (float_of_int stats.Activity_graph.past_day_files);
         Otel_metric_store.set_gauge
           Otel_metric_store.metric_activity_cache_records
           (float_of_int stats.Activity_graph.past_day_records)
       with
       | Eio.Cancel.Cancelled _ as exn -> raise exn
       | exn ->
         Log.Server.warn "activity cache gauge sample failed: %s" (Printexc.to_string exn)));
      Eio.Time.sleep clock 30.0;
      loop ()
    in
    loop ());
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      Eio.Time.sleep clock 5.0;
      Eio.Switch.run ~name:"tool-usage-flush" (fun _ ->
      (try Keeper_registry_tool_usage_persistence.flush_all_dirty () with
       | Eio.Cancel.Cancelled _ as exn -> raise exn
       | exn ->
         Log.Keeper.warn
           "tool_usage flush_all_dirty failed: %s"
           (Printexc.to_string exn)));
      loop ()
    in
    loop ());
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      Eio.Time.sleep clock 2.0;
      Eio.Switch.run ~name:"trajectory-flush" (fun _ ->
      (try Trajectory.flush_all_pending () with
       | Eio.Cancel.Cancelled _ as exn -> raise exn
       | exn ->
         Log.Keeper.warn
           "trajectory flush_all_pending failed: %s"
           (Printexc.to_string exn)));
      loop ()
    in
    loop ());
  let t0 = Eio.Time.now clock in
  Llm_metric_bridge.install ();
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
  Runtime_log_sink.install ();
  Log.Server.info
    "Runtime_log_sink installed (agent core -> MASC structured log)";
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
  let runtime_config_path =
    match Runtime.config_path () with
    | None ->
      raise (Owner_initialization_failed Runtime_config_path_unavailable)
    | Some config_path -> config_path
  in
  let runtime_config_observation =
    match Runtime.load_config_observation ~runtime_config_path () with
    | Ok observation -> observation
    | Error detail ->
      raise (Owner_initialization_failed (Runtime_config_read_failed detail))
  in
  (match Runtime.init_default_degraded_observation runtime_config_observation with
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
          (Runtime_default_initialization_failed error)));
  (match
     Server_skill_snapshot_runtime.refresh_from_observation
       ~base_path
       runtime_config_observation
   with
   | Error error ->
     Log.Server.error
       "Skill snapshot workspace rejected at boot: %s"
       (Server_skill_snapshot_runtime.error_to_string error)
   | Ok Workspace_retired ->
     Log.Server.warn "Skill snapshot workspace retired during boot publication"
   | Ok (Published skill_snapshot | Unchanged skill_snapshot) ->
     (match Skill_catalog_snapshot.config_state skill_snapshot with
      | Configured _ ->
        Log.Server.info
          "Skill snapshot ready at boot: snapshot_revision=%s catalog_revision=%s skills=%d rejections=%d"
          (Skill_catalog_snapshot.snapshot_revision skill_snapshot
           |> Skill_catalog_snapshot.snapshot_revision_to_string)
          (Skill_catalog_snapshot.catalog_revision skill_snapshot
           |> Skill_catalog_snapshot.catalog_revision_to_string)
          (List.length (Skill_catalog_snapshot.entries skill_snapshot))
          (List.length (Skill_catalog_snapshot.rejections skill_snapshot))
      | Config_rejected { diagnostics; _ } ->
        Log.Server.warn
          "Skill snapshot config rejected at boot: snapshot_revision=%s diagnostics=%d"
          (Skill_catalog_snapshot.snapshot_revision skill_snapshot
           |> Skill_catalog_snapshot.snapshot_revision_to_string)
          (List.length diagnostics)
      | Config_unreadable _ ->
        Log.Server.error
          "Skill snapshot config unreadable at boot: snapshot_revision=%s"
          (Skill_catalog_snapshot.snapshot_revision skill_snapshot
           |> Skill_catalog_snapshot.snapshot_revision_to_string)));
  (* masc#28404. Boot refuses only over runtimes something actually routes to,
     which is right — an unassigned runtime is not a reason to stay down. But
     the blocked ones then started silently, and the answer to "why can I not
     assign this runtime" lived nowhere. One line per blocked runtime at boot is
     that answer; empty is the healthy state and logs nothing. *)
  List.iter
    (fun ((runtime : Runtime.t), reason) ->
      Log.Server.warn
        "Runtime %s is not keeper-dispatchable: %s"
        runtime.id
        reason)
    (Runtime.keeper_dispatch_blocked (Runtime.get_runtimes ()));
  configure_exact_output_registry
    ~config_root:(Filename.dirname runtime_config_path)
    ();
  let t1 = Eio.Time.now clock in
  Log.Server.info "State created (runtime state) in %.1fs" (t1 -. t0);
  bootstrap_server_state_blocking state;
  sync_admin_token_env state;
  sync_internal_keeper_token_env state;
  sync_bootable_keeper_credentials state;
  (* Shutdown admission restore below is mailbox-linearized by the Keeper
     Owner. Install the inventory before persistence preparation so a durable
     shutdown fence can be restored on a real process restart. The operation
     runner remains dormant until the corresponding Keeper registry entry is
     healthy, so queued chat work cannot run across this pre-ready boundary. *)
  let keeper_owner_count =
    match
      Keeper_owner_registry.install_from_store
        ~sw
        ~operation_runner:
          (Some (Server_routes_http_keeper_stream.operation_runner ~state ~clock))
        (* The chat lane is told when its dependency is ready
           ([wake_operation_drain]); the autonomous lane had no equivalent and
           rediscovered a freed slot only on its next keepalive cadence, which
           RFC-0373 measured as up to five consecutive lost cycles. The Owner
           fires this only when the freed slot is still unclaimed, so the wake
           means a turn can start now. *)
        ~on_turn_slot_released:
          (Some
             (fun ~keeper_name ->
               match
                 Keeper_registry.wakeup_running
                   ~intent:Keeper_registry.Turn_slot_released
                   ~base_path:(Mcp_server.workspace_config state).base_path
                   keeper_name
               with
               | Keeper_registry.Signaled -> ()
               | Keeper_registry.Deferred_unregistered ->
                 Log.Keeper.info
                   ~keeper_name
                   "turn slot release wake deferred: keeper is no longer registered"
               | Keeper_registry.Deferred_not_running phase ->
                 Log.Keeper.info
                   ~keeper_name
                   "turn slot release wake deferred: phase=%s"
                   (Keeper_state_machine.phase_to_string phase)
               | Keeper_registry.Deferred_lifecycle _ ->
                 (* The registry already logged this arm and incremented
                    LifecycleDispatchRejections with intent=turn_slot_released;
                    repeating it here would double-count one denial. *)
                 ()))
        (Mcp_server.workspace_config state)
    with
    | Ok count -> count
    | Error error -> raise (Keeper_owner_registry.Install_failed error)
  in
  Log.Keeper.info
    "keeper_owner: installed %d single-owner actor(s) before persistence recovery"
    keeper_owner_count;
  let prepared_keeper_persistence =
    match
      Server_bootstrap_loops.prepare_keeper_persistence
        ~requested_base_path
        ~accept_store_quarantine
        ~config:(Mcp_server.workspace_config state)
        ()
    with
    | Ok prepared -> prepared
    | Error error ->
      raise
        (Owner_initialization_failed
           (Keeper_persistence_preparation_failed error))
  in
  (match
     Eio_unix.run_in_systhread (fun () ->
       Keeper_wire_capture.prune_expired
         ~masc_root:(Workspace.masc_root_dir (Mcp_server.workspace_config state)))
   with
   | Error error ->
     Log.Server.warn
       "startup wire-capture retention prune failed: %s"
       (Keeper_wire_capture.prune_error_to_string error)
   | Ok wire_capture_pruned ->
     if wire_capture_pruned > 0
     then
       Log.Server.info
         "startup wire-capture retention: pruned %d expired day-file(s)"
         wire_capture_pruned);
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
  install_domain_pool_references domain_pool;
  Log.Server.info
    "Domain_pool created (%d domains) for dashboard/keeper compute"
    (Domain_pool.domain_count domain_pool);
  { state; path_diagnostics; prepared_keeper_persistence; domain_pool }

(* Copies and deletions are two events, so they get two lines with two
   sample budgets. One line held both and cut the shared sample at ten: a
   version bump copies enough to fill it, and the deleted paths never
   reached the line. For [Tools] those names are the whole message, since a
   definition an operator drops into the runtime directory is deleted at the
   next boot and nothing else says so. *)
let sync_managed_assets_from_binary ~label ~domain ~dest_dir () =
  let sync =
    Managed_asset_sync.sync
      ~domain
      ~read:Embedded_config.read
      ~files:Embedded_config.file_list
      ~dest_dir
      ()
  in
  Option.iter
    (fun line -> Log.Misc.info "%s" line)
    (Managed_asset_sync.distribution_line ~label sync);
  Option.iter
    (fun line -> Log.Misc.warn "%s" line)
    (Managed_asset_sync.removed_line ~label sync);
  List.iter
    (fun (rel, msg) -> Log.Misc.warn "%s asset sync failed: %s: %s" label rel msg)
    sync.Managed_asset_sync.failed

(* Tool definitions ship embedded in the binary and are read once at boot
   (RFC prompts-and-tool-definitions-outside-ocaml §6). A definition that
   does not decode refuses the boot here, before readiness, instead of
   publishing a partial tool surface. *)
let validate_embedded_tool_definitions () =
  match
    Tool_definition_toml.validate_embedded
      ~read:Embedded_config.read
      ~files:Embedded_config.file_list
  with
  | Ok () -> ()
  | Error message -> failwith (Printf.sprintf "embedded tool definition: %s" message)

(* Same contract for the MCP surface TOMLs (config/mcp/*.toml): they are the
   resources/templates/prompts catalogue prose and the server description,
   read once at boot. *)
let validate_embedded_mcp_surface () =
  match
    Mcp_surface_toml.validate_embedded
      ~read:Embedded_config.read
      ~files:Embedded_config.file_list
  with
  | Ok () -> ()
  | Error message -> failwith (Printf.sprintf "embedded mcp surface: %s" message)

let bootstrap_prompt_assets () =
  sync_managed_assets_from_binary
    ~label:"prompt"
    ~domain:Managed_asset_sync.Prompts
    ~dest_dir:(Config_dir_resolver.prompts_dir ())
    ()

let bootstrap_prompt_state (state : Mcp_server.server_state) =
  let config = Mcp_server.workspace_config state in
  Config_dir_resolver.log_warnings ~context:"ServerBootstrap" ();
  Config_dir_resolver.log_resolution ~context:"ServerBootstrap" ();
  (* Converge the runtime prompt markdown and tool definition dirs onto the
     binary-embedded assets before anything scans them (#20929: merged
     prompt edits never reached the runtime dir otherwise). *)
  bootstrap_prompt_assets ();
  sync_managed_assets_from_binary
    ~label:"tool"
    ~domain:Managed_asset_sync.Tools
    ~dest_dir:(Config_dir_resolver.tools_dir ())
    ();
  sync_managed_assets_from_binary
    ~label:"mcp"
    ~domain:Managed_asset_sync.Mcp
    ~dest_dir:(Config_dir_resolver.mcp_dir ())
    ();
  validate_embedded_tool_definitions ();
  validate_embedded_mcp_surface ();
  (* Load the registry and replay operator overrides. The resolved directory is
     not inspected afterwards: three checks used to stand here and none of them
     gated. One compared a value against the call that produced it. One
     re-asserted a post-condition of the directory scan itself, and could not
     see the failure it read as protecting against, because a file the loader
     never read is never registered. One logged templates using undeclared
     variables. All three continued on failure, so a boot serving silently
     shorter prompts looked healthy.

     The prompts ship embedded in this binary, and
     [test_prompt_templates_render] requires every file under config/prompts to
     register as a key, resolve from a real source, render with the variables
     its own frontmatter declares, and use each one. Repeating that at start
     decides nothing the build did not already decide. *)
  ignore
    (Prompt_defaults.bootstrap_runtime
       ~workspace_path:config.workspace_path
       ~base_path:config.base_path
     : string)

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
    | "jsonl_prune" -> fun () -> startup_prune_jsonl state
    | "microvm_guest_sweep" -> fun () -> startup_sweep_microvm_guests state
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
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Switch.run ~name:"lazy-startup-tasks" @@ fun _ ->
    List.iter run_lazy_task_group task_groups)

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
      ~invalidate_full_health_snapshot:
        Server_routes_http_runtime.invalidate_full_health_snapshot
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

let mark_owner_state_ready () =
  match Server_startup_state.mark_state_ready () with
  | Error error -> Error (Readiness_transition_failed error)
  | Ok () ->
    let observed = Server_startup_state.snapshot () in
    if observed.state_ready then Ok ()
    else
      Error
        (Readiness_publication_failed { observed_phase = observed.phase })

let start_completion_authority ~sw ~clock (state : Mcp_server.server_state) =
  Completion_authority_agent.start
    ~sw
    ~clock
    ~config:(Mcp_server.workspace_config state)

(* RFC-0387 stage 2 PR-2: the goal-side verifier caller. It must start in the
   same post-readiness lane as the task completion authority — the stage-2
   gate is illegal to merge without it (a gate no one calls wedges every goal
   that enters [Verifying]). *)
let start_goal_verifier ~sw (state : Mcp_server.server_state) =
  Goal_verification_agent.start ~sw ~config:(Mcp_server.workspace_config state)

let start_post_ready_owner_lanes
      ~sw
      ~clock
      ~env
      (state : Mcp_server.server_state)
  =
  (* Keep the transport-neutral post-readiness order in one place. Both HTTP
     and stdio must install the system-LLM authority before maintenance can
     observe or resume AwaitingVerification work. *)
  start_completion_authority ~sw ~clock state;
  start_goal_verifier ~sw state;
  Server_bootstrap_loops.start_background_maintenance ~sw ~clock ~env state

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
    (match report.replay_projection_error with
     | None -> ()
     | Some error ->
       Log.Server.error
         "keeper_gate: derived replay projection unavailable; authorization queue remains ready base_path=%s error=%s"
         base_path
         (Keeper_approval_queue.storage_error_to_string error));
    List.iter
      (fun (failure : Keeper_approval_queue.delivery_replay_failure) ->
         Log.Server.error
           "keeper_gate: durable delivery replay failed approval=%s error=%s"
           failure.approval_id
           failure.reason)
      report.delivery_replay_failures;
    let resume_report = Keeper_gate.resume_persisted_auto_judges ~base_path in
    (match resume_report.queue_error with
     | Some error ->
       Log.Server.error
         "keeper_gate: Auto Judge recovery queue unavailable error=%s"
         (Keeper_approval_queue.storage_error_to_string error)
     | None -> ());
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
           "keeper_gate: recovered Auto Judge failed approval=%s code=%s detail=%s"
           failure.approval_id
           (Keeper_gate.auto_judge_resume_failure_code_to_string failure.code)
           failure.operator_detail)
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
  (* Auto Judge recovery renders prompts immediately. Prompt state is therefore
     a recovery prerequisite, not an eventually-consistent lazy task. *)
  bootstrap_prompt_state state;
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
  { state
  ; path_diagnostics = initialized.path_diagnostics
  ; domain_pool = initialized.domain_pool
  }
;;

let run ~sw ~env ~host ~port ~base_path ?input_base_path ~accept_store_quarantine
    ~make_routes ~make_request_handler ~make_h2_request_handler ~make_h2_error_handler () =
  let resolved_auth_config =
    match Server_auth_config.resolve (Server_auth_config.read_env ()) with
    | Ok config -> config
    | Error error ->
      raise
        (Env_config_core.Config_error
           (Server_auth_config.resolve_error_to_string error))
  in
  (match Server_auth.configure resolved_auth_config with
   | Ok () -> ()
   | Error error ->
     raise
       (Env_config_core.Config_error
          (Server_auth.configure_error_to_string error)));
  let clock, mono_clock, net, domain_mgr, proc_mgr, fs =
    init_runtime_context env
  in
  let configured_agent_transport = Masc_grpc_transport.configure_from_env () in
  let configured_http_mode = Env_config.Transport.configure_h2_from_env () in
  (* Route provider diagnostics into the structured log before any
     provider call runs (#25148). *)
  Provider_diag_log_sink.install ();
  (* 0. Dashboard bundle freshness — a stale bundle silently keeps calling
     routes the current binary already removed (#24332 governance->gate:
     the served SPA still called DELETE'd /api/v1/dashboard/governance for
     3+ days because scripts/build-dashboard-if-needed.sh was never re-run
     after the binary shipped). Cheap synchronous stat comparison; not worth
     its own fiber. *)
  Web_dashboard.log_bundle_freshness_warning ();
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
  let http_mode =
    match configured_http_mode with
    | Env_config.Transport.H2_only -> `H2_only
    | Env_config.Transport.H1_only -> `H1_only
    | Env_config.Transport.Auto -> `Auto
  in
  Transport_metrics.set_ws_same_origin_runtime_ready false;
  clear_server_state ();
  Server_startup_state.reset ();

  (* 2. Run owner initialization outside the accept loop. The state and
     long-lived owner fibers attach to the parent switch because HTTP request
     handlers use them after this setup fiber returns. A pre-readiness failure
     exits immediately rather than leaving that partial owner alive; only an
     auxiliary failure after readiness may continue as degraded serving. *)
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Switch.run ~name:"owner-initialization" @@ fun _ ->
    let handle_initialization_failure error =
      match
        startup_failure_disposition
          ~state_ready:(Server_startup_state.snapshot ()).state_ready
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
      Server_startup_state.mark_blocking ();
      let initialized_owner =
        initialize_owner_state_blocking ~sw ~env ~base_path ?input_base_path
          ~accept_store_quarantine ~clock ~mono_clock ~net ~domain_mgr ~proc_mgr ~fs ()
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
      publish_server_state state;
      (* Global readiness is the transport-neutral owner capability, not a
         quorum over optional transports. Mark it before starting fallible
         Discord/gRPC/WS/dashboard auxiliaries so one transport cannot
         turn an already-published HTTP owner into a process-wide fatal
         pre-readiness failure. Each auxiliary owns its typed health state. *)
      (match mark_owner_state_ready () with
       | Ok () -> ()
       | Error error -> raise (Owner_initialization_failed error));
      (* The lag probe forks here, on the main domain, so its ring reports
         the scheduler every handler on this domain shares. It starts at the
         readiness boundary rather than at process start so the boot replay
         is not counted as steady-state lag. *)
      (match Eio_context.get_mono_clock_opt () with
       | Some mono_clock ->
         Scheduler_lag.start ~sw ~mono_clock Scheduler_lag.global;
         Log.Server.info
           "scheduler lag probe started on the main domain: interval=%.0fms window=%.0fs"
           (Scheduler_lag.default_interval_s *. 1000.0)
           (Scheduler_lag.default_interval_s
            *. Float.of_int Scheduler_lag.default_window)
       | None ->
         Log.Server.warn
           "scheduler lag probe not started: Eio_context has no monotonic clock");
      (* Full-health has its own off-domain worker, timeout, and warm delay.
         Start it at the owner-readiness boundary so post-ready lanes and
         auxiliary prewarms cannot leave current diagnostics requested-but-idle. *)
      Server_routes_http_runtime.start_full_health_snapshot_refresh_loop
        ~sw
        ~clock
        ~request_authority:background_request_authority;
      (* Roots for GET /api/v1/diagnostics/heap-roots. Registered here, after
         owner readiness, because every store named below is installed by
         now; a walk before that would size the empty initial registries.
         Each root receives the walker and calls it itself, so a table that
         has a lock is walked under it. *)
      List.iter
        (fun (name, value) ->
           match Heap_roots.register ~name value with
           | Ok () -> ()
           | Error `Duplicate ->
             Log.Server.warn
               "heap root %S was already registered; the first registration stands"
               name)
        [ ("exact_lane_runs", fun walk -> walk (Some (Obj.repr (Exact_lane_run_registry.global ()))))
        ; ("verification_runs", fun walk -> walk (Some (Obj.repr (Verification_run_registry.global ()))))
        ; ( "goal_verification_runs"
          , fun walk -> walk (Some (Obj.repr (Goal_verification_run_registry.global ()))) )
        ; ("fusion_runs", fun walk -> walk (Some (Obj.repr (Fusion_run_registry.global ()))))
        ; ("sse_clients", fun walk -> walk (Some (Obj.repr (Atomic.get Sse.clients))))
        ; ("dashboard_snapshot", fun walk -> walk (Option.map Obj.repr (Dashboard_snapshot.current ())))
        ; ( "keeper_registry"
          , fun walk -> walk (Some (Obj.repr (Atomic.get Keeper_registry_setup.registry))) )
        ; ( "keeper_owner_pools"
          , fun walk -> Keeper_owner_registry.heap_root (fun value -> walk (Some value)) )
        ; ( "board_attention_partition_caches"
          , fun walk -> Keeper_board_attention_partition.heap_root (fun value -> walk (Some value)) )
        ; ( "activity_graph_caches"
          , fun walk -> Activity_graph.heap_root (fun value -> walk (Some value)) )
        ; ( "telemetry_trajectory_summaries"
          , fun walk -> Telemetry_unified.heap_root (fun value -> walk (Some value)) )
        ];
      let path_diagnostics = activated_owner.path_diagnostics in
      let resolved_base, masc_dir =
        start_post_ready_owner_lanes ~sw ~clock ~env state
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
      (* In-process iMessage connector, replacing the deleted
         sidecars/imessage-bot/ Python connector. Off unless Messages.app's
         chat.db is readable — on Linux it never is, and the start function
         records the reason and skips, leaving the server unaffected. *)
      Server_imessage_in_process_gateway.start ~sw ~env ~state;
      Server_bootstrap_http.print_startup_banner ~config ~resolved_base ~base_path
        ~masc_dir ~path_diagnostics;
      (* Auxiliary transports start after owner readiness and report their own
         availability. They must not gain lifecycle authority over HTTP or
         unrelated Keeper lanes. *)
      (* gRPC workspace transport (default-on, opt-out via MASC_GRPC_ENABLED=0) *)
      let tool_dispatcher tool_name args_json =
      Server_grpc_tool_dispatch.dispatch args_json ~dispatch:(fun arguments ->
          let workspace_scope = Mcp_server.workspace_scope state in
          let result =
            Mcp_server_eio_execute.execute_tool_eio
              ~sw
              ~clock
              ~workspace_scope
              state
              ~name:tool_name ~arguments
          in
          let success = not (Tool_result.is_failed result)
          and result_str = Tool_result.message result
          in
          if not success then
            Log.Server.error "gRPC tool call failed: tool=%s error_bytes=%d"
              tool_name (String.length result_str);
          if success then Ok result_str else Error result_str)
      in
      Masc_grpc_server.start ~sw ~env ~workspace_config:(Mcp_server.workspace_config state)
        ~tool_dispatcher;
      (* Initialize gRPC client for keeper heartbeat when transport is gRPC *)
      (match configured_agent_transport with
       | Masc_grpc_transport.Grpc ->
           (try
              let client = Masc_grpc_client.create_from_env ~sw ~env in
              Keeper_grpc_heartbeat.set_grpc_client ~env client;
              Log.Server.info "gRPC keeper client initialized"
            with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
              Log.Server.warn "gRPC keeper client init failed: %s"
                (Printexc.to_string exn))
       | Http | Ws | Local -> ());
      let dispatch_ws_inbound_message ws_session_id body_str =
          let jsonrpc_id_opt body =
            match Yojson.Safe.from_string body with
            | `Assoc fields -> (
                match List.assoc_opt "id" fields with
                | Some ((`Int _ | `String _ | `Null) as id) -> Some id
                | Some _ -> Some `Null
                | None -> None)
            | _ -> None
            | exception _ -> None (* cancel-guard-ok: the scrutinee is a decoded JSON value and the arms only pattern-match on it, so no fiber work runs under this handler *)
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
      (* WebSocket rides the HTTP listener's same-origin /ws upgrade
         (enabled by default, opt-out via MASC_WS_ENABLED=0). *)
      Transport_metrics.set_ws_same_origin_runtime_ready true;
      (* Register transport providers for unified bridge *)
      Transport_bridge.register_provider (module struct
        let name = "sse"
        let protocol = Transport.Sse
        let is_enabled () = true  (* SSE is always enabled *)
        let session_count () = Sse.client_count ()
      end);
      Transport_bridge.register_provider (module struct
        let name = "ws"
        let protocol = Transport.Ws
        let is_enabled () = Transport_metrics.ws_enabled ()
        let session_count () = Server_mcp_transport_ws.session_count ()
      end);
      Transport_bridge.register_provider (module struct
        let name = "grpc"
        let protocol = Transport.Grpc
        let is_enabled () = Masc_grpc_server.is_enabled ()
        let session_count () = 0  (* gRPC uses per-call, no persistent sessions *)
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
      Server_dashboard_http.start_operator_snapshot_refresh_loop
        ~state
        ~sw
        ~clock
        ~broadcast_snapshot:
          Server_dashboard_http_execution_surfaces.broadcast_operator_snapshot;
      Server_dashboard_http.start_operator_digest_refresh_loop
        ~state
        ~sw
        ~clock
        ~broadcast_digest:
          Server_dashboard_http_execution_surfaces.broadcast_operator_digest;
      (* Pre-warm primary dashboard surfaces in parallel across worker
         domains in a separate fiber so it cannot block lazy startup tasks
         or later keeper loop startup (#keeper-bootstrap-stuck). *)
      Atomic.set Server_dashboard_http.shell_warming true;
      Eio.Fiber.fork ~sw (fun () ->
        Eio.Switch.run ~name:"dashboard-shell-prewarm" @@ fun _ ->
        let outer_timeout_sec =
          Env_config_runtime.Dashboard.shell_prewarm_outer_timeout_sec
        in
        try
           match Eio.Time.with_timeout clock outer_timeout_sec (fun () ->
             Server_dashboard_http.warm_dashboard_surfaces state;
             Ok ())
           with
           | Ok () -> ()
           | Error `Timeout ->
             Log.Dashboard.warn "dashboard surfaces pre-warm timed out (%.1fs)"
               outer_timeout_sec
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
             Log.Dashboard.warn "dashboard surfaces pre-warm failed: %s"
             (Printexc.to_string exn));
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
    Eio.Switch.run ~name:"startup-watchdog" @@ fun _ ->
    try
      let timeout_sec = Server_startup_state.watchdog_timeout_sec () in
      Eio.Time.sleep clock timeout_sec;
      let current = Server_startup_state.snapshot () in
      if not current.state_ready then (
        let elapsed = Server_startup_state.elapsed_since_start () in
        Log.Server.error
          "[watchdog] Server init did not complete within %.0fs (elapsed=%.1fs, phase=%s). Exiting."
          timeout_sec elapsed
          (Server_startup_state.phase_to_string current.phase);
        exit 1)
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Server.error "startup watchdog fiber failed: %s"
        (Printexc.to_string exn));

  (* 3. Start serving -- /health responds before init completes *)
  let run_serving ~sw ~socket ~routes:_ ~request_handler ~h2_request_handler
      ~h2_error_handler =
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
  in
  if Env_config.Transport.serving_domain_enabled ()
  then (
    Log.Server.info
      "HTTP serving domain isolation enabled (RFC-0204 Phase 3): accept loop isolated on dedicated domain";
    Eio.Domain_manager.run domain_mgr (fun () ->
      (* This domain starts after [main_eio.ml] tuned the main one, and
         [Gc.set]'s minor_heap_size is per-domain, so it would otherwise
         serve every request on the 2 MB default -- the isolation this block
         exists for would be undone by the domain collecting eight times as
         often, and a minor collection stops every other domain with it. *)
      Domain_pool.tune_minor_heap ();
      Eio.Switch.run (fun serving_sw ->
        Eio_context.with_turn_switch serving_sw (fun () ->
          let socket =
            Server_bootstrap_http.listen_socket ~sw:serving_sw ~net config
          in
          let routes =
            make_routes ~port:config.port ~host:config.host ~sw:serving_sw ~clock
          in
          let request_handler =
            make_request_handler ~trust_policy:request_trust_policy routes
          in
          let h2_request_handler =
            make_h2_request_handler
              ~trust_policy:request_trust_policy
              ~sw:serving_sw
              ~clock
              ~server_start_time
          in
          let h2_error_handler = make_h2_error_handler () in
          run_serving
            ~sw:serving_sw
            ~socket
            ~routes
            ~request_handler
            ~h2_request_handler
            ~h2_error_handler))))
  else (
    let socket = Server_bootstrap_http.listen_socket ~sw ~net config in
    let routes = make_routes ~port:config.port ~host:config.host ~sw ~clock in
    let request_handler =
      make_request_handler ~trust_policy:request_trust_policy routes
    in
    let h2_request_handler =
      make_h2_request_handler
        ~trust_policy:request_trust_policy
        ~sw
        ~clock
        ~server_start_time
    in
    let h2_error_handler = make_h2_error_handler () in
    run_serving
      ~sw
      ~socket
      ~routes
      ~request_handler
      ~h2_request_handler
      ~h2_error_handler)
