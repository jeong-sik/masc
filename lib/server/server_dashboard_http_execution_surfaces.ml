(** Cached execution and transport dashboard surfaces extracted from the
    dashboard HTTP facade. *)

open Server_utils
open Server_dashboard_http_core

type cached_surface = Server_dashboard_http_cache.cached_surface


let deep_surface_cache_ttl_s = Server_dashboard_http_core_cache.deep_surface_cache_ttl_s
let shell_surface_cache_ttl_s = Server_dashboard_http_core_cache.shell_surface_cache_ttl_s
let config_cache_ttl_s = Server_dashboard_http_core_cache.config_cache_ttl_s

(* Transport health probe timeout — env-overridable with sane bounds.
   SSOT: env_config_snapshot.ml also registers the same env var. *)
let transport_health_timeout_default_s = 8.0
let transport_health_timeout_min_s = 3.0
let transport_health_timeout_max_s = 30.0

(* Routed through Env_config_runtime.Dashboard so operators can raise
   the ceiling on slow-disk deployments without a rebuild. The outer
   wrapper at [server_runtime_bootstrap.ml] uses the matching
   [shell_prewarm_outer_timeout_sec] env to keep the 5s headroom. *)
let shell_prewarm_timeout_s = Env_config_runtime.Dashboard.shell_prewarm_inner_timeout_sec

let warm_shell_cache (state : Mcp_server.server_state) =
  Atomic.set shell_warming true;
  Eio_guard.protect
    ~finally:(fun () -> Atomic.set shell_warming false)
    (fun () ->
       let t0 = Time_compat.now () in
       let cache_shell_payload ~light =
         let cache_key =
           dashboard_shell_cache_key ~light (Mcp_server.workspace_config state)
         in
         let compute () =
           dashboard_shell_payload_json ~light (Mcp_server.workspace_config state)
         in
         match state.Mcp_server.clock with
         | Some clock ->
           Dashboard_cache.get_or_compute_with_timeout
             cache_key
             ~ttl:shell_surface_cache_ttl_s
             ~clock
             ~timeout_sec:shell_prewarm_timeout_s
             compute
         | None -> Dashboard_cache.get_or_compute cache_key ~ttl:shell_surface_cache_ttl_s compute
       in
       (try
          let light_result = cache_shell_payload ~light:true in
          if is_dashboard_cache_timeout_json light_result
          then
            Log.Dashboard.warn
              "light shell cache pre-warm timed out during compute (%.0fs)"
              shell_prewarm_timeout_s
          else (
            Atomic.set last_good_shell_light light_result;
            Log.Dashboard.info
              "light shell cache pre-warmed (%.1fms)"
              ((Time_compat.now () -. t0) *. 1000.0))
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Log.Dashboard.warn
            "light shell cache pre-warm failed: %s"
            (Printexc.to_string exn));
       try
         let result = cache_shell_payload ~light:false in
         if is_dashboard_cache_timeout_json result
         then
           Log.Dashboard.warn
             "shell cache pre-warm timed out during compute (%.0fs)"
             shell_prewarm_timeout_s
         else (
           Atomic.set shell_warmed true;
           Atomic.set last_good_shell result;
           Log.Dashboard.info
             "shell cache pre-warmed (%.1fms)"
             ((Time_compat.now () -. t0) *. 1000.0))
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Log.Dashboard.warn "shell cache pre-warm failed: %s" (Printexc.to_string exn))
;;

(* Delta-push: track last broadcast hash per event_type to skip unchanged payloads. *)
let last_broadcast_hash : (string, Digestif.SHA256.t) Hashtbl.t = Hashtbl.create 8
let broadcast_hash_mu = Eio.Mutex.create ()

(** Broadcast a single cached surface to all Observer SSE sessions.
    [event_type] becomes the SSE event "type" field.
    Skips broadcast when payload hash matches the previous one (delta push).
    Mutex-protected: safe to call from concurrent fibers. *)
