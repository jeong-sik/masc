(** Cached execution and transport dashboard surfaces extracted from the
    dashboard HTTP facade. *)

open Server_utils
open Server_dashboard_http_core

let shell_prewarm_timeout_s = 30.0

let warm_shell_cache (state : Mcp_server.server_state) =
  Atomic.set _shell_warming true;
  Fun.protect
    ~finally:(fun () -> Atomic.set _shell_warming false)
    (fun () ->
      let t0 = Time_compat.now () in
      (try
         let cache_key =
           Printf.sprintf "shell:coord=%s:workspace=%s"
             state.Mcp_server.room_config.base_path
             state.Mcp_server.room_config.workspace_path
         in
         let compute () =
           dashboard_shell_payload_json state.Mcp_server.room_config
         in
         let result =
           match state.Mcp_server.clock with
           | Some clock ->
               Dashboard_cache.get_or_compute_with_timeout cache_key ~ttl:15.0
                 ~clock ~timeout_sec:shell_prewarm_timeout_s compute
           | None ->
               Dashboard_cache.get_or_compute cache_key ~ttl:15.0 compute
         in
         if is_dashboard_cache_timeout_json result then
           Log.Dashboard.warn
             "shell cache pre-warm timed out during compute (%.0fs)"
             shell_prewarm_timeout_s
         else begin
           Atomic.set _shell_warmed true;
           Atomic.set _last_good_shell result;
           Log.Dashboard.info "shell cache pre-warmed (%.1fms)"
             ((Time_compat.now () -. t0) *. 1000.0)
         end
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
           Log.Dashboard.warn "shell cache pre-warm failed: %s"
             (Printexc.to_string exn)))

(* Delta-push: track last broadcast hash per event_type to skip unchanged payloads. *)
let _last_broadcast_hash : (string, Digestif.SHA256.t) Hashtbl.t =
  Hashtbl.create 8

let _broadcast_hash_mu = Eio.Mutex.create ()

(** Broadcast a single cached surface to all Observer SSE sessions.
    [event_type] becomes the SSE event "type" field.
    Skips broadcast when payload hash matches the previous one (delta push).
    Mutex-protected: safe to call from concurrent fibers. *)
