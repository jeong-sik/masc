(** See [server_dashboard_shell_snapshot.mli] for the contract. *)

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

let telemetry_summary_cache_key ~base_path ~masc_root =
  let digest = Digest.string (base_path ^ "\000" ^ masc_root) |> Digest.to_hex in
  "dashboard:telemetry_summary:" ^ digest
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
    let base_path = config.base_path in
    let masc_root = Coord.masc_root_dir config in
    let cache_key = telemetry_summary_cache_key ~base_path ~masc_root in
    Server_timing.measure timing_obj Server_timing.Cache_lookup (fun () ->
      Dashboard_cache.get_or_compute cache_key ~ttl:30.0 (fun () ->
        Server_timing.measure
          timing_obj
          Server_timing.Telemetry_summary_aggregate
          (fun () -> Telemetry_unified.summary_json ~base_path ~masc_root ()))
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
