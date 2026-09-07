(** See [server_dashboard_snapshot_select.mli] for the contract. *)

let select_shell_json
      ?clock ?request ?timing ?(light = false) (config : Workspace.config)
  : Yojson.Safe.t
  =
  let timing_obj =
    match timing with
    | Some t -> t
    | None -> Server_timing.create ()
  in
  if light
  then (
    (* RFC-0204 section 8.3 ("A"): serve the published light projection
       wait-free.  Mirrors the non-light branch below but reads
       [snap.shell_light]; falls back to the (offloaded, timeout-guarded)
       recompute only before the first snapshot publish. *)
    match Dashboard_snapshot.current () with
    | Some snap ->
      let shell =
        Server_timing.measure
          timing_obj
          (Server_timing.Custom "snapshot_read")
          (fun () -> snap.shell_light)
      in
      (match request with
       | None -> shell
       | Some request ->
         Server_dashboard_http_core.dashboard_shell_with_request_auth_json
           ~request config shell)
    | None ->
      Server_dashboard_http_core.dashboard_shell_http_json
        ?clock ?request ~timing:timing_obj ~light config)
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
type tools_response =
  | Tools_json of Yojson.Safe.t
  | Tools_prepared of Dashboard_snapshot.tools_projection

let select_tools_response_with ~fallback
      ?keeper ?timing (config : Workspace.config)
  : tools_response
  =
  let timing_obj =
    match timing with
    | Some t -> t
    | None -> Server_timing.create ()
  in
  match keeper, Dashboard_snapshot.current () with
  | None, Some snap
    when String.equal snap.tools.base_path config.base_path
      && String.equal snap.tools.workspace_path config.workspace_path
      && String.equal snap.tools.masc_root (Workspace.masc_root_dir config) ->
    Server_timing.measure
      timing_obj
      (Server_timing.Custom "snapshot_read")
      (fun () -> Tools_prepared snap.tools)
  | _ ->
    Tools_json (fallback ~keeper ~timing:timing_obj config)
;;

let select_tools_response ?keeper ?timing config =
  select_tools_response_with ?keeper ?timing config
    ~fallback:(fun ~keeper ~timing config ->
      Server_dashboard_http_runtime_info.dashboard_tools_http_json ?keeper ~timing config)

let select_tools_json ?keeper ?timing config =
  match select_tools_response ?keeper ?timing config with
  | Tools_json json -> json
  | Tools_prepared tools -> tools.json

module For_testing = struct
  let select_tools_response = select_tools_response_with
end

let select_telemetry_summary_json
      ?timing (config : Workspace.config)
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
    let masc_root = Workspace.masc_root_dir config in
    let keeper_keepalive_interval_s =
      Runtime_params.get Runtime_settings.keeper_keepalive_interval_sec
      |> float_of_int
    in
    let keeper_metric_producer_active =
      Keeper_status_runtime.keeper_metric_producer_active ~base_path
    in
    Server_timing.measure
      timing_obj
      Server_timing.Telemetry_summary_aggregate
      (fun () ->
         Telemetry_unified.summary_json
           ~keeper_keepalive_interval_s
           ~keeper_metric_producer_active
           ~base_path
           ~masc_root
           ())
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
    (* Fallback: snapshot not yet published or namespace_truth is [`Null].
       Compute directly — the snapshot refresh loop (~2s) republishes
       quickly, so this cold path is hit at most once per process
       lifetime or after a brief LRU eviction window. *)
    Server_timing.measure
      timing_obj
      Server_timing.Project_snapshot_runtime
      (fun () ->
        Server_dashboard_http_namespace_truth
          .dashboard_namespace_truth_http_json
          ~state ~sw ~clock req)
;;
