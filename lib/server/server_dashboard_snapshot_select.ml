(** Scope and producer authority are checked before each retained read. *)

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
    match Dashboard_snapshot.shell_for_config config with
    | Some (_, trimmed) ->
      let shell =
        Server_timing.measure
          timing_obj
          (Server_timing.Custom "snapshot_read")
          (fun () -> trimmed)
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
    match Dashboard_snapshot.shell_for_config config with
    | Some (full, _) ->
      let shell =
        Server_timing.measure
          timing_obj
          (Server_timing.Custom "snapshot_read")
          (fun () -> full)
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
  match keeper, Dashboard_snapshot.tools_for_config config with
  | None, Some tools ->
    Server_timing.measure
      timing_obj
      (Server_timing.Custom "snapshot_read")
      (fun () -> Tools_prepared tools)
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
  match Dashboard_snapshot.telemetry_for_config config with
  | Some summary ->
    Server_timing.measure
      timing_obj
      (Server_timing.Custom "snapshot_read")
      (fun () -> summary)
  | None ->
    let base_path = config.base_path in
    let masc_root = Workspace.masc_dir config in
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
  match Server_dashboard_http_namespace_truth.namespace_truth_snapshot_from_caches state with
  | Some snapshot ->
    Server_timing.measure timing_obj (Server_timing.Custom "snapshot_read") (fun () -> snapshot)
  | None ->
    Server_timing.measure timing_obj Server_timing.Project_snapshot_runtime (fun () ->
      Server_dashboard_http_namespace_truth.dashboard_namespace_truth_http_json
        ~state ~sw ~clock req)
;;
