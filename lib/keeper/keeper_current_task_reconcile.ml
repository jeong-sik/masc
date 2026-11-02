(** Keeper current-task reconciliation shared by task transitions and
    keeper run-context assembly.

    This module intentionally does not depend on Task.Tool or
    Keeper_agent_tool_surface, so lifecycle transitions can update keeper meta
    without creating a keeper tool-surface dependency cycle. *)

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

type owned_active_tasks_snapshot =
  { tasks : owned_active_task list
  ; backlog_tasks : Masc_domain.task list
  ; backlog_version : int
  }

let owned_active_tasks_of_backlog ~(config : Workspace.config)
    ~(meta : Keeper_meta_contract.keeper_meta)
    (backlog : Masc_domain.backlog) =
  let tasks =
    backlog.tasks
    |> List.filter_map (fun (task : Masc_domain.task) ->
      match task.task_status with
      | Masc_domain.Claimed { assignee; _ }
      | Masc_domain.InProgress { assignee; _ }
        when Workspace_task_classify.same_task_actor
               config
               assignee
               meta.name ->
        task_id_of_owned_active_task ~keeper_name:meta.name task
        |> Option.map (fun task_id -> { task_id; task })
      | Masc_domain.Claimed _
      | Masc_domain.InProgress _
      | Masc_domain.AwaitingVerification _
      | Masc_domain.Todo
      | Masc_domain.Done _
      | Masc_domain.Cancelled _ -> None)
  in
  { tasks; backlog_tasks = backlog.tasks; backlog_version = backlog.version }

let owned_active_tasks_snapshot_for_meta ~(config : Workspace.config)
    ~(meta : Keeper_meta_contract.keeper_meta) =
  try
    match Workspace_backlog.read_prepared_backlog_r config with
    | Error message ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string ReconcileFailures)
        ~labels:[("keeper", meta.name); ("phase", "owned_tasks_query")]
        ();
      Log.Keeper.warn ~keeper_name:meta.name
        "owned task reconciliation failed: %s"
        message;
      Error message
    | Ok prepared ->
      Ok (owned_active_tasks_of_backlog ~config ~meta prepared.backlog)
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

let owned_active_tasks_for_meta ~config ~meta =
  owned_active_tasks_snapshot_for_meta ~config ~meta
  |> Result.map (fun snapshot -> snapshot.tasks)

let owned_active_tasks_snapshot_for_meta_strict ~(config : Workspace.config)
    ~(meta : Keeper_meta_contract.keeper_meta) =
  owned_active_tasks_snapshot_for_meta ~config ~meta
;;

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

let select_owned_active_task_id ~(meta : Keeper_meta_contract.keeper_meta)
    (tasks : owned_active_task list) =
  match tasks with
  | [] -> None
  | [ single ] -> Some single.task_id
  | tasks ->
    (match List.sort (compare_owned_active_task ~meta) tasks with
     | selected :: _ -> Some selected.task_id
     | [] -> None)

let owned_active_task_id_with_revision_for_meta ~(config : Workspace.config)
    ~(meta : Keeper_meta_contract.keeper_meta) =
  match owned_active_tasks_snapshot_for_meta ~config ~meta with
  | Error _ as err -> err
  | Ok snapshot ->
    Ok (snapshot.backlog_version, select_owned_active_task_id ~meta snapshot.tasks)

let owned_active_task_id_for_meta ~(config : Workspace.config)
    ~(meta : Keeper_meta_contract.keeper_meta) =
  match owned_active_task_id_result_for_meta ~config ~meta with
  | Ok task_id -> task_id
  | Error _ -> None

let between_ownership_read_and_apply_hook : (unit -> unit) Atomic.t =
  Atomic.make ignore

let reconcile_mu = Cross_context_mutex.create ()