let broadcast_cached_surface ~event_type (json : Yojson.Safe.t) : unit =
  let serialized = Yojson.Safe.to_string json in
  let hash = Digestif.SHA256.digest_string serialized in
  let should_broadcast =
    Eio.Mutex.use_rw ~protect:true broadcast_hash_mu (fun () ->
      let changed =
        match Hashtbl.find_opt last_broadcast_hash event_type with
        | Some prev -> not (Digestif.SHA256.equal prev hash)
        | None -> true
      in
      if changed
      then (
        Hashtbl.replace last_broadcast_hash event_type hash;
        true)
      else false)
  in
  if should_broadcast
  then (
    let sse_json =
      `Assoc
        [ "type", `String event_type
        ; "payload", json
        ; "ts_unix", `Float (Time_compat.now ())
        ]
    in
    Sse.broadcast_to Observers sse_json)
  else Log.Dashboard.routine "%s: payload unchanged, skipping broadcast" event_type
;;

let execution_actor_for_request ~base_path request =
  Server_auth.sanitized_dashboard_actor_for_request ~base_path request
;;

(* Wire operator broadcast refs now that Sse is in scope. *)
let () =
  operator_snapshot_broadcast_ref
  := broadcast_cached_surface ~event_type:"operator_snapshot"
;;

let () =
  operator_digest_broadcast_ref := broadcast_cached_surface ~event_type:"operator_digest"
;;

let execution_cache : cached_surface =
  Server_dashboard_http_cache.create_cached_surface
    (`Assoc
        [ "status", `String "initializing"
        ; "generated_at", `String (Masc_domain.now_iso ())
        ; "message", `String "Execution data is being computed. Refresh in a few seconds."
        ])
;;

let execution_default_light_cache_key = "execution:default:light"
let execution_default_light_http_body : string option Atomic.t = Atomic.make None

let clear_execution_default_light_http_body () =
  Atomic.set execution_default_light_http_body None
;;

let execution_surface_has_fresh_success () =
  match execution_cache.last_success_unix, execution_cache.last_error_unix with
  | Some success_ts, Some error_ts when error_ts > success_ts -> false
  | Some _, _ -> true
  | None, _ -> false
;;

let execution_trust_cache_key = "execution-trust:default"

let execution_trust_cache : cached_surface =
  Server_dashboard_http_cache.create_cached_surface
    (`Assoc
        [ "source", `String Dashboard_http_keeper_types.execution_trust_source
        ; "producer", `String Dashboard_http_keeper_types.execution_trust_producer
        ; "dashboard_surface", `String Dashboard_http_keeper_types.execution_trust_dashboard_surface
        ; "freshness_slo_s", `Float Dashboard_http_keeper_types.execution_trust_freshness_slo_s
        ; "entry_count", `Int 0
        ; "exists", `Bool false
        ; "generated_at", `String (Masc_domain.now_iso ())
        ; "keepers", `List []
        ; "total", `Int 0
        ; "coverage_gaps", `List []
        ; "coverage_gap_count", `Int 0
        ; "health", `String "initializing"
        ])
;;

let execution_trust_cache_mu = Eio.Mutex.create ()

let with_execution_trust_cache f =
  Eio.Mutex.use_rw ~protect:true execution_trust_cache_mu f
;;

(** Invalidate the execution surface cache so the next
    [/api/v1/dashboard/execution] request recomputes fresh data.
    Called via [Workspace_hooks.on_task_mutation_fn] after task add,
    batch_add, and all transitions (claim, start, done, cancel,
    release) routed through [observe_task_transition].
    Best-effort: never raises — cache staleness must not break
    the mutation path. *)
let record_invalidation_failure ~callback ~message exn =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string LifecycleCallbackFailures)
    ~labels:[ "callback", callback ]
    ();
  Log.Dashboard.error "%s: %s" message (Printexc.to_string exn)
;;

let invalidate_execution_cache_with_hooks_for_testing
      ~invalidate_execution_surface
      ~invalidate_light_cache
      ()
  =
  (try invalidate_execution_surface () with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     record_invalidation_failure
       ~callback:"execution_surface_cache_invalidate"
       ~message:"Failed to invalidate execution surface cache"
       exn);
  try invalidate_light_cache () with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    record_invalidation_failure
      ~callback:"dashboard_execution_light_cache_invalidate"
      ~message:"Failed to invalidate dashboard execution cache"
      exn
;;

let invalidate_execution_cache () =
  invalidate_execution_cache_with_hooks_for_testing
    ~invalidate_execution_surface:(fun () ->
      clear_execution_default_light_http_body ();
      Server_dashboard_http_cache.invalidate_cached_surface execution_cache)
    ~invalidate_light_cache:(fun () ->
      Dashboard_cache.invalidate execution_default_light_cache_key)
    ()
;;

(** Bypass the proactive warm-up guard so tests that call
    [dashboard_namespace_truth_http_json] get the full response instead of
    the "initializing" short-circuit. *)
let seed_execution_cache_for_test () =
  Server_dashboard_http_cache.mark_cached_surface_success
    execution_cache
    (`Assoc [ "status", `String "seeded_for_test" ])
;;

let transport_health_cache =
  Server_dashboard_http_cache.create_cached_surface
    (`Assoc
        [ "status", `String "initializing"
        ; "generated_at", `String (Masc_domain.now_iso ())
        ; ( "message"
          , `String "Transport health data is warming up. Refresh in a few seconds." )
        ])
;;

