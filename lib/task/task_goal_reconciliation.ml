type ready = {
  goal_id : string;
  triggering_task_id : string;
}

type startup_ready = {
  ready : ready;
  completing_agent_name : string;
}

module Workspace = Workspace_core

let terminal_fact (task : Masc_domain.task) =
  match task.task_status with
  | Masc_domain.Done { assignee; completed_at; _ } ->
    Some (completed_at, assignee)
  | Masc_domain.Cancelled { cancelled_by; cancelled_at; _ } ->
    Some (cancelled_at, cancelled_by)
  | Masc_domain.Todo
  | Masc_domain.Claimed _
  | Masc_domain.InProgress _
  | Masc_domain.AwaitingVerification _ -> None
;;

let latest_terminal_task tasks =
  match
    tasks
    |> List.filter_map (fun task ->
         Option.map
           (fun (terminal_at, completing_agent_name) ->
              task, terminal_at, completing_agent_name)
           (terminal_fact task))
    |> List.sort (fun
         ((left : Masc_domain.task), left_at, _)
         ((right : Masc_domain.task), right_at, _) ->
         match String.compare right_at left_at with
         | 0 -> String.compare right.id left.id
         | ordering -> ordering)
  with
  | [] -> None
  | latest :: _ -> Some latest
;;

let ready_after_terminal_task ~config ~task_id =
  let open Result.Syntax in
  let* backlog = Workspace_backlog.read_backlog_r config in
  let tasks = backlog.tasks in
  Ok
    (match
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
     | Some _ | None -> None)

let ready_executing_goals ~config =
  let open Result.Syntax in
  let* backlog = Workspace_backlog.read_backlog_r config in
  let tasks = backlog.tasks in
  let goal_task_links = Workspace_goal_index.read_goal_task_links config in
  let goal_task_index =
    Workspace_goal_index.build_goal_task_index ~goal_task_links tasks
  in
  Ok
    (Goal_store.list_goals config ~phase:Goal_phase.Executing ()
     |> List.sort (fun left right -> String.compare left.Goal_store.id right.Goal_store.id)
     |> List.filter_map (fun (goal : Goal_store.goal) ->
       let linked_tasks =
         Workspace_goal_index.tasks_for_goal goal_task_index ~goal_id:goal.id
       in
       if
         linked_tasks = []
         || not
              (List.for_all
                 (fun (task : Masc_domain.task) ->
                    Masc_domain.task_status_is_terminal task.task_status)
                 linked_tasks)
       then None
       else
         match latest_terminal_task linked_tasks with
         | None -> None
         | Some (task, _, completing_agent_name) ->
           Some
             { ready =
                 { goal_id = goal.id; triggering_task_id = task.Masc_domain.id }
             ; completing_agent_name
             }))
;;
