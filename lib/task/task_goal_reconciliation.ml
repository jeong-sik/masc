type ready = {
  goal_id : string;
  triggering_task_id : string;
}

module Workspace = Workspace_core

let ready_after_terminal_task ~config ~task_id =
  let tasks = Workspace.get_tasks_raw config in
  match
    List.find_opt
      (fun (task : Masc_domain.task) -> String.equal task.id task_id)
      tasks
  with
  | Some task when Masc_domain.task_status_is_terminal task.task_status ->
    let goal_task_links = Workspace_goal_index.read_goal_task_links config in
    let task_goal_index =
      Workspace_goal_index.build_task_goal_index ~goal_task_links ()
    in
    (match Hashtbl.find_opt task_goal_index task_id with
     | Some [ goal_id ] ->
       (match Goal_store.get_goal config ~goal_id with
        | Some { phase = Goal_phase.Executing; _ } ->
          let goal_task_index =
            Workspace_goal_index.build_goal_task_index ~goal_task_links tasks
          in
          if
            Workspace_goal_index.tasks_for_goal goal_task_index ~goal_id <> []
            && Workspace_goal_index.open_task_count_for_goal_indexed
                 goal_task_index
                 ~goal_id
               = 0
          then Some { goal_id; triggering_task_id = task_id }
          else None
        | Some _ | None -> None)
     | Some (_ :: _ :: _) | Some [] | None -> None)
  | Some _ | None -> None