let cached_surface_assoc_field_opt key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let cached_surface_projection_fields json =
  match cached_surface_assoc_field_opt "projection_diagnostics" json with
  | Some (`Assoc fields) -> fields
  | _ -> []
;;

let cached_surface_projection_field json key =
  List.assoc_opt key (cached_surface_projection_fields json)
;;

let cached_surface_generated_at_iso json =
  match cached_surface_projection_field json "generated_at" with
  | Some (`String value) -> value
  | _ ->
    (match cached_surface_assoc_field_opt "generated_at" json with
     | Some (`String value) -> value
     | _ -> Masc_domain.now_iso ())
;;

let cached_surface_cache_json
      ?cache_key
      ~scope
      ~ttl_s
      ~timeout_s
      ~background_refresh_interval_s
      json
  =
  let diagnostic_field key =
    match cached_surface_projection_field json key with
    | Some value -> value
    | None -> `Null
  in
  let cache_state =
    match cached_surface_projection_field json "cache_state" with
    | Some (`String value) -> value
    | _ -> "request_swr_or_inline_compute"
  in
  `Assoc
    [ "scope", `String scope
    ; "cache_state", `String cache_state
    ; "projection_surface", diagnostic_field "surface"
    ; "last_success_at", diagnostic_field "last_success_at"
    ; "last_attempt_at", diagnostic_field "last_attempt_at"
    ; "last_error_at", diagnostic_field "last_error_at"
    ; "stale_reason", diagnostic_field "stale_reason"
    ; "stale_age_ms", diagnostic_field "stale_age_ms"
    ; "request_cache_key", Json_util.string_opt_to_json cache_key
    ; "request_cache_ttl_s", `Float ttl_s
    ; "request_timeout_s", `Float timeout_s
    ; "background_refresh_interval_s", `Float background_refresh_interval_s
    ; "policy", `String "cached_surface plus HTTP stale-while-revalidate"
    ]
;;

let with_cached_dashboard_surface_metadata
      ~(config : Workspace_utils.config)
      ?cache_key
      ~dashboard_surface
      ~source
      ~scope
      ~producer
      ~store_kind
      ~ttl_s
      ~timeout_s
      ~background_refresh_interval_s
      ~query
      json
  =
  match json with
  | `Assoc fields ->
    let metadata_keys =
      [ "dashboard_surface"
      ; "source"
      ; "generated_at_iso"
      ; "retention"
      ; "query"
      ; "cache"
      ]
    in
    let metadata =
      [ "dashboard_surface", `String dashboard_surface
      ; "source", `String source
      ; "generated_at_iso", `String (cached_surface_generated_at_iso json)
      ; ( "retention"
        , `Assoc
            [ "scope", `String scope
            ; "workspace_root", `String config.base_path
            ; "workspace_path", `String config.workspace_path
            ; "producer", `String producer
            ; "store_kind", `String store_kind
            ; "cache_surface", `String "Server_dashboard_http_execution_surfaces.cached_surface"
            ; "http_swr_ttl_s", `Float ttl_s
            ; "background_refresh_interval_s", `Float background_refresh_interval_s
            ; "request_timeout_s", `Float timeout_s
            ; ( "cache_policy"
              , `String
                  "default route uses proactive cached_surface; parameterized route uses HTTP stale-while-revalidate"
              )
            ] )
      ; ( "query", query )
      ; ( "cache"
        , cached_surface_cache_json
            ?cache_key
            ~scope
            ~ttl_s
            ~timeout_s
            ~background_refresh_interval_s
            json )
      ]
    in
    let fields =
      List.filter (fun (key, _) -> not (List.mem key metadata_keys)) fields
    in
    `Assoc (metadata @ fields)
  | other -> other
;;

let execution_query_json ~actor ~fixture ~full_mode ~light ~default_light_request ~force =
  `Assoc
    [ "actor", Json_util.string_opt_to_json actor
    ; "fixture", Json_util.string_opt_to_json fixture
    ; "full", `Bool full_mode
    ; "light", `Bool light
    ; "default_light_request", `Bool default_light_request
    ; "force", `Bool force
    ]
;;

let default_light_execution_query =
  execution_query_json
    ~actor:None
    ~fixture:None
    ~full_mode:false
    ~light:true
    ~default_light_request:true
    ~force:false
;;

let with_execution_metadata ~config ?cache_key ~query json =
  with_cached_dashboard_surface_metadata
    ~config
    ?cache_key
    ~dashboard_surface:"/api/v1/dashboard/execution"
    ~source:"dashboard_execution_read_model"
    ~scope:"dashboard_execution"
    ~producer:"Dashboard_execution.json"
    ~store_kind:"process_cache"
    ~ttl_s:deep_surface_cache_ttl_s
    ~timeout_s:Env_config_runtime.Dashboard.execution_timeout_sec
    ~background_refresh_interval_s:60.0
    ~query
    json
;;

let execution_default_light_response_json ~config =
  Server_dashboard_http_cache.cached_surface_json execution_cache
  |> with_execution_metadata
       ~config
       ~cache_key:execution_default_light_cache_key
       ~query:default_light_execution_query
;;

let cache_execution_default_light_http_body response_json =
  if execution_surface_has_fresh_success ()
  then
    Atomic.set
      execution_default_light_http_body
      (Some (Yojson.Safe.to_string response_json))
  else clear_execution_default_light_http_body ()
;;

let refresh_execution_default_light_http_body ~config =
  let response_json = execution_default_light_response_json ~config in
  cache_execution_default_light_http_body response_json;
  response_json
;;

let transport_health_query_json () =
  `Assoc [ "default_snapshot_request", `Bool true ]
;;

let with_transport_health_metadata ~config ~timeout_s json =
  with_cached_dashboard_surface_metadata
    ~config
    ~dashboard_surface:"/api/v1/dashboard/transport-health"
    ~source:"transport_health_read_model"
    ~scope:"dashboard_transport_health"
    ~producer:"Transport_metrics.transport_health_json"
    ~store_kind:"process_cache"
    ~ttl_s:config_cache_ttl_s
    ~timeout_s
    ~background_refresh_interval_s:30.0
    ~query:(transport_health_query_json ())
    json
;;

let dashboard_execution_snapshot_json () = Server_dashboard_http_cache.cached_surface_json execution_cache

let dashboard_transport_health_snapshot_json () =
  Server_dashboard_http_cache.cached_surface_json transport_health_cache
;;

(* Issue #8396 / #22071: cache patchers project a wire lifecycle event name onto
   dashboard row fields (keepalive_running / phase / pipeline_stage / paused).
   Cache rows deserialise from JSON, so the input is a [string]; but the closed
   custom-event vocabulary ([Keeper_lifecycle_events.t]) is parsed to the typed
   verb and matched EXHAUSTIVELY in [display_of_custom_event]. Adding a custom
   lifecycle variant now fails to compile here until its projection is defined —
   replacing the prior raw-string whitelist that silently dropped new variants
   to [None] (and an in-doc reference to a coverage test that did not exist).

   Phase-derived names ([running]/[stopped]/[crashed]/[dead]) and legacy operator
   strings ([paused]/[resumed]) are not custom-event verbs and cross the JSON
   boundary as raw strings, so they stay string-keyed and fail closed to [None]
   for unknown input. Coverage over the SSOT vocabulary is pinned by
   [test/test_dashboard_http_core.ml :: lifecycle_event_cache_patcher_coverage]. *)

type lifecycle_display =
  { ld_keepalive_running : bool
  ; ld_phase : string
  ; ld_pipeline_stage : string
  ; ld_paused : bool
  }

type lifecycle_legacy_wire_event =
  | Legacy_running
  | Legacy_stopped
  | Legacy_crashed
  | Legacy_dead
  | Legacy_paused
  | Legacy_resumed

(* Exhaustive over the closed custom-event sum. A new [Keeper_lifecycle_events.t]
   variant breaks this match (no catch-all) until its dashboard projection is
   declared. Values are byte-identical to the prior per-field string whitelist. *)
let display_of_custom_event (verb : Keeper_lifecycle_events.t) : lifecycle_display =
  let open Keeper_lifecycle_events in
  match verb with
  | Started | Restarted | Reconciled ->
    { ld_keepalive_running = true; ld_phase = "running"; ld_pipeline_stage = "idle"; ld_paused = false }
  | Purged ->
    { ld_keepalive_running = false; ld_phase = "stopped"; ld_pipeline_stage = "offline"; ld_paused = false }
  | Admission_denied ->
    (* admission guard refused to launch a fiber *)
    { ld_keepalive_running = false; ld_phase = "offline"; ld_pipeline_stage = "offline"; ld_paused = false }
  | Dead_cleaned ->
    (* cleanup == no longer alive *)
    { ld_keepalive_running = false; ld_phase = "dead"; ld_pipeline_stage = "offline"; ld_paused = false }
;;

(* Phase-derived + legacy operator strings (not custom-event verbs). Raw-string
   keyed by necessity (JSON boundary); unknown input fails closed to [None]. *)
let lifecycle_legacy_wire_event_of_string = function
  | "running" -> Some Legacy_running
  | "stopped" -> Some Legacy_stopped
  | "crashed" -> Some Legacy_crashed
  | "dead" -> Some Legacy_dead
  | "paused" -> Some Legacy_paused
  | "resumed" -> Some Legacy_resumed
  | _ -> None
;;

let display_of_phase_or_legacy_event = function
  | Legacy_running ->
    Some { ld_keepalive_running = true; ld_phase = "running"; ld_pipeline_stage = "idle"; ld_paused = false }
  | Legacy_stopped ->
    Some
      { ld_keepalive_running = false; ld_phase = "stopped"; ld_pipeline_stage = "offline"; ld_paused = true }
  | Legacy_crashed ->
    Some
      { ld_keepalive_running = false; ld_phase = "crashed"; ld_pipeline_stage = "crashed"; ld_paused = false }
  | Legacy_dead ->
    Some { ld_keepalive_running = false; ld_phase = "dead"; ld_pipeline_stage = "offline"; ld_paused = false }
  | Legacy_paused ->
    Some { ld_keepalive_running = true; ld_phase = "paused"; ld_pipeline_stage = "paused"; ld_paused = true }
  | Legacy_resumed ->
    Some { ld_keepalive_running = true; ld_phase = "running"; ld_pipeline_stage = "idle"; ld_paused = false }

let display_of_phase_or_legacy_string s =
  match lifecycle_legacy_wire_event_of_string s with
  | None -> None
  | Some event -> display_of_phase_or_legacy_event event
;;

let lifecycle_display_of_event event =
  match Keeper_lifecycle_events.event_of_string event with
  | Some verb -> Some (display_of_custom_event verb)
  | None -> display_of_phase_or_legacy_string event
;;

let keepalive_running_of_lifecycle_event event =
  Option.map (fun (d : lifecycle_display) -> d.ld_keepalive_running) (lifecycle_display_of_event event)
;;

let phase_of_lifecycle_event event =
  Option.map (fun (d : lifecycle_display) -> d.ld_phase) (lifecycle_display_of_event event)
;;

let pipeline_stage_of_lifecycle_event event =
  Option.map (fun (d : lifecycle_display) -> d.ld_pipeline_stage) (lifecycle_display_of_event event)
;;

let paused_of_lifecycle_event event =
  Option.map (fun (d : lifecycle_display) -> d.ld_paused) (lifecycle_display_of_event event)
;;

let keeper_agent_status_opt row =
  match Json_util.assoc_member_opt "agent" row with
  | Some (`Assoc _ as agent) ->
    (match Json_util.assoc_member_opt "status" agent with
     | Some (`String status) -> Some status
     | _ -> None)
  | None | Some _ ->
    (match Json_util.assoc_member_opt "status" row with
     | Some (`String status) -> Some status
     | _ -> None)
;;

let patched_keeper_status row ~keepalive_running =
  if not keepalive_running
  then `String "offline"
  else (
    (* RFC-0089: classify the row's display status via the typed surface_status
       SSOT. busy/active/listening/idle pass through; inactive/offline collapse
       to "offline"; anything outside the domain defaults to "idle". *)
    match
      Option.bind (keeper_agent_status_opt row)
        Keeper_status_runtime.surface_status_of_string_opt
    with
    | Some ((Surface_busy | Surface_active | Surface_listening | Surface_idle) as s) ->
      `String (Keeper_status_runtime.surface_status_to_string s)
    | Some (Surface_offline | Surface_inactive) -> `String "offline"
    | None -> `String "idle")
;;

let patch_keeper_row ~keeper_name ~event ~keepalive_running = function
  | `Assoc fields as row ->
    (match Json_util.assoc_member_opt "name" row with
     | Some (`String name) when String.equal name keeper_name ->
       let row_fields : (string * Yojson.Safe.t) list = fields in
       let row_fields =
         row_fields
         |> upsert_assoc_field "keepalive_running" (`Bool keepalive_running)
         |> upsert_assoc_field "status" (patched_keeper_status row ~keepalive_running)
       in
       let row_fields =
         match paused_of_lifecycle_event event with
         | Some paused -> upsert_assoc_field "paused" (`Bool paused) row_fields
         | None -> row_fields
       in
       let row_fields =
         match phase_of_lifecycle_event event with
         | Some phase -> upsert_assoc_field "phase" (`String phase) row_fields
         | None -> row_fields
       in
       let row_fields =
         match pipeline_stage_of_lifecycle_event event with
         | Some stage -> upsert_assoc_field "pipeline_stage" (`String stage) row_fields
         | None -> row_fields
       in
       `Assoc row_fields
     | _ -> row)
  | other -> other
;;

let patch_keeper_rows ~keeper_name ~event ~keepalive_running rows =
  List.map (patch_keeper_row ~keeper_name ~event ~keepalive_running) rows
;;

let running_keeper_names (config : Workspace.config) =
  Keeper_meta_store.keeper_names config
  |> List.filter_map (fun name ->
    match Keeper_meta_store.read_meta config name with
    | Ok (Some meta) when Keeper_status_bridge.runtime_keepalive_running config meta ->
      Some name
    | _ -> None)
;;

let patch_surface_json_for_running_keepers (config : Workspace.config) = function
  | `Assoc fields as json ->
    let running = running_keeper_names config in
    if running = []
    then json
    else (
      let patch_rows rows =
        List.fold_left
          (fun acc keeper_name ->
             patch_keeper_rows
               ~keeper_name
               ~event:"reconciled"
               ~keepalive_running:true
               acc)
          rows
          running
      in
      match List.assoc_opt "keepers" fields with
      | Some (`List rows) ->
        `Assoc (upsert_assoc_field "keepers" (`List (patch_rows rows)) fields)
      | Some (`Assoc keeper_fields) ->
        (match List.assoc_opt "items" keeper_fields with
         | Some (`List rows) ->
           let keeper_fields =
             upsert_assoc_field "items" (`List (patch_rows rows)) keeper_fields
           in
           `Assoc (upsert_assoc_field "keepers" (`Assoc keeper_fields) fields)
         | _ -> json)
      | _ -> json)
  | other -> other
;;

let patchexecution_cache_for_keeper ~keeper_name ~event ~keepalive_running =
  clear_execution_default_light_http_body ();
  match execution_cache.json with
  | `Assoc fields ->
    (match List.assoc_opt "keepers" fields with
     | Some (`List rows) ->
       execution_cache.json
       <- `Assoc
            (upsert_assoc_field
               "keepers"
               (`List (patch_keeper_rows ~keeper_name ~event ~keepalive_running rows))
               fields)
     | Some _ -> ()
     | None -> ())
  | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> ()
