(** Keeper current-task reconciliation shared by task transitions and
    keeper run-context assembly.

    This module intentionally does not depend on Task.Tool or
    Keeper_agent_tool_surface, so lifecycle transitions can update keeper meta
    without creating a keeper tool-surface dependency cycle. *)

let resolved_agent_names ~(config : Workspace.config) ~(agent_name : string) =
  let actual_name =
    try Workspace.resolve_agent_name config agent_name
    with
    | Sys_error _ | Yojson.Json_error _ -> agent_name
    | exn ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string ReconcileFailures)
        ~labels:[("keeper", agent_name); ("phase", "resolve_agent")]
        ();
      Log.Keeper.warn
        "resolve_agent_name failed while reconciling current task for %s: %s"
        agent_name (Printexc.to_string exn);
      agent_name
  in
  [ agent_name; actual_name ] |> List.sort_uniq String.compare

let task_id_of_owned_active_task ~(keeper_name : string) (task : Masc_domain.task) =
  match Keeper_id.Task_id.of_string task.id with
  | Ok task_id -> Some task_id
  | Error msg ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ReconcileFailures)
      ~labels:[("keeper", keeper_name); ("phase", "task_id_parse")]
      ();
    Log.Keeper.warn ~keeper_name:keeper_name
      "owned task %s could not be parsed: %s"
      task.id msg;
    None

type owned_active_task =
  { task_id : Keeper_id.Task_id.t
  ; task : Masc_domain.task
  }

let owned_active_tasks_for_meta ~(config : Workspace.config)
    ~(meta : Keeper_meta_contract.keeper_meta) =
  let names = resolved_agent_names ~config ~agent_name:meta.agent_name in
  let matches assignee = List.mem assignee names in
  try
    match Workspace_backlog.read_backlog_r config with
    | Error message ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string ReconcileFailures)
        ~labels:[("keeper", meta.name); ("phase", "owned_tasks_query")]
        ();
      Log.Keeper.warn ~keeper_name:meta.name
        "owned task reconciliation failed: %s"
        message;
      Error message
    | Ok backlog ->
      backlog.tasks
      |> List.filter_map (fun (task : Masc_domain.task) ->
           match task.task_status with
           | Masc_domain.Claimed { assignee; _ }
           | Masc_domain.InProgress { assignee; _ }
             when matches assignee ->
               task_id_of_owned_active_task ~keeper_name:meta.name task
               |> Option.map (fun task_id -> { task_id; task })
           | Masc_domain.Claimed _
           | Masc_domain.InProgress _
           | Masc_domain.AwaitingVerification _
           | Masc_domain.Todo
           | Masc_domain.Done _
           | Masc_domain.Cancelled _ -> None)
      |> fun tasks -> Ok tasks
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    let message = Printexc.to_string exn in
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ReconcileFailures)
      ~labels:[("keeper", meta.name); ("phase", "owned_tasks_query")]
      ();
    Log.Keeper.warn ~keeper_name:meta.name
      "owned task reconciliation failed: %s"
      message;
    Error message

let active_status_rank = function
  | Masc_domain.InProgress _ -> 0
  | Masc_domain.Claimed _ -> 1
  | Masc_domain.AwaitingVerification _
  | Masc_domain.Todo
  | Masc_domain.Done _
  | Masc_domain.Cancelled _ -> 2

let current_task_rank (meta : Keeper_meta_contract.keeper_meta) task_id =
  match meta.current_task_id with
  | Some current when Keeper_id.Task_id.equal current task_id -> 0
  | Some _ | None -> 1

let compare_owned_active_task ~(meta : Keeper_meta_contract.keeper_meta) a b =
  let cmp = compare (current_task_rank meta a.task_id) (current_task_rank meta b.task_id) in
  if cmp <> 0
  then cmp
  else (
    let cmp = compare (active_status_rank a.task.task_status) (active_status_rank b.task.task_status) in
    if cmp <> 0
    then cmp
    else (
      let cmp = compare a.task.priority b.task.priority in
      if cmp <> 0
      then cmp
      else (
        let cmp = String.compare a.task.created_at b.task.created_at in
        if cmp <> 0
        then cmp
        else
          String.compare
            (Keeper_id.Task_id.to_string a.task_id)
            (Keeper_id.Task_id.to_string b.task_id))))

