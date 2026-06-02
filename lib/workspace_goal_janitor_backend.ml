(** Workspace-owned task escalation installed behind Goal_janitor hooks. *)

let task_age_seconds ?(now = Unix.gettimeofday ()) (task : Masc_domain.task) =
  match Masc_domain.parse_iso8601_opt task.created_at with
  | None -> None
  | Some created_at -> Some (int_of_float (max 0.0 (now -. created_at)))

let audit_unclaimed_goal_orphan_tasks ?(now = Unix.gettimeofday ())
    ~valid_goal_ids:_ ~min_age_seconds (tasks : Masc_domain.task list) =
  tasks
  |> List.filter_map (fun (task : Masc_domain.task) ->
    match task.task_status, task.goal_id, task_age_seconds ~now task with
    | Masc_domain.Todo, None, Some age_seconds
      when age_seconds >= min_age_seconds ->
        Some (task, age_seconds)
    | _ -> None)

let emit_orphan_task_escalation workspace_config ~threshold_seconds orphan_tasks =
  match orphan_tasks with
  | [] -> ()
  | _ ->
      let task_ids =
        List.map
          (fun ((task, _) : Masc_domain.task * int) -> `String task.id)
          orphan_tasks
      in
      let task_items =
        List.map
          (fun ((task, age_seconds) : Masc_domain.task * int) ->
             `Assoc
               [ ("task_id", `String task.id)
               ; ("title", `String task.title)
               ; ("created_at", `String task.created_at)
               ; ("age_seconds", `Int age_seconds)
               ; ("created_by", Json_util.string_opt_to_json task.created_by)
               ])
          orphan_tasks
      in
      Workspace_utils.log_event workspace_config
        (`Assoc
           [ ("type", `String "goal_orphan_task_escalation")
           ; ("subsystem", `String "goal_janitor")
           ; ("threshold_seconds", `Int threshold_seconds)
           ; ("orphan_task_count", `Int (List.length orphan_tasks))
           ; ("task_ids", `List task_ids)
           ; ("tasks", `List task_items)
           ; ( "action",
               `String "link_task_goal_id_or_cancel_stale_unclaimed_task" )
           ; ("ts", `String (Masc_domain.now_iso ()))
           ]);
      Log.Misc.warn
        "[GoalJanitor] escalated %d stale unclaimed task(s) without goal linkage"
        (List.length orphan_tasks)

let escalate_orphan_tasks workspace_config ~valid_goal_ids ~min_age_seconds =
  let orphan_task_rows =
    Workspace_query.get_tasks_safe workspace_config
    |> audit_unclaimed_goal_orphan_tasks ~valid_goal_ids ~min_age_seconds
  in
  emit_orphan_task_escalation workspace_config
    ~threshold_seconds:min_age_seconds
    orphan_task_rows;
  List.length orphan_task_rows

let install_hooks () =
  Goal_janitor.set_orphan_task_escalation_hooks
    { Goal_janitor.escalate_orphan_tasks = escalate_orphan_tasks }