;;

let patch_operator_snapshot_cache_for_keeper ~keeper_name ~event ~keepalive_running =
  match operator_snapshot_cache.json with
  | `Assoc fields ->
    (match List.assoc_opt "keepers" fields with
     | Some (`Assoc keeper_fields) ->
       (match List.assoc_opt "items" keeper_fields with
        | Some (`List rows) ->
          let keeper_fields =
            upsert_assoc_field
              "items"
              (`List (patch_keeper_rows ~keeper_name ~event ~keepalive_running rows))
              keeper_fields
          in
          operator_snapshot_cache.json
          <- `Assoc (upsert_assoc_field "keepers" (`Assoc keeper_fields) fields)
        | Some _ -> ()
        | None -> ())
     | Some _ -> ()
     | None -> ())
  | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> ()
;;

let patch_keeper_dependent_caches ~keeper_name ~event =
  match keepalive_running_of_lifecycle_event event with
  | None -> ()
  | Some keepalive_running ->
    patchexecution_cache_for_keeper ~keeper_name ~event ~keepalive_running;
    patch_operator_snapshot_cache_for_keeper ~keeper_name ~event ~keepalive_running
;;

(** Late-bound broadcast hook. Set after [broadcast_namespace_truth_snapshot]
    is defined in [Server_dashboard_http_namespace_truth]. *)
