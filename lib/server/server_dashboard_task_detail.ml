type error = Missing_task_id | Task_not_found | Task_detail_unavailable

let find ~tasks ~goal_task_index ~task_id =
  let task_id = String.trim task_id in
  if task_id = "" then Error Missing_task_id
  else
    match List.find_opt (fun (task : Masc_domain.task) -> String.equal task.id task_id) tasks with
    | None -> Error Task_not_found
    | Some task -> Ok (Dashboard_execution.task_json ~goal_task_index task)

let read ~config ~task_id =
  match task_id with
  | None -> Error Missing_task_id
  | Some task_id ->
  let task_id = String.trim task_id in
  if task_id = "" then Error Missing_task_id
  else
    try
      match Workspace_backlog.read_backlog_r config with
      | Error _ -> Error Task_detail_unavailable
      | Ok backlog ->
          match List.find_opt
            (fun (task : Masc_domain.task) -> String.equal task.id task_id)
            backlog.tasks with
          | None -> Error Task_not_found
          | Some task ->
              match Workspace_goal_index.read_goal_task_links_authoritative_r config with
              | Error _ -> Error Task_detail_unavailable
              | Ok goal_task_links ->
                  let goal_task_index =
                    Workspace_goal_index.build_task_goal_index ~goal_task_links () in
                  Ok (Dashboard_execution.task_json ~goal_task_index task)
    with
    | Sys_error _ | Unix.Unix_error _
    | Workspace_backlog.Backlog_read_failed _ -> Error Task_detail_unavailable

type status = [ `OK | `Bad_request | `Not_found | `Service_unavailable ]

let response result : status * Yojson.Safe.t = match result with
  | Ok task -> `OK, `Assoc ["task", task]
  | Error Missing_task_id ->
      `Bad_request, `Assoc ["error", `String "task_id is required"]
  | Error Task_not_found ->
      `Not_found, `Assoc ["error", `String "task not found"]
  | Error Task_detail_unavailable ->
      `Service_unavailable, `Assoc ["error", `String "task detail unavailable"]
