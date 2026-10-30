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

let inspect ~config ~task_id =
  match task_id with
  | None -> Error Missing_task_id
  | Some task_id ->
    let task_id=String.trim task_id in
    if task_id="" then Error Missing_task_id
    else try
      match Workspace_query.read_task_inspection_r config ~task_id with
      | Error _ -> Error Task_detail_unavailable
      | Ok observation ->
        let envelope kind task deletion = `Assoc [
          "schema",`String "masc.task-inspection/v1";"task_id",`String task_id;
          "observation",`String kind;"task",task;"deletion",deletion] in
        (match observation with
         | Workspace_query.Task_unobserved -> Ok (envelope "not_observed" `Null `Null)
         | Task_deletion_recorded receipt ->
           let cleanup=match receipt.Masc_domain.phase with
             | Cleanup_required _ -> "required" | Cleanup_verified -> "verified" in
           Ok (envelope "deletion_recorded" `Null (`Assoc [
             "deletion_id",`String receipt.deletion_id;"requested_at",`String receipt.requested_at;
             "cleanup",`String cleanup]))
         | Inspected_task {task;location} ->
           match Workspace_goal_index.read_goal_task_links_authoritative_r config with
           | Error _ -> Error Task_detail_unavailable
           | Ok goal_task_links ->
             let goal_task_index=Workspace_goal_index.build_task_goal_index ~goal_task_links () in
             let kind=match location with Task_backlog -> "backlog" | Task_archive -> "archive" in
             Ok (envelope kind (Dashboard_execution.task_json ~goal_task_index task) `Null))
    with Sys_error _ | Unix.Unix_error _ | Workspace_backlog.Backlog_read_failed _ ->
      Error Task_detail_unavailable

let inspection_response = function
  | Ok json -> `OK,json
  | Error error -> response (Error error)