let broadcast_namespace_truth_ref : (Mcp_server.server_state -> unit) ref =
  ref (fun (_state : Mcp_server.server_state) -> ())
;;

(** Start the proactive execution refresh loop. When an Executor_pool is
    available, each refresh runs in a pool domain with a domain-local Caqti
    pool. Falls back to in-domain compute. *)
let start_execution_refresh_loop ~state ~sw ~clock ~net ~mono_clock =
  let workspace_config = (Mcp_server.workspace_config state) in
  let proc_mgr = state.Mcp_server.proc_mgr in
  (* Default keeps timeout < interval (60s) so Proactive_refresh's clamp
     at start does not fire every boot. Env var override can still push
     above interval; runtime clamp remains the safety net. *)
  let execution_refresh_timeout_s =
    float_of_env_default
      "MASC_DASHBOARD_EXECUTION_REFRESH_TIMEOUT_S"
      ~default:48.0
      ~min_v:30.0
      ~max_v:300.0
  in
  let compute () =
    clear_execution_default_light_http_body ();
    Server_dashboard_http_cache.mark_cached_surface_attempt execution_cache;
    let started_at = Unix.gettimeofday () in
    try
      run_dashboard_compute
        ~mode:Offloaded_readonly
        ~sw
        ~clock
        ~net
        ~mono_clock
        ~config:workspace_config
        (fun ~config ~sw ->
           Dashboard_execution.json ~light:true ~config ~sw ~clock ~proc_mgr ()
           |> patch_surface_json_for_running_keepers config
           |> with_projection_diagnostics
                ~surface:"execution"
                ~started_at
                ~extra:
                  [ ( "readonly_pool"
                    , Workspace_utils.domain_local_pg_backend_diagnostics_json () )
                  ])
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      clear_execution_default_light_http_body ();
      Server_dashboard_http_cache.mark_cached_surface_error execution_cache exn;
      raise exn
  in
  Proactive_refresh.start
    ~sw
    ~clock
    ~config:
      { (Proactive_refresh.default_config ~label:"execution" ~interval_s:60.0) with
        timeout_s = execution_refresh_timeout_s
      ; on_error =
          Some
            (fun exn ->
              clear_execution_default_light_http_body ();
              Server_dashboard_http_cache.mark_cached_surface_error execution_cache exn)
      ; warm_delay_s = 0.0
      }
    ~compute
    ~on_result:(fun json ->
      Server_dashboard_http_cache.mark_cached_surface_success execution_cache json;
      broadcast_cached_surface
        ~event_type:"execution_snapshot"
        (refresh_execution_default_light_http_body ~config:workspace_config);
      !broadcast_namespace_truth_ref state)
