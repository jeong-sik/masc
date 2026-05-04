(** Keeper current-task reconciliation shared by task transitions and
    keeper run-context assembly.

    This module intentionally does not depend on Tool_task or
    Keeper_agent_tool_surface, so lifecycle transitions can update keeper meta
    without creating a keeper tool-surface dependency cycle. *)

let resolved_agent_names ~(config : Coord.config) ~(agent_name : string) =
  let actual_name =
    try Coord.resolve_agent_name config agent_name
    with
    | Sys_error _ | Yojson.Json_error _ -> agent_name
    | exn ->
      Log.Keeper.warn
        "resolve_agent_name failed while reconciling current task for %s: %s"
        agent_name (Printexc.to_string exn);
      agent_name
  in
  [ agent_name; actual_name ] |> List.sort_uniq String.compare

let task_id_of_owned_active_task ~(keeper_name : string) (task : Types.task) =
  match Keeper_id.Task_id.of_string task.id with
  | Ok task_id -> Some task_id
  | Error msg ->
    Log.Keeper.warn
      "keeper:%s owned task %s could not be parsed: %s"
      keeper_name task.id msg;
    None

let owned_active_task_ids_for_meta ~(config : Coord.config)
    ~(meta : Keeper_types.keeper_meta) =
  let names = resolved_agent_names ~config ~agent_name:meta.agent_name in
  let matches assignee = List.mem assignee names in
  try
    Coord.get_tasks_raw config
    |> List.filter_map (fun (task : Types.task) ->
         match task.task_status with
         | Types.Claimed { assignee; _ }
         | Types.InProgress { assignee; _ }
           when matches assignee ->
             task_id_of_owned_active_task ~keeper_name:meta.name task
         | Types.Claimed _
         | Types.InProgress _
         | Types.AwaitingVerification _
         | Types.Todo
         | Types.Done _
         | Types.Cancelled _ -> None)
    |> List.sort_uniq (fun a b ->
         String.compare
           (Keeper_id.Task_id.to_string a)
           (Keeper_id.Task_id.to_string b))
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Keeper.warn
      "keeper:%s owned task reconciliation failed: %s"
      meta.name (Printexc.to_string exn);
    []

let owned_active_task_id_for_meta ~(config : Coord.config)
    ~(meta : Keeper_types.keeper_meta) =
  match owned_active_task_ids_for_meta ~config ~meta with
  | [ task_id ] -> Some task_id
  | [] -> None
  | task_ids ->
    Log.Keeper.warn
      "keeper:%s has %d active owned tasks; leaving current_task_id unset until one task is explicit"
      meta.name (List.length task_ids);
    None

let merge_current_task_id ~(latest : Keeper_types.keeper_meta)
    ~(caller : Keeper_types.keeper_meta) =
  {
    latest with
    current_task_id = caller.current_task_id;
    updated_at = caller.updated_at;
  }

let sync_current_task_id_from_backlog ~(config : Coord.config)
    (meta : Keeper_types.keeper_meta) =
  let desired = owned_active_task_id_for_meta ~config ~meta in
  let equal =
    match meta.current_task_id, desired with
    | None, None -> true
    | Some a, Some b -> Keeper_id.Task_id.equal a b
    | Some _, None | None, Some _ -> false
  in
  if equal then meta
  else
    let updated_meta =
      { meta with current_task_id = desired; updated_at = Types.now_iso () }
    in
    Keeper_registry.update_meta ~base_path:config.base_path meta.name updated_meta;
    (match
       Keeper_types.write_meta_with_merge
         ~merge:merge_current_task_id config updated_meta
     with
     | Ok () -> ()
     | Error msg ->
       Prometheus.inc_counter
         Prometheus.metric_keeper_write_meta_failures
         ~labels:[("keeper", meta.name); ("phase", "reconcile_task_id")]
         ();
       Log.Keeper.warn
         "keeper:%s failed to persist reconciled current_task_id=%s: %s"
         meta.name
         (match desired with
          | Some task_id -> Keeper_id.Task_id.to_string task_id
          | None -> "(cleared)")
         msg);
    Log.Keeper.info
      "keeper:%s reconciled current_task_id=%s from backlog ownership"
      meta.name
      (match desired with
       | Some task_id -> Keeper_id.Task_id.to_string task_id
       | None -> "(cleared)");
    updated_meta

let keeper_name_candidates ~(config : Coord.config) ~(agent_name : string) =
  resolved_agent_names ~config ~agent_name
  |> List.filter_map Keeper_identity.canonical_keeper_name
  |> List.sort_uniq String.compare

let sync_current_task_id_for_agent_name ~(config : Coord.config) ~agent_name =
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
    ignore (sync_current_task_id_from_backlog ~config entry.meta : Keeper_types.keeper_meta)
  | None ->
    candidates
    |> List.find_map (fun name ->
         match Keeper_types.read_meta config name with
         | Ok (Some meta) -> Some meta
         | Ok None | Error _ -> None)
    |> Option.iter (fun meta ->
         ignore (sync_current_task_id_from_backlog ~config meta : Keeper_types.keeper_meta))
