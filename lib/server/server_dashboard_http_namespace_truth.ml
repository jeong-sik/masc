(** Namespace-truth read model and SSE snapshot broadcasting. *)

open Server_dashboard_http_core

module Execution_surfaces = Server_dashboard_http_execution_surfaces
module Namespace_truth_support = Server_dashboard_http_namespace_truth_support

let float_of_env_default_with_legacy ~canonical ~legacy ~default ~min_v ~max_v =
  match Sys.getenv_opt canonical with
  | Some _ -> float_of_env_default canonical ~default ~min_v ~max_v
  | None -> float_of_env_default legacy ~default ~min_v ~max_v

let dashboard_namespace_truth_http_json ~state ~sw:_ ~clock _request =
  (* Fast-path: if the proactive execution refresh hasn't produced a result
     yet, return "initializing" immediately instead of blocking for 15-20s
     on cold-start on-demand compute. The frontend retries every 3s via
     scheduleWarmRetry; the proactive refresh loop populates _execution_cache
     in background. *)
  let warm_escape_s =
    float_of_env_default "MASC_DASHBOARD_EXECUTION_REFRESH_TIMEOUT_S"
      ~default:75.0 ~min_v:30.0 ~max_v:300.0
    +. 15.0
  in
  let proactive_first_cycle_pending =
    not (cached_surface_has_success Execution_surfaces._execution_cache)
    &&
    match Execution_surfaces._execution_cache.last_attempt_unix with
    | None -> true
    | Some attempt_ts ->
        let elapsed = Time_compat.now () -. attempt_ts in
        elapsed < warm_escape_s
        && Option.is_none Execution_surfaces._execution_cache.last_error_unix
  in
  if proactive_first_cycle_pending then
    `Assoc
      [
        ("status", `String "initializing");
        ("generated_at", `String (Types.now_iso ()));
        ( "message",
          `String
            "Execution snapshot is still warming up. The dashboard will retry automatically."
        );
      ]
  else
    with_dashboard_timeout ~clock (fun () ->
        let config = state.Mcp_server.room_config in
        let started_at = Unix.gettimeofday () in
        let t0 = Time_compat.now () in
        (* Staged fetch: shell may still need a guarded refresh, while execution
           stays on the proactive cache to keep namespace-truth off the cold path. *)
        let shell_ref = ref (`Assoc []) in
        let execution_ref = ref (`Assoc []) in
        let command_ref = ref (`Assoc []) in
        (* Single env var for namespace-truth fiber timeouts.
           Cold start uses higher defaults to allow shell/namespace reads to warm up. *)
        let warm_timeout_s =
          float_of_env_default_with_legacy
            ~canonical:"MASC_DASHBOARD_NAMESPACE_TRUTH_TIMEOUT_S"
            ~legacy:"MASC_DASHBOARD_ROOM_TRUTH_TIMEOUT_S"
            ~default:5.0 ~min_v:2.0 ~max_v:25.0
        in
        let cold_timeout_s =
          float_of_env_default_with_legacy
            ~canonical:"MASC_DASHBOARD_NAMESPACE_TRUTH_COLD_TIMEOUT_S"
            ~legacy:"MASC_DASHBOARD_ROOM_TRUTH_COLD_TIMEOUT_S"
            ~default:15.0 ~min_v:5.0 ~max_v:60.0
        in
        let is_cold =
          not (cached_surface_has_success Execution_surfaces._execution_cache)
        in
        let base_timeout_s = if is_cold then cold_timeout_s else warm_timeout_s in
        let fiber_with_timeout ?(timeout_s = base_timeout_s) label f fallback =
          try
            match Eio.Time.with_timeout clock timeout_s (fun () -> Ok (f ())) with
            | Ok v -> v
            | Error `Timeout ->
                Log.Dashboard.warn "namespace-truth fiber %s timed out (%.0fs)" label
                  timeout_s;
                fallback
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn ->
              Log.Dashboard.warn "namespace-truth fiber %s failed: %s" label
                (Printexc.to_string exn);
              fallback
        in
        let shell_timeout_s =
          if !(Execution_surfaces._shell_warmed) then base_timeout_s
          else cold_timeout_s
        in
        (* Sequential fetch to avoid PG connection concurrent usage (#3305). *)
        shell_ref :=
          fiber_with_timeout ~timeout_s:shell_timeout_s "shell"
            (fun () -> dashboard_shell_http_json ~clock config)
            (`Assoc []);
        execution_ref := cached_surface_json Execution_surfaces._execution_cache;
        (* command_plane_summary_http_json reads from a proactive cache ref. *)
        command_ref :=
          Server_command_plane_http.command_plane_summary_http_json ~state;
        let shell_json = !shell_ref in
        if (not !(Execution_surfaces._shell_warmed)) && shell_json <> `Assoc [] then
          Execution_surfaces._shell_warmed := true;
        let execution_json = !execution_ref in
        let command_summary_json = !command_ref in
        let parallel_ms = (Time_compat.now () -. t0) *. 1000.0 in
        if parallel_ms >= 100.0 then
          Log.Dashboard.info "namespace-truth fetch: %.0fms" parallel_ms
        else
          Log.Dashboard.debug "namespace-truth fetch: %.0fms" parallel_ms;
        let execution_cache_state =
          json_assoc_field "projection_diagnostics" execution_json
          |> json_string_field_opt "cache_state"
        in
        Namespace_truth_support.compose_namespace_truth_snapshot ~config
          ~initialized:(Room.is_initialized config) ~shell_json ~execution_json
          ~command_summary_json
        |> with_projection_diagnostics ~surface:"namespace_truth" ~started_at
             ~extra:
               [
                 ("parallel_ms", `Int (int_of_float parallel_ms));
                 ( "execution_cache_state",
                   match execution_cache_state with
                   | Some value -> `String value
                   | None -> `Null );
               ])

(** Assemble a lightweight namespace-truth snapshot from cached refs only.
    No PG I/O — reads proactive caches for execution and command, and
    the TTL-cached shell. Returns None when the execution cache has not
    produced its first successful result (cold start). *)
let namespace_truth_snapshot_from_caches (state : Mcp_server.server_state) :
    Yojson.Safe.t option =
  if not (cached_surface_has_success Execution_surfaces._execution_cache) then
    None
  else
    let config = state.Mcp_server.room_config in
    let shell_json =
      if !(Execution_surfaces._shell_warmed) then
        try dashboard_shell_http_json ?clock:state.Mcp_server.clock config
        with Eio.Cancel.Cancelled _ as e -> raise e | _ -> `Assoc []
      else `Assoc []
    in
    let execution_json = cached_surface_json Execution_surfaces._execution_cache in
    let command_summary_json =
      Server_command_plane_http.command_plane_summary_http_json ~state
    in
    Some
      (Namespace_truth_support.compose_namespace_truth_snapshot ~config
         ~initialized:(Room.is_initialized config) ~shell_json ~execution_json
         ~command_summary_json)

(** Broadcast current namespace-truth snapshot to all Observer SSE sessions.
    Called after proactive cache refreshes and keeper lifecycle events.
    Safe to call from any fiber — reads only from cached refs. *)
let broadcast_namespace_truth_snapshot (state : Mcp_server.server_state) : unit =
  match namespace_truth_snapshot_from_caches state with
  | None -> ()
  | Some snapshot ->
      let namespace_sse_json =
        `Assoc
          [
            ("type", `String "namespace_truth_snapshot");
            ("payload", snapshot);
            ("ts_unix", `Float (Time_compat.now ()));
          ]
      in
      let legacy_sse_json =
        `Assoc
          [
            ("type", `String "room_truth_snapshot");
            ("payload", snapshot);
            ("ts_unix", `Float (Time_compat.now ()));
          ]
      in
      Sse.broadcast_to Observers namespace_sse_json;
      Sse.broadcast_to Observers legacy_sse_json;
      ignore
        (Server_meta_cognition_feedback.maybe_post_digest
           ~config:state.Mcp_server.room_config snapshot);
      Log.Dashboard.info "namespace-truth snapshot pushed via SSE"

let () =
  Execution_surfaces._broadcast_namespace_truth_ref :=
    broadcast_namespace_truth_snapshot