;;

let dashboard_execution_cached_http_body ~state request =
  let config = Mcp_server.workspace_config state in
  let fixture = query_param request "fixture" in
  let actor = execution_actor_for_request ~base_path:config.base_path request in
  let full_mode = bool_query_param request "full" ~default:false in
  let force = bool_query_param request "force" ~default:false in
  match fixture, actor, full_mode, force, Atomic.get execution_default_light_http_body with
  | None, None, false, false, Some body when execution_surface_has_fresh_success () ->
    Some body
  | _ -> None
;;

let start_transport_health_refresh_loop ~state ~sw ~clock =
  let timeout_s =
    float_of_env_default
      "MASC_DASHBOARD_TRANSPORT_HEALTH_TIMEOUT_S"
      ~default:transport_health_timeout_default_s
      ~min_v:transport_health_timeout_min_s
      ~max_v:transport_health_timeout_max_s
  in
  let compute () =
    Server_dashboard_http_cache.mark_cached_surface_attempt transport_health_cache;
    try Transport_metrics.transport_health_json ~config:(Mcp_server.workspace_config state) with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Server_dashboard_http_cache.mark_cached_surface_error transport_health_cache exn;
      raise exn
  in
  let interval_s = 30.0 in
  Proactive_refresh.start
    ~sw
    ~clock
    ~config:
      { (Proactive_refresh.default_config ~label:"transport_health" ~interval_s) with
        timeout_s
      ; on_error = Some (Server_dashboard_http_cache.mark_cached_surface_error transport_health_cache)
      ; warm_delay_s = 0.0
      }
    ~compute
    ~on_result:(fun json ->
      Server_dashboard_http_cache.mark_cached_surface_success transport_health_cache json;
      broadcast_cached_surface
        ~event_type:"transport_health_snapshot"
        (Server_dashboard_http_cache.cached_surface_json transport_health_cache
         |> with_transport_health_metadata
              ~config:(Mcp_server.workspace_config state)
              ~timeout_s))
