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
    (* actor-filtered variant OR snapshot not yet published — fall
       back to the synchronous compute path (per-actor cache lives
       inside [dashboard_tools_http_json]). *)
    Server_dashboard_http_runtime_info.dashboard_tools_http_json
      ?actor ~timing:timing_obj config
;;

(* Cache key shared with the legacy router-inline definition.  Kept
   byte-identical so a cold start that hits the fallback path observes
   the same cache slot the previous router code wrote into.  When Step
   5 retires [Dashboard_cache] from this read path, the duplicate goes
   away together. *)
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
          (fun () -> Telemetry_unified.summary_json ~base_path ~masc_root ())))
;;
