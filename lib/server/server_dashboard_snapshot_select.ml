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
      Server_timing.measure
        timing_obj
        (Server_timing.Custom "snapshot_read")
        (fun () -> snap.shell)
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
    Server_timing.measure
      timing_obj
      Server_timing.Project_snapshot_runtime
      (fun () ->
        Server_dashboard_http_namespace_truth
          .dashboard_namespace_truth_http_json
          ~state ~sw ~clock req)
;;