;;

let compute_execution_trust_json ~state ~sw ~clock =
  (* NDT-OK: wall-clock is projection timing telemetry only; execution-trust
     content and routing do not branch on this value. *)
  let started_at = Unix.gettimeofday () in
  run_dashboard_compute
    ~mode:Offloaded_readonly
    ?net:state.Mcp_server.net
    ?mono_clock:state.Mcp_server.mono_clock
    ~sw
    ~clock
    ~config:(Mcp_server.workspace_config state)
    (fun ~config ~sw:_ ->
       Dashboard_http_keeper.execution_trust_dashboard_json config
       |> with_projection_diagnostics
            ~surface:"execution_trust"
            ~started_at
            ~extra:[])
;;

let start_execution_trust_refresh_loop ~state ~sw ~clock =
  let compute () =
    with_execution_trust_cache (fun () ->
      Server_dashboard_http_cache.mark_cached_surface_attempt execution_trust_cache);
    compute_execution_trust_json ~state ~sw ~clock
  in
  Proactive_refresh.start
    ~sw
    ~clock
    ~config:
      { (Proactive_refresh.default_config
           ~label:"execution_trust"
           ~interval_s:Dashboard_http_keeper_types.execution_trust_refresh_interval_s)
        with
        timeout_s = Env_config_runtime.Dashboard.execution_trust_timeout_sec
      ; on_error =
          Some
            (fun exn ->
              with_execution_trust_cache (fun () ->
                Server_dashboard_http_cache.mark_cached_surface_error
                  execution_trust_cache
                  exn))
      ; warm_delay_s = 0.0
      }
    ~compute
    ~on_result:
      (fun json ->
        with_execution_trust_cache (fun () ->
          Server_dashboard_http_cache.mark_cached_surface_success
            execution_trust_cache
            json))
;;

