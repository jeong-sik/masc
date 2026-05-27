(** See [server_dashboard_snapshot_select.mli] for the contract. *)

let select_shell_json
      ?clock ?request ?timing ?(light = false) (config : Coord.config)
  : Yojson.Safe.t
  =
  let timing_obj =
    match timing with
    | Some t -> t
    | None -> Server_timing.create ()
  in
  if light
  then
    Server_dashboard_http_core.dashboard_shell_http_json
      ?clock ?request ~timing:timing_obj ~light config
  else (
    match Dashboard_snapshot.current () with
    | Some snap ->
      let shell =
        Server_timing.measure
          timing_obj
          (Server_timing.Custom "snapshot_read")
          (fun () -> snap.shell)
      in
      (match request with
       | None -> shell
       | Some request ->
         Server_dashboard_http_core.dashboard_shell_with_request_auth_json
           ~request config shell)
    | None ->
      Server_dashboard_http_core.dashboard_shell_http_json
        ?clock ?request ~timing:timing_obj ~light config)
;;
let select_tools_json
      ?actor ?timing (config : Coord.config)
  : Yojson.Safe.t
  =
  let timing_obj =
    match timing with
    | Some t -> t
    | None -> Server_timing.create ()
  in
  match actor, Dashboard_snapshot.current () with
  | None, Some snap ->
    Server_timing.measure
      timing_obj
      (Server_timing.Custom "snapshot_read")
      (fun () -> snap.tools)
  | _ ->
    Server_dashboard_http_runtime_info.dashboard_tools_http_json
      ?actor ~timing:timing_obj config
;;

let select_telemetry_summary_json
      ?timing (config : Coord.config)
  : Yojson.Safe.t
  =
  let timing_obj =
    match timing with
    | Some t -> t
    | None -> Server_timing.create ()
  in
  match Dashboard_snapshot.current () with
  | Some snap ->
    Server_timing.measure
      timing_obj
      (Server_timing.Custom "snapshot_read")
      (fun () -> snap.telemetry_summary)
  | None ->
    (* RFC-0138 Phase 3 Step 5 — Dashboard_cache retired from the
       read path.  Cold-start fallback (snapshot=None) computes the
       summary fresh; the refresh fiber takes ownership within ~2s.
       The narrow window without dedup is acceptable for a per-process
       once-only path. *)
    let base_path = config.base_path in
    let masc_root = Coord.masc_root_dir config in
    Server_timing.measure
      timing_obj
      Server_timing.Telemetry_summary_aggregate
      (fun () -> Telemetry_unified.summary_json ~base_path ~masc_root ())
;;

let select_project_snapshot_json ~state ~sw ~clock ?timing req
  : Yojson.Safe.t
  =
  let timing_obj =
    match timing with
    | Some t -> t
    | None -> Server_timing.create ()
  in
  match Dashboard_snapshot.current () with
  | Some snap when snap.namespace_truth <> `Null ->
    Server_timing.measure
      timing_obj
      (Server_timing.Custom "snapshot_read")
      (fun () -> snap.namespace_truth)
  | _ ->
    (* Fallback: [Dashboard_snapshot.refresh_loop] publishes [`Null] for
       [namespace_truth] whenever
       [Server_dashboard_http_namespace_truth.namespace_truth_snapshot_from_caches]
       returns [None] — which is gated on [execution_cache] holding a
       success entry.  On a live fleet that condition flips frequently
       (LRU pressure evicts the entry, refresh tick lands while
       execution_cache is computing, etc.).  Without this cache layer
       every concurrent /dashboard/namespace-truth fiber re-runs the
       full compute on the main HTTP domain — measured at 287-916ms on
       a live build.

       The compute does not consume [req] meaningfully
       ([dashboard_namespace_truth_http_json] takes [_request]), so a
       single [base_path]-keyed cache slot suffices.  TTL 2s matches the
       refresh_loop interval so a stale cache entry is replaced within
       one tick of the snapshot refresh recovering. *)
    let cache_key =
      Printf.sprintf "namespace_truth:fallback:%s"
        state.Mcp_server.room_config.Coord.base_path
    in
    Server_timing.measure
      timing_obj
      Server_timing.Project_snapshot_runtime
      (fun () ->
        Dashboard_cache.get_or_compute cache_key ~ttl:2.0 (fun () ->
          Server_dashboard_http_namespace_truth
            .dashboard_namespace_truth_http_json
            ~state ~sw ~clock req))
;;