let owned_active_task_id_result_for_meta ~(config : Workspace.config)
    ~(meta : Keeper_meta_contract.keeper_meta) =
  match owned_active_tasks_for_meta ~config ~meta with
  | Error _ as err -> err
  | Ok [ { task_id; _ } ] -> Ok (Some task_id)
  | Ok [] -> Ok None
  | Ok tasks ->
    (match List.sort (compare_owned_active_task ~meta) tasks with
     | selected :: _ -> Ok (Some selected.task_id)
     | [] -> Ok None)

let owned_active_task_id_for_meta ~(config : Workspace.config)
    ~(meta : Keeper_meta_contract.keeper_meta) =
  match owned_active_task_id_result_for_meta ~config ~meta with
  | Ok task_id -> task_id
  | Error _ -> None

let merge_current_task_id ~(latest : Keeper_meta_contract.keeper_meta)
    ~(caller : Keeper_meta_contract.keeper_meta) =
  {
    latest with
    current_task_id = caller.current_task_id;
    updated_at = caller.updated_at;
  }

let sync_current_task_id_from_backlog ~(config : Workspace.config)
    (meta : Keeper_meta_contract.keeper_meta) =
  match owned_active_task_id_result_for_meta ~config ~meta with
  | Error err ->
    Log.Keeper.warn ~keeper_name:meta.name
      "current task sync skipped because backlog ownership could not be read: %s"
      err;
    meta
  | Ok desired ->
    let equal =
      match meta.current_task_id, desired with
      | None, None -> true
      | Some a, Some b -> Keeper_id.Task_id.equal a b
      | Some _, None | None, Some _ -> false
    in
    if equal then meta
    else
      let updated_meta =
        { meta with current_task_id = desired; updated_at = Masc_domain.now_iso () }
      in
      Keeper_registry.update_meta ~base_path:config.base_path meta.name updated_meta;
      (match
         Keeper_meta_store.write_meta_with_merge
           ~merge:merge_current_task_id config updated_meta
       with
       | Ok () -> ()
       | Error msg ->
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string WriteMetaFailures)
           ~labels:[("keeper", meta.name); ("phase", "reconcile_task_id")]
           ();
         Log.Keeper.warn ~keeper_name:meta.name
           "failed to persist reconciled current_task_id=%s: %s"
           (match desired with
            | Some task_id -> Keeper_id.Task_id.to_string task_id
            | None -> "(cleared)")
           msg);
      (* RFC-0142 / audit 2026-05-21 §10.2: this is the success path of a
         routine drift correction, firing on every observed delta between
         keeper_meta.current_task_id and backlog ownership.  Live measurement
         on 5/21 captured 1,183 events/day across the fleet — none of them
         individually actionable (the WARN branch above + the
         [metric_keeper_write_meta_failures] counter already cover the
         failure case).  Demoted to DEBUG so the high-volume verbose path
         no longer drowns the INFO stream; raise back to INFO only if a
         per-keeper thrash investigation needs structured timing without
         a debug-level subscription. *)
      Log.Keeper.debug ~keeper_name:meta.name
        "reconciled current_task_id=%s from backlog ownership"
        (match desired with
         | Some task_id -> Keeper_id.Task_id.to_string task_id
         | None -> "(cleared)");
      updated_meta

let keeper_name_candidates ~(config : Workspace.config) ~(agent_name : string) =
  resolved_agent_names ~config ~agent_name
  |> List.filter_map Keeper_identity.canonical_keeper_name
  |> List.sort_uniq String.compare

let sync_current_task_id_for_agent_name ~(config : Workspace.config) ~agent_name =
  let candidates = keeper_name_candidates ~config ~agent_name in
  let entry_from_candidates =
    candidates
    |> List.find_map (fun name ->
         match Keeper_registry.get ~base_path:config.base_path name with
         | Some entry -> Some entry
         | None -> None)
  in
  let entry =
    match entry_from_candidates with
    | Some _ as entry -> entry
    | None ->
      Keeper_registry.all ~base_path:config.base_path ()
      |> List.find_opt (fun (entry : Keeper_registry.registry_entry) ->
           String.equal entry.meta.agent_name agent_name)
  in
  match entry with
  | Some entry ->
    ignore (sync_current_task_id_from_backlog ~config entry.meta : Keeper_meta_contract.keeper_meta)
  | None ->
    candidates
    |> List.find_map (fun name ->
         match Keeper_meta_store.read_meta config name with
         | Ok (Some meta) -> Some meta
         | Ok None | Error _ -> None)
    |> Option.iter (fun meta ->
         ignore (sync_current_task_id_from_backlog ~config meta : Keeper_meta_contract.keeper_meta))
