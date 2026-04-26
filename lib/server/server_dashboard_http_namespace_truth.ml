(** Namespace-truth read model and SSE snapshot broadcasting. *)

open Server_dashboard_http_core
module Execution_surfaces = Server_dashboard_http_execution_surfaces
module Namespace_truth_support = Server_dashboard_http_namespace_truth_support

let float_of_env_default_with_legacy ~canonical ~legacy ~default ~min_v ~max_v =
  match Sys.getenv_opt canonical with
  | Some _ -> float_of_env_default canonical ~default ~min_v ~max_v
  | None -> float_of_env_default legacy ~default ~min_v ~max_v
;;

let dashboard_namespace_truth_http_json ~state ~sw:_ ~clock _request =
  (* Fast-path: if the proactive execution refresh hasn't produced a result
     yet, return "initializing" immediately instead of blocking for 15-20s
     on cold-start on-demand compute. The frontend retries every 3s via
     scheduleWarmRetry; the proactive refresh loop populates _execution_cache
     in background. *)
  let warm_escape_s =
    float_of_env_default
      "MASC_DASHBOARD_EXECUTION_REFRESH_TIMEOUT_S"
      ~default:75.0
      ~min_v:30.0
      ~max_v:300.0
    +. 15.0
  in
  let proactive_first_cycle_pending =
    (not (cached_surface_has_success Execution_surfaces._execution_cache))
    &&
    match Execution_surfaces._execution_cache.last_attempt_unix with
    | None -> true
    | Some attempt_ts ->
      let elapsed = Time_compat.now () -. attempt_ts in
      elapsed < warm_escape_s
      && Option.is_none Execution_surfaces._execution_cache.last_error_unix
  in
  if proactive_first_cycle_pending
  then
    `Assoc
      [ "status", `String "initializing"
      ; "generated_at", `String (Types.now_iso ())
      ; ( "message"
        , `String
            "Execution snapshot is still warming up. The dashboard will retry \
             automatically." )
      ]
  else
    with_dashboard_timeout ~clock (fun () ->
      let config = state.Mcp_server.room_config in
      let started_at = Unix.gettimeofday () in
      let t0 = Time_compat.now () in
      (* Staged fetch: shell may still need a guarded refresh, while execution
           stays on the proactive cache to keep project-snapshot off the cold path. *)
      let shell_ref = ref (`Assoc []) in
      let execution_ref = ref (`Assoc []) in
      let command_ref = ref (`Assoc []) in
      (* Namespace-truth fiber timeouts.  Cold start uses higher defaults to
           allow shell/namespace reads to warm up.  Tunable via env for fleets
           whose observed fetch latency drifts above the literal defaults (see
           #7908 — fleet p50 ≈ 17s made the 12s shell cap misfire). *)
      let warm_timeout_s =
        float_of_env_default
          "MASC_NAMESPACE_TRUTH_WARM_TIMEOUT_S"
          ~default:8.0
          ~min_v:1.0
          ~max_v:120.0
      in
      let cold_timeout_s =
        float_of_env_default
          "MASC_NAMESPACE_TRUTH_COLD_TIMEOUT_S"
          ~default:15.0
          ~min_v:1.0
          ~max_v:120.0
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
            Log.Dashboard.warn
              "project-snapshot fiber %s timed out (%.0fs)"
              label
              timeout_s;
            fallback
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Log.Dashboard.warn
            "project-snapshot fiber %s failed: %s"
            label
            (Printexc.to_string exn);
          fallback
      in
      (* Shell fiber timeout: must exceed inner cache timeout
           (dashboard_shell_timeout_s, default 8s) to avoid the double-timeout
           race where the inner cache returns timeout-error JSON while the outer
           fiber also fires, discarding even stale data.  Fixes #5090. *)
      let shell_fiber_timeout_s =
        float_of_env_default
          "MASC_NAMESPACE_TRUTH_SHELL_FIBER_TIMEOUT_S"
          ~default:12.0
          ~min_v:1.0
          ~max_v:120.0
      in
      let cold_safety_margin_s =
        float_of_env_default
          "MASC_NAMESPACE_TRUTH_COLD_SAFETY_MARGIN_S"
          ~default:4.0
          ~min_v:0.0
          ~max_v:60.0
      in
      let shell_timeout_s =
        if Atomic.get _shell_warmed
        then shell_fiber_timeout_s
        else Float.max cold_timeout_s (shell_fiber_timeout_s +. cold_safety_margin_s)
      in
      (* Graceful degradation: on timeout fall back to the last successful
           shell result rather than empty JSON, which would zero out namespace
           counts and focus data (61x/day under I/O contention). *)
      let shell_fallback = Atomic.get _last_good_shell in
      (* Sequential fetch to avoid PG connection concurrent usage (#3305). *)
      shell_ref
      := fiber_with_timeout
           ~timeout_s:shell_timeout_s
           "shell"
           (fun () -> dashboard_shell_http_json ~clock config)
           shell_fallback;
      execution_ref := cached_surface_json Execution_surfaces._execution_cache;
      command_ref := `Assoc [];
      let shell_json = !shell_ref in
      (* Update last-known-good shell on success. *)
      if shell_json <> `Assoc [] && shell_json <> shell_fallback
      then Atomic.set _last_good_shell shell_json;
      if (not (Atomic.get _shell_warmed)) && shell_json <> `Assoc []
      then Atomic.set _shell_warmed true;
      let execution_json = !execution_ref in
      let command_summary_json = !command_ref in
      let parallel_ms = (Time_compat.now () -. t0) *. 1000.0 in
      if parallel_ms >= 100.0
      then Log.Dashboard.info "project-snapshot fetch: %.0fms" parallel_ms
      else Log.Dashboard.debug "project-snapshot fetch: %.0fms" parallel_ms;
      let execution_cache_state =
        json_assoc_field "projection_diagnostics" execution_json
        |> json_string_field_opt "cache_state"
      in
      Namespace_truth_support.compose_namespace_truth_snapshot
        ~config
        ~initialized:(Coord.is_initialized config)
        ~shell_json
        ~execution_json
        ~command_summary_json
      |> with_projection_diagnostics
           ~surface:"namespace_truth"
           ~started_at
           ~extra:
             [ "parallel_ms", `Int (int_of_float parallel_ms)
             ; ( "execution_cache_state"
               , match execution_cache_state with
                 | Some value -> `String value
                 | None -> `Null )
             ])
;;

(** Assemble a lightweight namespace-truth snapshot from cached refs only.
    No PG I/O — reads proactive caches for execution and command, and
    the TTL-cached shell. Returns None when the execution cache has not
    produced its first successful result (cold start). *)
let namespace_truth_snapshot_from_caches (state : Mcp_server.server_state)
  : Yojson.Safe.t option
  =
  if
    not
      (cached_surface_has_success
         Server_dashboard_http_execution_surfaces._execution_cache)
  then None
  else (
    let config = state.Mcp_server.room_config in
    let shell_json =
      if Atomic.get _shell_warmed
      then (
        try
          let result = dashboard_shell_http_json ?clock:state.Mcp_server.clock config in
          Atomic.set _last_good_shell result;
          result
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | _ -> Atomic.get _last_good_shell)
      else Atomic.get _last_good_shell
    in
    let execution_json =
      cached_surface_json Server_dashboard_http_execution_surfaces._execution_cache
    in
    let command_summary_json = `Assoc [] in
    Some
      (Namespace_truth_support.compose_namespace_truth_snapshot
         ~config
         ~initialized:(Coord.is_initialized config)
         ~shell_json
         ~execution_json
         ~command_summary_json))
;;

let _last_namespace_truth_snapshot_hash : Digestif.SHA256.t option ref = ref None
let _namespace_truth_snapshot_hash_mu = Eio.Mutex.create ()

let rec normalize_namespace_truth_snapshot_for_hash (json : Yojson.Safe.t) : Yojson.Safe.t
  =
  match json with
  | `Assoc fields ->
    `Assoc
      (fields
       |> List.filter_map (fun (key, value) ->
         if String.equal key "generated_at"
         then None
         else Some (key, normalize_namespace_truth_snapshot_for_hash value)))
  | `List values -> `List (List.map normalize_namespace_truth_snapshot_for_hash values)
  | other -> other
;;

let should_broadcast_namespace_truth_snapshot (snapshot : Yojson.Safe.t) =
  let serialized =
    snapshot |> normalize_namespace_truth_snapshot_for_hash |> Yojson.Safe.to_string
  in
  let hash = Digestif.SHA256.digest_string serialized in
  Eio.Mutex.use_rw ~protect:true _namespace_truth_snapshot_hash_mu (fun () ->
    match !_last_namespace_truth_snapshot_hash with
    | Some prev when Digestif.SHA256.equal prev hash -> false
    | _ ->
      _last_namespace_truth_snapshot_hash := Some hash;
      true)
;;

(** Broadcast current namespace-truth snapshot to all Observer SSE sessions.
    Called after proactive cache refreshes and keeper lifecycle events.
    Safe to call from any fiber — reads only from cached refs. *)
let broadcast_namespace_truth_snapshot (state : Mcp_server.server_state) : unit =
  match namespace_truth_snapshot_from_caches state with
  | None -> ()
  | Some snapshot when should_broadcast_namespace_truth_snapshot snapshot ->
    let namespace_sse_json =
      `Assoc
        [ "type", `String "project_snapshot"
        ; "payload", snapshot
        ; "ts_unix", `Float (Time_compat.now ())
        ]
    in
    let namespace_alias_sse_json =
      `Assoc
        [ "type", `String "namespace_truth_snapshot"
        ; "payload", snapshot
        ; "ts_unix", `Float (Time_compat.now ())
        ]
    in
    let legacy_sse_json =
      `Assoc
        [ "type", `String "room_truth_snapshot"
        ; "payload", snapshot
        ; "ts_unix", `Float (Time_compat.now ())
        ]
    in
    Sse.broadcast_to Observers namespace_sse_json;
    Sse.broadcast_to Observers namespace_alias_sse_json;
    Sse.broadcast_to Observers legacy_sse_json;
    (* Demote the "pushed via SSE" log to DEBUG when no SSE client is
         connected. With zero observers, the broadcast still runs (for
         the replay buffer and external subscribers) but the log line
         is pure housekeeping noise — once per minute for 96 minutes
         straight in a fresh masc-server.log when nothing is tailing
         /project-snapshot. Operators only care about this signal when
         there is an actual client on the wire. *)
    let log_fn =
      if Sse.client_count () > 0 then Log.Dashboard.info else Log.Dashboard.debug
    in
    log_fn "project-snapshot pushed via SSE"
  | Some _ -> Log.Dashboard.debug "project-snapshot unchanged, skipping SSE broadcast"
;;

let () =
  Execution_surfaces._broadcast_namespace_truth_ref := broadcast_namespace_truth_snapshot
;;
