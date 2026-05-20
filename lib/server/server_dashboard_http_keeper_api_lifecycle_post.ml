(** Lifecycle POST handler (boot/shutdown/reset/clear) for keeper dashboard API,
    plus execution-surface cache helpers used by lifecycle + directive handlers. *)

open Server_dashboard_http_keeper_api_types

module Http = Http_server_eio

let refresh_keeper_execution_surfaces ~config ~name event =
  Operator_control_snapshot.invalidate_snapshot_cache ();
  Dashboard_projection_cache.invalidate_snapshot_json ~config;
  (try Dashboard_cache.invalidate "execution:default:light" with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
       Log.Dashboard.warn
         "keeper %s %s: execution dashboard cache invalidate failed: %s"
         name event (Printexc.to_string exn));
  Server_dashboard_http_execution_surfaces.patch_keeper_dependent_caches
    ~keeper_name:name ~event

let invalidate_keeper_execution_surfaces ~config () =
  Operator_control_snapshot.invalidate_snapshot_cache ();
  Dashboard_projection_cache.invalidate_snapshot_json ~config;
  Server_dashboard_http_execution_surfaces.invalidate_execution_cache ()

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
      Http.Response.json ~status:`Bad_request
        (Printf.sprintf {|{"error":"%s"}|} (String.escaped msg)) reqd
  | Ok suffix ->
  let name = extract_keeper_name_for_post req_path suffix in
  if String.length name = 0 then
    Http.Response.json ~status:`Bad_request
      {|{"error":"keeper name is required"}|} reqd
  else
    let config = state.Mcp_server.room_config in
    let resolve_keeper_agent_name () =
      match Keeper_registry_lookup.find_by_name name with
      | Some entry -> Some entry.meta.agent_name
      | None -> (
          match Keeper_types.read_meta config name with
          | Ok (Some meta) -> Some meta.agent_name
          | Ok None -> None
          | Error err ->
              Log.Keeper.warn
                "resolve_keeper_agent_name %s: read_meta failed: %s"
                name err;
              None)
    in
    let persist_keeper_paused_state paused =
      match Keeper_types.read_meta config name with
      | Ok (Some meta) when Bool.equal meta.paused paused -> ()
      | Ok (Some meta) ->
          let updated_meta =
            {
              meta with
              paused;
              updated_at = Keeper_types.now_iso ();
            }
          in
          (match Keeper_types.write_meta_with_retry config updated_meta with
           | Ok () -> ()
           | Error err ->
               Log.Keeper.warn
                 "keeper %s %s: write_meta failed: %s"
                 name
                 (if paused then "pause" else "resume")
                 err)
      (* Issue #8391 HIGH #1: split [Ok None] (meta vanished) from
         [Error _] (IO/parse failure) so silent failures become visible.
         The boot HTTP contract is unchanged — auto-resume cleanup is a
         best-effort side effect of [boot], not the primary action. *)
      | Ok None ->
          Log.Keeper.warn
            "keeper %s %s: meta missing — skipping paused-state persist"
            name
            (if paused then "pause" else "resume");
          Prometheus.inc_counter
            Keeper_metrics.metric_keeper_paused_state_persist_errors
            ~labels:[("phase", Keeper_paused_state_persist_phase.(to_label Boot_resume_persist));
                     ("reason", "meta_missing")]
            ()
      | Error err ->
          Log.Keeper.error
            "keeper %s %s: read_meta failed: %s"
            name
            (if paused then "pause" else "resume")
            err;
          Prometheus.inc_counter
            Keeper_metrics.metric_keeper_paused_state_persist_errors
            ~labels:[("phase", Keeper_paused_state_persist_phase.(to_label Boot_resume_persist));
                     ("reason", "read_meta_error")]
            ()
    in
    let resume_booted_keeper_if_needed () =
      match Keeper_types.read_meta config name with
      | Ok (Some meta) when meta.paused ->
          persist_keeper_paused_state false;
          (match resolve_keeper_agent_name () with
           | Some keeper_agent_name ->
               Keeper_keepalive.process_directive
                 ~agent_name:keeper_agent_name
                 "resume"
           | None ->
               Log.Keeper.warn
                 "keeper boot: agent_name not found for paused keeper %s"
                 name)
      | Ok (Some _) -> ()
      (* Issue #8391 HIGH #1: split [Ok None] from [Error _] — boot itself
         already succeeded via Tool_keeper.dispatch, so we don't change the
         HTTP status. We make the failure observable instead. *)
      | Ok None ->
          Log.Keeper.warn
            "keeper %s boot: meta missing — skipping auto-resume check"
            name;
          Prometheus.inc_counter
            Keeper_metrics.metric_keeper_paused_state_persist_errors
            ~labels:[("phase", Keeper_paused_state_persist_phase.(to_label Boot_resume_check));
                     ("reason", "meta_missing")]
            ()
      | Error err ->
          Log.Keeper.error
            "keeper %s boot: read_meta failed during auto-resume check: %s"
            name
            err;
          Prometheus.inc_counter
            Keeper_metrics.metric_keeper_paused_state_persist_errors
            ~labels:[("phase", Keeper_paused_state_persist_phase.(to_label Boot_resume_check));
                     ("reason", "read_meta_error")]
            ()
    in
    let keeper_ctx : _ Tool_keeper.context =
      {
        config;
        agent_name;
        sw;
        clock;
        proc_mgr = state.Mcp_server.proc_mgr;
        net = state.Mcp_server.net;
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
        Http.Response.json ~status:`Bad_request
          (Printf.sprintf {|{"ok":false,"error":"%s"}|} (String.escaped msg))
          reqd
    | Ok args ->
        let started_at = Eio.Time.now clock in
        let duration_ms () =
          (Eio.Time.now clock -. started_at) *. 1000.0 |> int_of_float
        in
        let log_lifecycle_result outcome =
          Log.Server.info
            "keeper lifecycle %s name=%s actor=%s outcome=%s duration_ms=%d"
            action name agent_name outcome (duration_ms ())
        in
        Log.Server.info "keeper lifecycle %s name=%s actor=%s started"
          action name agent_name;
        let live_boot_entry =
          if String.equal action "boot"
          then (
            match Keeper_registry.get ~base_path:config.base_path name with
            | Some entry
              when entry.conditions.fiber_alive
                   && not entry.conditions.stop_requested ->
              Some entry
            | Some _ | None -> None)
          else None
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
             "wakeup";
           refresh_keeper_execution_surfaces ~config ~name "started";
           let detail =
             match Keeper_registry.get ~base_path:config.base_path name with
             | Some latest -> Keeper_types.meta_to_json latest.meta
             | None -> Keeper_types.meta_to_json entry.meta
           in
           log_lifecycle_result "already_live";
           Http.Response.json ~compress:true ~request:req
             (Printf.sprintf
                {|{"ok":true,"action":"%s","name":"%s","already_live":true,"detail":%s}|}
                (String.escaped action)
                (String.escaped name)
                (Yojson.Safe.to_string detail))
             reqd
         | None ->
           (match Tool_keeper.dispatch keeper_ctx ~name:tool_name ~args with
            | Some (true, body)
              when String.equal action "boot" || String.equal action "clear" ->
              if String.equal action "boot"
              then (
                resume_booted_keeper_if_needed ();
                refresh_keeper_execution_surfaces ~config ~name "started")
              else (
                (match Keeper_registry.get_phase ~base_path:config.base_path name with
                 | Some Keeper_state_machine.Paused -> persist_keeper_paused_state true
                 | Some _ | None -> ());
                invalidate_keeper_execution_surfaces ~config ());
              log_lifecycle_result "ok";
              Http.Response.json ~compress:true ~request:req
                (Printf.sprintf
                   {|{"ok":true,"action":"%s","name":"%s","detail":%s}|}
                   (String.escaped action)
                   (String.escaped name)
                   body)
                reqd
            | Some (true, _body) ->
              (match action with
               | "shutdown" ->
                 persist_keeper_paused_state true;
                 refresh_keeper_execution_surfaces ~config ~name "stopped"
               | _ -> invalidate_keeper_execution_surfaces ~config ());
              log_lifecycle_result "ok";
              Http.Response.json ~compress:true ~request:req
                (Printf.sprintf {|{"ok":true,"action":"%s","name":"%s"}|}
                   (String.escaped action)
                   (String.escaped name))
                reqd
            | Some (false, body) ->
              log_lifecycle_result "rejected";
              Http.Response.json ~status:`Bad_request ~request:req
                (Yojson.Safe.to_string
                   (`Assoc [("ok", `Bool false); ("error", `String body)]))
                reqd
            | None ->
              log_lifecycle_result "dispatch_none";
              Http.Response.json ~status:`Internal_server_error ~request:req
                {|{"ok":false,"error":"dispatch returned None"}|}
                reqd))

(** POST /api/v1/keepers/:name/directive — pause / resume / wakeup.

    Delegates to [Keeper_keepalive.process_directive] which updates
    registry state, dispatches a state-machine event, and optionally
    wakes up the keeper fiber. *)
