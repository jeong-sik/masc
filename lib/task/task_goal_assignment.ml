(** RFC-0267 Phase 2 — explicit, validated task->goal assignment.

    See {!Task_goal_assignment} (the .mli) for the contract. *)

(* Why this lives in [masc_task_handlers] (the task domain), not in the goal
   leaf domain: the operation needs all three stores — [Goal_store] (goal
   existence), the task backlog ([Workspace_query], task existence), and
   [Workspace_goal_index] (the link write). The task domain already integrates
   with goals (e.g. [handle_add_task] validates a goal_id), so a task->goal
   reference here is the established, allowed direction. Putting it in [lib/goal]
   instead would teach the goal *leaf* domain about the task domain. Both the
   MCP tool handler and the dashboard HTTP route call this one function, so the
   precondition checks live in a single place. *)

type set_task_goal_error =
  | Goal_source_unavailable of Goal_store.unavailable
  | Goal_lock_failed of Masc_domain.masc_error
  | Backlog_read_failed of string
  | Unknown_task of string
  | Ambiguous_task of string
  | Unknown_goal of string
  | Ambiguous_goal of string
  | Goal_closed of { goal_id : string; phase : Goal_phase.t }
  | Task_finished of
      { task_id : string
      ; status : Masc_domain.task_status
      }
  | Already_assigned of
      { task_id : string
      ; existing_goal_ids : string list
      }
  | Link_write_failed of string

let set_task_goal_error_to_string = function
  | Goal_source_unavailable unavailable ->
    "Goal store unavailable: " ^ Goal_store.unavailable_to_string unavailable
  | Goal_lock_failed error -> "Goal store lock failed: " ^ Masc_domain.masc_error_to_string error
  | Backlog_read_failed message -> Printf.sprintf "failed to read authoritative backlog: %s" message
  | Unknown_task task_id -> Printf.sprintf "unknown task '%s'" task_id
  | Ambiguous_task task_id -> Printf.sprintf "task '%s' has an ambiguous ID" task_id
  | Unknown_goal goal_id -> Printf.sprintf "unknown goal '%s'" goal_id
  | Ambiguous_goal goal_id -> Printf.sprintf "goal '%s' has an ambiguous ID" goal_id
  | Goal_closed { goal_id; phase } ->
    Printf.sprintf "goal '%s' is %s; new work cannot be linked" goal_id (Goal_phase.to_string phase)
  | Task_finished { task_id; status } ->
    Printf.sprintf
      "task '%s' is already %s; a finished task is not linked to a goal (a link \
       has no timestamp)"
      task_id
      (Masc_domain.task_status_to_string status)
  | Already_assigned { task_id; existing_goal_ids } ->
    Printf.sprintf
      "task '%s' is already assigned to goal(s) [%s]; reassignment is out of \
       scope (RFC-0267 Phase 2 only links goalless tasks)"
      task_id
      (String.concat ", " existing_goal_ids)
  | Link_write_failed msg -> Printf.sprintf "failed to persist task goal link: %s" msg
;;

let set_task_goal config ~task_id ~goal_id : (unit, set_task_goal_error) result =
  let task_id = String.trim task_id in
  let goal_id = String.trim goal_id in
  match Goal_store.with_assignable_goal config ~goal_id (fun () ->
    match Workspace_utils.with_file_lock_r config (Workspace_backlog.backlog_lock_path config) (fun () ->
      match Workspace_backlog.read_prepared_backlog_r config with
      | Error message -> Error (Backlog_read_failed message)
      | Ok prepared ->
        (match List.filter (fun (task : Masc_domain.task) ->
           String.equal (String.trim task.id) task_id) prepared.backlog.tasks with
         | [] -> Error (Unknown_task task_id)
         | [task] when String.equal task.id task_id ->
           if Masc_domain.task_status_is_terminal task.task_status then
             Error (Task_finished { task_id; status = task.task_status })
           else
             (match Workspace_goal_index.link_goalless_task_to_goal config ~goal_id ~task_id with
              | Ok () -> Ok ()
              | Error (Workspace_goal_index.Already_linked_to_goals existing_goal_ids) ->
                Error (Already_assigned { task_id; existing_goal_ids })
              | Error (Workspace_goal_index.Link_write_failed message) ->
                Error (Link_write_failed message))
         | [_] | _ :: _ :: _ -> Error (Ambiguous_task task_id))) with
    | Ok result -> result
    | Error error -> Error (Backlog_read_failed (Masc_domain.masc_error_to_string error))) with
  | Ok result -> result
  | Error (Goal_store.Assignment_goal_missing id) -> Error (Unknown_goal id)
  | Error (Goal_store.Assignment_goal_ambiguous id) -> Error (Ambiguous_goal id)
  | Error (Goal_store.Assignment_goal_closed phase) -> Error (Goal_closed { goal_id; phase })
  | Error (Goal_store.Assignment_source_unavailable unavailable) ->
    Error (Goal_source_unavailable unavailable)
  | Error (Goal_store.Assignment_lock_failed error) -> Error (Goal_lock_failed error)
;;

(* Workspace is the persistence layer and Goal depends on it. This task-domain
   boundary joins Goal authority to that existing backlog/link transaction
   without introducing a workspace-to-Goal dependency cycle. *)
let add_task_with_result ?contract ?goal_id ?created_by ?creation_request_id ?predecessor_task_id
    ?skills config ~title ~priority ~description =
  let goal_id = Workspace_task_classify.trim_opt goal_id in
  match Goal_store.with_existing_goals config ~goal_ids:(Option.to_list goal_id) (fun () ->
    Workspace_task.add_task_with_result ?contract ?goal_id ?created_by ?creation_request_id
      ?predecessor_task_id ?skills config ~title ~priority ~description) with
  | Ok result -> result
  | Error (Goal_store.Goal_missing id) -> Error (Workspace_task.Unknown_goal id)
  | Error (Goal_store.Goal_source_unavailable unavailable) ->
    Error (Workspace_task.Goal_source_unavailable unavailable)
  | Error (Goal_store.Goal_lock_failed error) ->
    Error (Workspace_task.Goal_lock_failed (Masc_domain.masc_error_to_string error))
;;

let batch_add_tasks_with_contracts_result ?created_by config tasks =
  let tasks = List.map (fun (title, priority, description, contract, goal_id) ->
    title, priority, description, contract, Workspace_task_classify.trim_opt goal_id) tasks in
  let goal_ids = List.filter_map (fun (_, _, _, _, goal_id) -> goal_id) tasks in
  match Goal_store.with_existing_goals config ~goal_ids (fun () ->
    Workspace_task.batch_add_tasks_with_contracts_result ?created_by config tasks) with
  | Ok result -> result
  | Error (Goal_store.Goal_missing id) -> Error (Workspace_task.Batch_unknown_goal id)
  | Error (Goal_store.Goal_source_unavailable unavailable) ->
    Error (Workspace_task.Batch_goal_source_unavailable unavailable)
  | Error (Goal_store.Goal_lock_failed error) ->
    Error (Workspace_task.Batch_goal_lock_failed (Masc_domain.masc_error_to_string error))
;;