let dashboard_execution_http_json ~state ~sw ~clock request =
  let config = (Mcp_server.workspace_config state) in
  let net = state.Mcp_server.net in
  let mono_clock = state.Mcp_server.mono_clock in
  let fixture = query_param request "fixture" in
  let actor =
    execution_actor_for_request ~base_path:config.base_path request
  in
  let full_mode = bool_query_param request "full" ~default:false in
  let force = bool_query_param request "force" ~default:false in
  let light = not full_mode in
  let query =
    execution_query_json
      ~actor
      ~fixture
      ~full_mode
      ~light
      ~default_light_request:(fixture = None && actor = None && not full_mode && not force)
      ~force
  in
  let compute ?actor ?fixture ~light () =
    let started_at = Unix.gettimeofday () in
    run_dashboard_compute
      ~mode:Offloaded_readonly
      ?net
      ?mono_clock
      ~sw
      ~clock
      ~config
      (fun ~config ~sw ->
         Dashboard_execution.json
           ?actor
           ?fixture
           ~light
           ~config
           ~sw
           ~clock
           ~proc_mgr:state.Mcp_server.proc_mgr
           ()
         |> patch_surface_json_for_running_keepers config
         |> with_projection_diagnostics
              ~surface:"execution"
              ~started_at
              ~extra:
                [ "readonly_pool", Workspace_utils.domain_local_pg_backend_diagnostics_json ()
                ])
  in
  match fixture, actor, full_mode with
  | None, None, false when force ->
    let timeout_sec = Env_config_runtime.Dashboard.execution_timeout_sec in
    let compute_and_track () =
      clear_execution_default_light_http_body ();
      Server_dashboard_http_cache.mark_cached_surface_attempt execution_cache;
      try
        let json = compute ~light:true () in
        Server_dashboard_http_cache.mark_cached_surface_success execution_cache json;
        let (_ : Yojson.Safe.t) =
          refresh_execution_default_light_http_body ~config
        in
        Server_dashboard_http_cache.cached_surface_json execution_cache
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        clear_execution_default_light_http_body ();
        Server_dashboard_http_cache.mark_cached_surface_error execution_cache exn;
        raise exn
    in
    (match
       Eio.Time.with_timeout clock timeout_sec (fun () -> Ok (compute_and_track ()))
     with
     | Ok json -> json
     | Error `Timeout ->
       let exn =
         Dashboard_cache.Compute_timeout (execution_default_light_cache_key, false)
       in
       clear_execution_default_light_http_body ();
       Server_dashboard_http_cache.mark_cached_surface_error execution_cache exn;
       Log.Dashboard.warn
         "dashboard execution force refresh timed out: %s (%.0fs)"
         execution_default_light_cache_key
         timeout_sec;
       `Assoc
         [ "error", `String "computation_timeout"
         ; "message",
           `String
             (Printf.sprintf
                "Dashboard %s timed out after %.0fs"
                execution_default_light_cache_key
                timeout_sec)
         ; "generated_at", `String (Masc_domain.now_iso ())
         ; "timeout_kind", `String "owner"
         ; "timeout_sec", `Float timeout_sec
         ; "key", `String execution_default_light_cache_key
         ])
    |> with_execution_metadata
         ~config
         ~cache_key:execution_default_light_cache_key
         ~query
  | None, None, false ->
    (* Default light mode: stay instant after first success, but avoid
         serving the empty initializing payload forever when proactive warm-up
         misses its first build window. *)
    let json =
      Server_dashboard_http_cache.cached_surface_or_first_success_json
        execution_cache
        ~cache_key:execution_default_light_cache_key
        ~ttl:deep_surface_cache_ttl_s
        ~clock
        ~timeout_sec:Env_config_runtime.Dashboard.execution_timeout_sec
        (compute ~light:true)
    in
    let response_json =
      with_execution_metadata
        ~config
        ~cache_key:execution_default_light_cache_key
        ~query
        json
    in
    cache_execution_default_light_http_body response_json;
    response_json
  | _ ->
    (* Parameterized requests (fixture/actor/full): on-demand with SWR cache.
         These are rare (test fixtures, actor-specific views, full mode). *)
    let cache_key =
      Printf.sprintf
        "execution:%s:%s:%s"
        (Option.value ~default:"" actor)
        (Option.value ~default:"" fixture)
        (if full_mode then "full" else "light")
    in
    Dashboard_cache.get_or_compute_with_timeout
      cache_key
      ~ttl:deep_surface_cache_ttl_s
      ~clock
      ~timeout_sec:Env_config_runtime.Dashboard.execution_timeout_sec
      (compute ?actor ?fixture ~light)
    |> with_execution_metadata ~config ~cache_key ~query
;;

let dashboard_execution_trust_http_json ~state ~sw ~clock _request =
  let attach_surface_envelope json =
    Server_dashboard_surface.attach
      ~surface:Dashboard_http_keeper_types.execution_trust_dashboard_surface
      ~source:Dashboard_http_keeper_types.execution_trust_source
      ~cache_key:execution_trust_cache_key
      ~ttl_s:shell_surface_cache_ttl_s
      json
  in
  with_execution_trust_cache (fun () ->
    Server_dashboard_http_cache.cached_surface_or_first_success_json
      execution_trust_cache
      ~cache_key:execution_trust_cache_key
      ~ttl:shell_surface_cache_ttl_s
      ~clock
      ~timeout_sec:Env_config_runtime.Dashboard.execution_trust_timeout_sec
      (fun () -> compute_execution_trust_json ~state ~sw ~clock))
  |> attach_surface_envelope
;;

let transport_health_cache_diagnostics () =
  match Server_dashboard_http_cache.cached_surface_json transport_health_cache with
  | `Assoc fields ->
    (match List.assoc_opt "projection_diagnostics" fields with
     | Some (`Assoc diagnostics) -> diagnostics
     | _ -> [])
  | _ -> []
;;

let dashboard_transport_health_http_json ~state =
  let timeout_s =
    float_of_env_default
      "MASC_DASHBOARD_TRANSPORT_HEALTH_TIMEOUT_S"
      ~default:transport_health_timeout_default_s
      ~min_v:transport_health_timeout_min_s
      ~max_v:transport_health_timeout_max_s
  in
  let json = Server_dashboard_http_cache.cached_surface_json transport_health_cache in
  extend_projection_diagnostics
    json
    (("source", `String "cached_surface") :: transport_health_cache_diagnostics ())
  |> with_transport_health_metadata
       ~config:(Mcp_server.workspace_config state)
       ~timeout_s
;;
