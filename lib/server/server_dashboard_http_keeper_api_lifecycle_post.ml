(** Lifecycle POST handler (boot/shutdown/reset/clear) for keeper dashboard API,
    plus execution-surface cache helpers used by lifecycle + directive handlers. *)

open Server_dashboard_http_keeper_api_types

module Http = Http_server_eio

let error_json ?ok message =
  let fields = [ ("error", `String message) ] in
  let fields =
    match ok with
    | None -> fields
    | Some value -> ("ok", `Bool value) :: fields
  in
  `Assoc fields

let respond_error ?(status = `Bad_request) ?request ?ok reqd message =
  Http.Response.json_value ?request ~status (error_json ?ok message) reqd

let tool_detail_json body =
  try Yojson.Safe.from_string body with
  | Yojson.Json_error _ -> `String body

(* Surface refresh — invalidate ALL execution: dashboard caches so a pause /
   resume action reflects on every parameterized view (actor / fixture / full
   mode) immediately instead of waiting on TTL.

   Plan 가설 D: 이전 구현은 "execution:default:light" 단일 키만 무효화하여
   server_dashboard_http_execution_surfaces.ml:940-941 의
   "execution:{actor}:{fixture}:{light|full}" parameterized 키는
   deep_surface_cache_ttl_s 동안 stale 유지 → 대시보드가 최신 pause/resume
   상태를 늦게 반영.

   Similarly, dashboard_shell_cache_prefix 로 묶이는 per-keeper shell surface
   cache (60s TTL) 도 별도 무효화한다.

   - Light cache + parameterized keys: [Dashboard_cache.invalidate_prefix "execution:"]
   - Per-keeper shell surface: [dashboard_shell_cache_prefix config]
   - Global execution surface object: [patch_keeper_dependent_caches] (covers
     [execution_cache] typed-surface invalidation)
   - Operator control snapshot cache: [Operator_control_snapshot.invalidate_snapshot_cache]
   - Projection cache: [Dashboard_projection_cache.invalidate_snapshot_json] *)
let refresh_keeper_execution_surfaces ~config ~name event =
  Operator_control_snapshot.invalidate_snapshot_cache ();
  Dashboard_projection_cache.invalidate_snapshot_json ~config;
  (try Dashboard_cache.invalidate_prefix "execution:" with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
       Log.Dashboard.warn
         "keeper %s %s: execution dashboard cache invalidate failed: %s"
         name event (Printexc.to_string exn));
  (try
     Dashboard_cache.invalidate_prefix
       (Server_dashboard_http_core.dashboard_shell_cache_prefix config)
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
       Log.Dashboard.warn
         "keeper %s %s: shell surface cache invalidate failed: %s"
         name event (Printexc.to_string exn));
  Server_dashboard_http_execution_surfaces.patch_keeper_dependent_caches
    ~keeper_name:name ~event

(* Wakeup / invalidate path — same cache-surface coverage as
   [refresh_keeper_execution_surfaces]. Wakeup doesn't go through the directive
   lifecycle, but the dashboard must still drop parameterized + shell-surface
   entries so the wakeup reflects on every view. *)
let invalidate_keeper_execution_surfaces ~config () =
  Operator_control_snapshot.invalidate_snapshot_cache ();
  Dashboard_projection_cache.invalidate_snapshot_json ~config;
  (try Dashboard_cache.invalidate_prefix "execution:" with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
       Log.Dashboard.warn
         "keeper wakeup: execution dashboard cache invalidate failed: %s"
         (Printexc.to_string exn));
  (try
     Dashboard_cache.invalidate_prefix
       (Server_dashboard_http_core.dashboard_shell_cache_prefix config)
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
       Log.Dashboard.warn
         "keeper wakeup: shell surface cache invalidate failed: %s"
         (Printexc.to_string exn));
  Server_dashboard_http_execution_surfaces.invalidate_execution_cache ()

(* Typed outcome of a keeper lifecycle action, so the log severity is chosen by
   an exhaustive match rather than a string-parsing wildcard with a permissive
   default (#8605). [Succeeded]/[Already_live] are successes (Info);
   [Rejected] (400) and [Dispatch_none] (500) are failures (Warn) — see
   docs/spec/18-log-severity-taxonomy.md § 3.6. *)
type lifecycle_outcome =
  | Succeeded
  | Already_live
  | Rejected
  | Dispatch_none
  | Persist_failed

let handle_keeper_lifecycle_post ?body_str ~sw ~clock ~tool_name ~action
    state agent_name req reqd =
  let req_path = Http.Request.path req in
  let suffix_result =
    match action with
    | "boot" -> Ok keeper_suffix_boot
    | "shutdown" -> Ok keeper_suffix_shutdown
    | "reset" -> Ok keeper_suffix_reset
    | "clear" -> Ok keeper_suffix_clear
    | unknown ->
        Error (Printf.sprintf "unknown keeper lifecycle action: %s" unknown)
  in
  match suffix_result with
  | Error msg ->
      respond_error reqd msg
  | Ok suffix ->
  let name = extract_keeper_name_for_post req_path suffix in
  if String.length name = 0 then
    respond_error reqd "keeper name is required"
  else
    let workspace_scope = Mcp_server.workspace_scope state in
    let config = workspace_scope.config in
    let resolve_keeper_agent_name () =
      match Keeper_registry_lookup.find_by_name name with
      | Some entry -> Some entry.meta.agent_name
      | None -> (
          match Keeper_meta_store.read_meta config name with
          | Ok (Some meta) -> Some meta.agent_name
          | Ok None -> None
          | Error err ->
              Log.Keeper.warn
                "resolve_keeper_agent_name %s: read_meta failed: %s"
                name err;
              None)
    in
    let persist_keeper_paused_state paused =
      match Keeper_meta_store.read_meta config name with
      | Ok (Some meta) when Bool.equal meta.paused paused -> true
      | Ok (Some meta) ->
           let updated_meta =
             (* Resume ([paused = false]) routes through [mark_resumed] so the
                boot-resume writer clears the typed latch together with the
                pause bit — it must never persist paused=false + Dead_tombstone
                (rejected by the meta store). Pause keeps the latch paired. *)
             let base =
               if paused then { meta with paused = true }
               else Keeper_meta_contract.mark_resumed meta
             in
             { base with updated_at = Keeper_meta_contract.now_iso () }
           in
           (match
              Keeper_meta_store.write_meta_with_merge
                ~merge:Keeper_meta_merge.caller_wins config updated_meta
            with
            | Ok () -> true
            | Error err ->
              Log.Keeper.warn
                "keeper %s %s: write_meta failed: %s"
                name
                (if paused then "pause" else "resume")
                err;
              false)
      (* Issue #8391 HIGH #1: split [Ok None] (meta vanished) from
         [Error _] (IO/parse failure) so silent failures become visible.
         The boot HTTP contract is unchanged — explicit resume persistence is
         a best-effort side effect of [boot], not the primary action. *)
      | Ok None ->
          Log.Keeper.warn
            "keeper %s %s: meta missing — skipping paused-state persist"
            name
            (if paused then "pause" else "resume");
          Otel_metric_store.inc_counter
            Keeper_metrics.(to_string PausedStatePersistErrors)
            ~labels:[("phase", Keeper_paused_state_persist_phase.(to_label Boot_resume_persist));
                     ("reason", "meta_missing")]
            ();
          false
      | Error err ->
          Log.Keeper.error
            "keeper %s %s: read_meta failed: %s"
            name
            (if paused then "pause" else "resume")
            err;
          Otel_metric_store.inc_counter
            Keeper_metrics.(to_string PausedStatePersistErrors)
            ~labels:[("phase", Keeper_paused_state_persist_phase.(to_label Boot_resume_persist));
                     ("reason", "read_meta_error")]
            ();
          false
    in
    let resume_booted_keeper_if_needed () =
      match Keeper_meta_store.read_meta config name with
      | Ok (Some meta) when meta.paused ->
          if persist_keeper_paused_state false
          then (
            match resolve_keeper_agent_name () with
            | Some keeper_agent_name ->
              Keeper_keepalive.process_directive
                ~agent_name:keeper_agent_name
                Keeper_directive.Resume
            | None ->
              Log.Keeper.warn
                "keeper boot: agent_name not found for paused keeper %s"
                name)
      | Ok (Some _) -> ()
      (* Issue #8391 HIGH #1: split [Ok None] from [Error _] — boot itself
         already succeeded via Keeper_tool_surface.dispatch, so we don't change the
         HTTP status. We make the failure observable instead. *)
      | Ok None ->
          Log.Keeper.warn
            "keeper %s boot: meta missing — skipping resume check"
            name;
          Otel_metric_store.inc_counter
            Keeper_metrics.(to_string PausedStatePersistErrors)
            ~labels:[("phase", Keeper_paused_state_persist_phase.(to_label Boot_resume_check));
                     ("reason", "meta_missing")]
            ()
      | Error err ->
          Log.Keeper.error
            "keeper %s boot: read_meta failed during resume check: %s"
            name
            err;
          Otel_metric_store.inc_counter
            Keeper_metrics.(to_string PausedStatePersistErrors)
            ~labels:[("phase", Keeper_paused_state_persist_phase.(to_label Boot_resume_check));
                     ("reason", "read_meta_error")]
            ()
    in
    let keeper_ctx : _ Keeper_tool_surface.context =
      {
        config;
        agent_name;
        sw;
        clock;
        proc_mgr = state.Mcp_server.proc_mgr;
        net = state.Mcp_server.net;
        publication_recovery_registry = (Mcp_server.workspace_scope_publication_recovery_registry workspace_scope);
      }
    in
    let args_result =
      match action with
      | "clear" -> (
          match body_str with
          | None ->
              Error "request body is required for clear"
          | Some raw -> (
              try
                let parsed = Yojson.Safe.from_string raw in
                match parsed with
                | `Assoc fields ->
                    Ok (`Assoc (("name", `String name) :: List.remove_assoc "name" fields))
                | _ ->
                    Error "request body must be a JSON object"
              with
              | Yojson.Json_error err ->
                  Error (Printf.sprintf "invalid json: %s" err)))
      | _ -> Ok (`Assoc [("name", `String name)])
    in
    match args_result with
    | Error msg ->
        respond_error ~ok:false reqd msg
    | Ok args ->
        let started_at = Eio.Time.now clock in
        let duration_ms () =
          (Eio.Time.now clock -. started_at) *. 1000.0 |> int_of_float
        in
        let log_lifecycle_result (outcome : lifecycle_outcome) =
          (* docs/spec/18-log-severity-taxonomy.md § 3.6: the line carries the
             outcome, so the severity is derived from it (single emission)
             instead of a static [Info] — otherwise a rejected/failed lifecycle
             action hides under the noise floor. Failures are
             degraded-with-recovery (the client gets an error response, the
             server keeps serving) → [Warn]. *)
          let level, outcome_s =
            match outcome with
            | Succeeded -> (Log.Info, "ok")
            | Already_live -> (Log.Info, "already_live")
            | Rejected -> (Log.Warn, "rejected")
            | Dispatch_none -> (Log.Warn, "dispatch_none")
            | Persist_failed -> (Log.Warn, "persist_failed")
          in
          Log.Server.emit level
            (Printf.sprintf
               "keeper lifecycle %s name=%s actor=%s outcome=%s duration_ms=%d"
               action name agent_name outcome_s (duration_ms ()))
        in
        Log.Server.info "keeper lifecycle %s name=%s actor=%s started"
          action name agent_name;
        let live_boot_entry =
          match Keeper_registry.get ~base_path:config.base_path name with
          | Some entry
            when String.equal action "boot"
                 && entry.conditions.fiber_alive
                 && not entry.conditions.stop_requested
                 && (entry.phase = Keeper_state_machine.Running
                     || entry.phase = Keeper_state_machine.Paused) ->
            Some entry
          | Some _ | None -> None
        in
        (match live_boot_entry with
         | Some entry ->
           (* Dashboard boot is an idempotent lifecycle action.  If a keeper
              is already live, do not send it through masc_keeper_up's update
              path: that path intentionally stop/starts changed keepers, and
              doing so during an active turn creates duplicate fibers and
              contradictory stopped/executing surfaces.  Resume and wake the
              existing fiber instead. *)
           resume_booted_keeper_if_needed ();
           Keeper_keepalive.process_directive
             ~agent_name:entry.meta.agent_name
             Keeper_directive.Wakeup;
           refresh_keeper_execution_surfaces ~config ~name "started";
           let detail =
             match Keeper_registry.get ~base_path:config.base_path name with
             | Some latest -> Keeper_meta_json.meta_to_json latest.meta
             | None -> Keeper_meta_json.meta_to_json entry.meta
           in
           log_lifecycle_result Already_live;
           Http.Response.json_value ~compress:true ~request:req
             (`Assoc
                [
                  ("ok", `Bool true);
                  ("action", `String action);
                  ("name", `String name);
                  ("already_live", `Bool true);
                  ("detail", detail);
                ])
             reqd
         | None ->
           (match Keeper_tool_surface.dispatch keeper_ctx ~name:tool_name ~args with
            | Some result
              when Tool_result.is_success result
                   && (String.equal action "boot" || String.equal action "clear") ->
              let body = Tool_result.message result in
              let post_action_result =
                if String.equal action "boot"
                then (
                  resume_booted_keeper_if_needed ();
                  refresh_keeper_execution_surfaces ~config ~name "started";
                  Ok ())
                else (
                  match Keeper_registry.get_phase ~base_path:config.base_path name with
                  | Some Keeper_state_machine.Paused
                    when not (persist_keeper_paused_state true) ->
                    Error "paused-state persist failed after clear"
                  | Some Keeper_state_machine.Paused | Some _ | None ->
                    invalidate_keeper_execution_surfaces ~config ();
                    Ok ())
              in
              (match post_action_result with
               | Error msg ->
                 log_lifecycle_result Persist_failed;
                 respond_error
                   ~status:`Internal_server_error
                   ~request:req
                   ~ok:false
                   reqd
                   msg
               | Ok () ->
                 log_lifecycle_result Succeeded;
                 Http.Response.json_value ~compress:true ~request:req
                   (`Assoc
                      [
                        ("ok", `Bool true);
                        ("action", `String action);
                        ("name", `String name);
                        ("detail", tool_detail_json body);
                      ])
                   reqd)
            | Some result when Tool_result.is_success result ->
              let post_action_result =
                match action with
                | "shutdown" ->
                  if persist_keeper_paused_state true
                  then (
                    refresh_keeper_execution_surfaces ~config ~name "stopped";
                    Ok ())
                  else Error "paused-state persist failed after shutdown"
                | _ ->
                  invalidate_keeper_execution_surfaces ~config ();
                  Ok ()
              in
              (match post_action_result with
               | Error msg ->
                 log_lifecycle_result Persist_failed;
                 respond_error
                   ~status:`Internal_server_error
                   ~request:req
                   ~ok:false
                   reqd
                   msg
               | Ok () ->
                 log_lifecycle_result Succeeded;
                 Http.Response.json_value ~compress:true ~request:req
                   (`Assoc
                      [
                        ("ok", `Bool true);
                        ("action", `String action);
                        ("name", `String name);
                      ])
                   reqd)
            | Some result ->
              let body = Tool_result.message result in
              log_lifecycle_result Rejected;
              Http.Response.json_value ~status:`Bad_request ~request:req
                (`Assoc [("ok", `Bool false); ("error", `String body)])
                reqd
            | None ->
              log_lifecycle_result Dispatch_none;
              respond_error ~status:`Internal_server_error ~request:req ~ok:false
                reqd "dispatch returned None"))

(** POST /api/v1/keepers/:name/directive — pause / resume / wakeup.

    Delegates to [Keeper_keepalive.process_directive] which updates
    registry state, dispatches a state-machine event, and optionally
    wakes up the keeper fiber. *)