let apply_current_task_if_revision
    ~(config : Workspace.config)
    ~(meta : Keeper_meta_contract.keeper_meta)
    ?preferred_task_id:(preferred_task_id : Keeper_id.Task_id.t option)
    ~backlog_revision
    ~desired
    ()
  =
  (Atomic.get between_ownership_read_and_apply_hook) ();
  let selection_meta =
    match preferred_task_id with
    | Some preferred -> { meta with current_task_id = Some preferred }
    | None -> meta
  in
  Cross_context_mutex.with_lock reconcile_mu (fun () ->
    match Workspace_backlog.read_prepared_backlog_r config with
    | Error message -> Error message
    | Ok prepared ->
      let current_snapshot =
        owned_active_tasks_of_backlog ~config ~meta:selection_meta prepared.backlog
      in
      let current_desired =
        select_owned_active_task_id ~meta:selection_meta current_snapshot.tasks
      in
      let effective_desired =
        if current_snapshot.backlog_version = backlog_revision
           && Option.equal Keeper_id.Task_id.equal desired current_desired
        then desired
        else current_desired
      in
      Ok
        ( effective_desired
        , Keeper_owner_registry.apply_meta
            ~base_path:config.base_path
            ~keeper_name:meta.name
            (Keeper_owner_reducer.Set_current_task
               { task_id = effective_desired; updated_at = Masc_domain.now_iso () }) ))

let sync_observed_task_with_revision ~(config : Workspace.config)
    (meta : Keeper_meta_contract.keeper_meta) observed =
  match observed with
  | Error err ->
    Log.Keeper.warn ~keeper_name:meta.name
      "current task sync skipped because backlog ownership could not be read: %s"
      err;
    meta, Error err
  | Ok (backlog_revision, desired) ->
    let registry_matches =
      match Keeper_registry.get ~base_path:config.base_path meta.name with
      | None -> true
      | Some entry ->
        Option.equal Keeper_id.Task_id.equal entry.meta.current_task_id desired
    in
    let equal =
      Option.equal Keeper_id.Task_id.equal meta.current_task_id desired
      && registry_matches
    in
    if equal then meta, Ok desired
    else
      (match
         apply_current_task_if_revision
           ~config
           ~meta
           ~backlog_revision
           ~desired
           ()
       with
       | Error err ->
         Log.Keeper.warn ~keeper_name:meta.name
           "current task sync skipped because backlog ownership recheck failed: %s"
           err;
         meta, Error err
       | Ok (effective_desired, Ok (Some _persisted)) ->
         Log.Keeper.debug
           ~keeper_name:meta.name
           "reconciled current_task_id=%s from backlog ownership"
           (match effective_desired with
            | Some task_id -> Keeper_id.Task_id.to_string task_id
            | None -> "(cleared)");
         (* Update the one field this function is named for, on the caller's
            meta. [apply_meta] answers with the committed owner projection,
            which is durable JSON: that file omits the TOML-owned fields on
            purpose ([Keeper_meta_contract.effective_meta_result]), so every
            one of them -- sandbox_profile, network_mode,
            instructions -- comes back as the decoder's default. Returning it
            handed the turn a meta that had silently lost its overlay, and a
            keeper whose TOML said docker then dispatched Execute to the host.

            The two failure arms below already keep [meta]; only success
            replaced it, so the profile survived exactly the turns where the
            task id happened to match and this branch never ran. *)
         { meta with current_task_id = effective_desired }, Ok effective_desired
       | Ok (effective_desired, Ok None) ->
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string WriteMetaFailures)
           ~labels:[ "keeper", meta.name; "phase", "reconcile_task_id" ]
           ();
         Log.Keeper.warn
           ~keeper_name:meta.name
           "owner removed metadata while reconciling current_task_id";
         meta, Ok effective_desired
       | Ok (effective_desired, Error error) ->
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string WriteMetaFailures)
           ~labels:[ "keeper", meta.name; "phase", "reconcile_task_id" ]
           ();
         Log.Keeper.warn
           ~keeper_name:meta.name
           "failed to persist reconciled current_task_id=%s: %s"
           (match effective_desired with
            | Some task_id -> Keeper_id.Task_id.to_string task_id
            | None -> "(cleared)")
           (Keeper_owner_registry.command_error_to_string error);
         meta, Ok effective_desired)

let sync_current_task_id_with_observation ~config meta =
  let observed = owned_active_task_id_with_revision_for_meta ~config ~meta in
  sync_observed_task_with_revision ~config meta observed
;;

let sync_current_task_id_from_backlog ~config meta =
  fst (sync_current_task_id_with_observation ~config meta)
;;

let sync_current_task_id_for_agent_name ~(config : Workspace.config) ~agent_name =
  match
    Keeper_registry.all ~base_path:config.base_path ()
    |> List.find_opt (fun (entry : Keeper_registry.registry_entry) ->
         String.equal entry.name agent_name)
  with
  | Some entry ->
    ignore (sync_current_task_id_from_backlog ~config entry.meta : Keeper_meta_contract.keeper_meta)
  | None -> ()