let broadcast_cached_surface ~event_type (json : Yojson.Safe.t) : unit =
  let serialized = Yojson.Safe.to_string json in
  let hash = Digestif.SHA256.digest_string serialized in
  let should_broadcast =
    Eio.Mutex.use_rw ~protect:true _broadcast_hash_mu (fun () ->
      let changed =
        match Hashtbl.find_opt _last_broadcast_hash event_type with
        | Some prev -> not (Digestif.SHA256.equal prev hash)
        | None -> true
      in
      if changed then (Hashtbl.replace _last_broadcast_hash event_type hash; true)
      else false)
  in
  if should_broadcast then begin
    let sse_json =
      `Assoc
        [
          ("type", `String event_type);
          ("payload", json);
          ("ts_unix", `Float (Time_compat.now ()));
        ]
    in
    Sse.broadcast_to Observers sse_json
  end else
    Log.Dashboard.debug "%s: payload unchanged, skipping broadcast" event_type

(* Wire operator broadcast refs now that Sse is in scope. *)
let () =
  _operator_snapshot_broadcast_ref :=
    broadcast_cached_surface ~event_type:"operator_snapshot"

let () =
  _operator_digest_broadcast_ref :=
    broadcast_cached_surface ~event_type:"operator_digest"

let _execution_cache =
  create_cached_surface
    (`Assoc
      [
        ("status", `String "initializing");
        ("generated_at", `String (Types.now_iso ()));
        ( "message",
          `String "Execution data is being computed. Refresh in a few seconds."
        );
      ])

(** Invalidate the execution surface cache so the next
    [/api/v1/dashboard/execution] request recomputes fresh data.
    Called via [Coord_hooks.on_task_mutation_fn] after task add,
    batch_add, and all transitions (claim, start, done, cancel,
    release) routed through [observe_task_transition].
    Best-effort: never raises — cache staleness must not break
    the mutation path. *)
let invalidate_execution_cache () =
  (try invalidate_cached_surface _execution_cache with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
     Log.Dashboard.error "Failed to invalidate execution surface cache: %s"
       (Printexc.to_string exn));
  (try Dashboard_cache.invalidate "execution:default:light" with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
     Log.Dashboard.error "Failed to invalidate dashboard execution cache: %s"
       (Printexc.to_string exn))

(** Bypass the proactive warm-up guard so tests that call
    [dashboard_namespace_truth_http_json] get the full response instead of
    the "initializing" short-circuit. *)
let seed_execution_cache_for_test () =
  mark_cached_surface_success _execution_cache
    (`Assoc [ ("status", `String "seeded_for_test") ])

let _transport_health_cache =
  create_cached_surface
    (`Assoc
      [
        ("status", `String "initializing");
        ("generated_at", `String (Types.now_iso ()));
        ( "message",
          `String "Transport health data is warming up. Refresh in a few seconds."
        );
      ])

(* Issue #8396: cache patchers used to recognise only 7 lifecycle event
   names while [Keeper_lifecycle_events.all_event_names] now publishes
   10. The drift left dashboard rows stale until the next full
   recompute when the supervisor emitted [dead_cleaned],
   [self_preservation], [paused_pruned], or the phase-derived [running].

   The 4 patchers below remain string-typed (cache rows deserialise
   from JSON), but each [match] now covers every name in the SSOT.
   The sync test in [test/test_types.ml :: lifecycle_event_cache_patcher_coverage]
   asserts every name in [Keeper_lifecycle_events.all_event_names]
   returns [Some] from at least one of these patchers. *)

let keepalive_running_of_lifecycle_event = function
  | "started" | "restarted" | "reconciled" | "running" -> Some true
  | "resumed" | "self_preservation" -> Some true
  | "paused" -> Some true
  | "paused_pruned" -> Some false   (* prune == removed from supervision *)
  | "dead_cleaned" -> Some false    (* cleanup == no longer alive *)
  | "stopped" | "crashed" | "dead" -> Some false
  | _ -> None

let phase_of_lifecycle_event = function
  | "started" | "restarted" | "reconciled" | "running" -> Some "running"
  | "resumed" | "self_preservation" -> Some "running"
  | "paused" -> Some "paused"
  | "paused_pruned" -> Some "stopped"
  | "stopped" -> Some "stopped"
  | "crashed" -> Some "crashed"
  | "dead" | "dead_cleaned" -> Some "dead"
  | _ -> None

let pipeline_stage_of_lifecycle_event = function
  | "started" | "restarted" | "reconciled" | "running" -> Some "idle"
  | "resumed" | "self_preservation" -> Some "idle"
  | "paused" -> Some "paused"
  | "paused_pruned" -> Some "offline"
  | "stopped" | "dead" | "dead_cleaned" -> Some "offline"
  | "crashed" -> Some "crashed"
  | _ -> None

let paused_of_lifecycle_event = function
  | "started" | "restarted" | "reconciled" | "resumed" | "running"
  | "self_preservation" -> Some false
  | "paused" | "paused_pruned" | "stopped" -> Some true
  | "dead" | "dead_cleaned" | "crashed" -> Some false
  | _ -> None

let keeper_agent_status_opt row =
  let open Yojson.Safe.Util in
  match member "agent" row with
  | `Assoc _ as agent -> (
      match member "status" agent with
      | `String status -> Some status
      | _ -> None)
  | _ -> (
      match member "status" row with
      | `String status -> Some status
      | _ -> None)

let patched_keeper_status row ~keepalive_running =
  if not keepalive_running then
    `String "offline"
  else
    match keeper_agent_status_opt row with
    | Some (("busy" | "active" | "listening" | "idle") as status) ->
        `String status
    | Some ("offline" | "inactive") -> `String "offline"
    | _ -> `String "idle"

let patch_keeper_row ~keeper_name ~event ~keepalive_running = function
  | `Assoc fields as row -> (
      match Yojson.Safe.Util.member "name" row with
      | `String name when String.equal name keeper_name ->
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

let patch_keeper_rows ~keeper_name ~event ~keepalive_running rows =
  List.map (patch_keeper_row ~keeper_name ~event ~keepalive_running) rows

let running_keeper_names (config : Coord.config) =
  Keeper_types.keeper_names config
  |> List.filter_map (fun name ->
         match Keeper_types.read_meta config name with
         | Ok (Some meta)
           when Keeper_status_bridge.runtime_keepalive_running config meta ->
             Some name
         | _ -> None)

let patch_surface_json_for_running_keepers (config : Coord.config) = function
  | `Assoc fields as json ->
      let running = running_keeper_names config in
      if running = [] then json
      else
        let patch_rows rows =
          List.fold_left
            (fun acc keeper_name ->
              patch_keeper_rows ~keeper_name ~event:"reconciled"
                ~keepalive_running:true acc)
            rows running
        in
        (match List.assoc_opt "keepers" fields with
         | Some (`List rows) ->
             `Assoc
               (upsert_assoc_field "keepers" (`List (patch_rows rows)) fields)
         | Some (`Assoc keeper_fields) -> (
             match List.assoc_opt "items" keeper_fields with
             | Some (`List rows) ->
                 let keeper_fields =
                   upsert_assoc_field "items" (`List (patch_rows rows))
                     keeper_fields
                 in
                 `Assoc
                   (upsert_assoc_field "keepers" (`Assoc keeper_fields) fields)
             | _ -> json)
         | _ -> json)
  | other -> other

let patch_execution_cache_for_keeper ~keeper_name ~event ~keepalive_running =
  match _execution_cache.json with
  | `Assoc fields -> (
      match List.assoc_opt "keepers" fields with
      | Some (`List rows) ->
          _execution_cache.json <-
            `Assoc
              (upsert_assoc_field "keepers"
                 (`List (patch_keeper_rows ~keeper_name ~event ~keepalive_running rows))
                 fields)
      | _ -> ())
  | _ -> ()

let patch_operator_snapshot_cache_for_keeper ~keeper_name ~event ~keepalive_running =
  match _operator_snapshot_cache.json with
  | `Assoc fields -> (
      match List.assoc_opt "keepers" fields with
      | Some (`Assoc keeper_fields) -> (
          match List.assoc_opt "items" keeper_fields with
          | Some (`List rows) ->
              let keeper_fields =
                upsert_assoc_field "items"
                  (`List (patch_keeper_rows ~keeper_name ~event ~keepalive_running rows))
                  keeper_fields
              in
              _operator_snapshot_cache.json <-
                `Assoc
                  (upsert_assoc_field "keepers" (`Assoc keeper_fields) fields)
          | _ -> ())
      | _ -> ())
  | _ -> ()

let patch_keeper_dependent_caches ~keeper_name ~event =
  match keepalive_running_of_lifecycle_event event with
  | None -> ()
  | Some keepalive_running ->
      patch_execution_cache_for_keeper ~keeper_name ~event ~keepalive_running;
      patch_operator_snapshot_cache_for_keeper ~keeper_name ~event ~keepalive_running

(** Late-bound broadcast hook. Set after [broadcast_namespace_truth_snapshot]
    is defined in [Server_dashboard_http_namespace_truth]. *)
let _broadcast_namespace_truth_ref : (Mcp_server.server_state -> unit) ref =
  ref (fun (_state : Mcp_server.server_state) -> ())

(** Start the proactive execution refresh loop. When an Executor_pool is
    available, each refresh runs in a pool domain with a domain-local Caqti
    pool. Falls back to in-domain compute. *)
let start_execution_refresh_loop ~state ~sw ~clock ~net ~mono_clock =
  let room_config = state.Mcp_server.room_config in
  let proc_mgr = state.Mcp_server.proc_mgr in
  (* Default keeps timeout < interval (60s) so Proactive_refresh's clamp
     at start does not fire every boot. Env var override can still push
     above interval; runtime clamp remains the safety net. *)
  let execution_refresh_timeout_s =
    float_of_env_default "MASC_DASHBOARD_EXECUTION_REFRESH_TIMEOUT_S"
      ~default:48.0 ~min_v:30.0 ~max_v:300.0
  in
  let compute () =
    mark_cached_surface_attempt _execution_cache;
    let started_at = Unix.gettimeofday () in
    try
      run_dashboard_compute ~mode:Offloaded_readonly ~sw ~clock ~net
        ~mono_clock ~config:room_config
        (fun ~config ~sw ->
          Dashboard_execution.json ~light:true ~config ~sw ~clock ~proc_mgr ()
          |> patch_surface_json_for_running_keepers config
          |> with_projection_diagnostics ~surface:"execution" ~started_at
               ~extra:
                 [
                   ( "readonly_pool",
                     Coord_utils.domain_local_pg_backend_diagnostics_json () );
                 ])
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
        mark_cached_surface_error _execution_cache exn;
        raise exn
  in
  Proactive_refresh.start ~sw ~clock
    ~config:
      { (Proactive_refresh.default_config ~label:"execution" ~interval_s:60.0)
        with
        timeout_s = execution_refresh_timeout_s;
        warm_delay_s = 0.0;
      }
    ~compute
    ~on_result:(fun json ->
      mark_cached_surface_success _execution_cache json;
      broadcast_cached_surface ~event_type:"execution_snapshot" json;
      !_broadcast_namespace_truth_ref state)

let start_transport_health_refresh_loop ~state ~sw ~clock =
  let timeout_s =
    float_of_env_default "MASC_DASHBOARD_TRANSPORT_HEALTH_TIMEOUT_S"
      ~default:8.0 ~min_v:3.0 ~max_v:30.0
  in
  let compute () =
    mark_cached_surface_attempt _transport_health_cache;
    try Transport_metrics.transport_health_json ~config:state.Mcp_server.room_config
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
        mark_cached_surface_error _transport_health_cache exn;
        raise exn
  in
  let interval_s = 30.0 in
  Proactive_refresh.start ~sw ~clock
    ~config:
      { (Proactive_refresh.default_config ~label:"transport_health" ~interval_s)
        with
        timeout_s;
        warm_delay_s = 0.0;
      }
    ~compute
    ~on_result:(fun json ->
      mark_cached_surface_success _transport_health_cache json;
      broadcast_cached_surface ~event_type:"transport_health_snapshot" json)

let dashboard_execution_http_json ~state ~sw ~clock request =
  let net = state.Mcp_server.net in
  let mono_clock = state.Mcp_server.mono_clock in
  let fixture = query_param request "fixture" in
  let actor = operator_actor_hint request in
  let full_mode = bool_query_param request "full" ~default:false in
  let light = not full_mode in
  let compute ?actor ?fixture ~light () =
    let started_at = Unix.gettimeofday () in
    run_dashboard_compute ~mode:Offloaded_readonly ?net ?mono_clock ~sw
      ~clock ~config:state.Mcp_server.room_config (fun ~config ~sw ->
        Dashboard_execution.json ?actor ?fixture ~light ~config ~sw ~clock
          ~proc_mgr:state.Mcp_server.proc_mgr ()
        |> patch_surface_json_for_running_keepers config
        |> with_projection_diagnostics ~surface:"execution" ~started_at
             ~extra:
               [
                 ( "readonly_pool",
                   Coord_utils.domain_local_pg_backend_diagnostics_json () );
               ])
  in
  match fixture, actor, full_mode with
  | None, None, false ->
      (* Default light mode: stay instant after first success, but avoid
         serving the empty initializing payload forever when proactive warm-up
         misses its first build window. *)
      cached_surface_or_first_success_json _execution_cache
        ~cache_key:"execution:default:light" ~ttl:120.0 ~clock
        ~timeout_sec:120.0 (compute ~light:true)
  | _ ->
      (* Parameterized requests (fixture/actor/full): on-demand with SWR cache.
         These are rare (test fixtures, actor-specific views, full mode). *)
      let cache_key =
        Printf.sprintf "execution:%s:%s:%s"
          (Option.value ~default:"" actor)
          (Option.value ~default:"" fixture)
          (if full_mode then "full" else "light")
      in
      Dashboard_cache.get_or_compute_with_timeout cache_key ~ttl:120.0
        ~clock ~timeout_sec:120.0 (compute ?actor ?fixture ~light)

let transport_health_cache_diagnostics () =
  match cached_surface_json _transport_health_cache with
  | `Assoc fields -> (
      match List.assoc_opt "projection_diagnostics" fields with
      | Some (`Assoc diagnostics) -> diagnostics
      | _ -> [])
  | _ -> []

let dashboard_transport_health_http_json ~state =
  let live_json =
    Transport_metrics.transport_health_json ~config:state.Mcp_server.room_config
  in
  extend_projection_diagnostics live_json
    (("source", `String "live_metrics") :: transport_health_cache_diagnostics ())
