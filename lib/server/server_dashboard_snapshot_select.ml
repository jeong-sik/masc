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
let replace_assoc_field name value = function
  | `Assoc fields ->
    `Assoc ((name, value) :: List.remove_assoc name fields)
  | other -> other
;;

let waiting_inventory_visibility = function
  | `Assoc fields ->
    (match List.assoc_opt "keeper_waiting_inventory" fields with
     | Some (`Assoc inventory_fields) ->
       (match List.assoc_opt "visibility" inventory_fields with
        | Some (`String visibility) -> Some visibility
        | Some _ | None -> None)
     | Some _ | None -> None)
  | _ -> None
;;

let select_tools_json
      ?actor ?timing ?(include_sensitive = false)
      ?(fresh_keeper_waiting_inventory = false) (config : Workspace.config)
  : Yojson.Safe.t
  =
  let timing_obj =
    match timing with
    | Some t -> t
    | None -> Server_timing.create ()
  in
  let base, used_snapshot =
    match actor, Dashboard_snapshot.current () with
    | None, Some snap ->
      ( Server_timing.measure
          timing_obj
          (Server_timing.Custom "snapshot_read")
          (fun () -> snap.tools)
      , true )
    | _ ->
      ( Server_dashboard_http_runtime_info.dashboard_tools_http_json
          ?actor ~timing:timing_obj ~include_sensitive config
      , false )
  in
  let expected_visibility = if include_sensitive then "operator" else "redacted" in
  let snapshot_projection_matches_request =
    (not used_snapshot)
    || waiting_inventory_visibility base = Some expected_visibility
  in
  if not fresh_keeper_waiting_inventory && snapshot_projection_matches_request
  then base
  else
    let keeper_waiting_inventory =
      Server_timing.measure
        timing_obj
        (Server_timing.Custom "fresh_keeper_waiting_inventory")
        (fun () ->
          if include_sensitive
          then Server_keeper_waiting_inventory.dashboard_json config
          else Server_keeper_waiting_inventory.tool_json config)
    in
    replace_assoc_field "keeper_waiting_inventory" keeper_waiting_inventory base
;;

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
