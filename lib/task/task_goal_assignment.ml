(** RFC-0267 Phase 2 — explicit, validated task->goal assignment.

    See {!Task_goal_assignment} (the .mli) for the contract. *)

(* Why this lives in [masc_task_handlers] (the task domain), not in the goal
   leaf domain: the operation needs all three stores — [Goal_store] (goal
   existence), the task backlog ([Workspace_query], task existence), and
   [Workspace_goal_index] (the link write). The task domain already integrates
   with goals (e.g. [handle_add_task] validates a goal_id), so a task->goal
   reference here is the established, allowed direction. Putting it in [lib/goal]
   instead would teach the goal *leaf* domain about the task domain — a
   goal->task coupling the domain-boundary ratchet
   (scripts/lint/masc-domain-boundary-ratchet.sh) rejects. Both the MCP tool
   handler and the dashboard HTTP route call this one function, so the
   precondition checks live in a single place. *)

type set_task_goal_error =
  | Goal_source_unavailable of string
  | Backlog_read_failed of string
  | Unknown_task of string
  | Unknown_goal of string
  | Already_assigned of
      { task_id : string
      ; existing_goal_ids : string list
      }
  | Link_write_failed of string

let set_task_goal_error_to_string = function
  | Goal_source_unavailable message -> "Goal store unavailable: " ^ message
  | Backlog_read_failed message -> Printf.sprintf "failed to read authoritative backlog: %s" message
  | Unknown_task task_id -> Printf.sprintf "unknown task '%s'" task_id
  | Unknown_goal goal_id -> Printf.sprintf "unknown goal '%s'" goal_id
  | Already_assigned { task_id; existing_goal_ids } ->
    Printf.sprintf
      "task '%s' is already assigned to goal(s) [%s]; reassignment is out of \
       scope (RFC-0267 Phase 2 only links goalless tasks)"
      task_id
      (String.concat ", " existing_goal_ids)
  | Link_write_failed msg -> Printf.sprintf "failed to persist task goal link: %s" msg
;;

let set_task_goal config ~task_id ~goal_id : (unit, set_task_goal_error) result =
  match Goal_store.with_existing_goals config ~goal_ids:[goal_id] (fun () ->
    match Workspace_utils.with_file_lock_r config (Workspace_backlog.backlog_lock_path config) (fun () ->
      match Workspace_backlog.read_backlog_r config with
      | Error message -> Error (Backlog_read_failed message)
      | Ok backlog when not (List.exists (fun (t : Masc_domain.task) -> String.equal t.id task_id) backlog.tasks) ->
        Error (Unknown_task task_id)
      | Ok _ ->
        match Workspace_goal_index.link_goalless_task_to_goal config ~goal_id ~task_id with
        | Ok () -> Ok ()
        | Error (Workspace_goal_index.Already_linked_to_goals existing_goal_ids) ->
          Error (Already_assigned { task_id; existing_goal_ids })
        | Error (Workspace_goal_index.Link_write_failed message) ->
          Error (Link_write_failed message)) with
    | Ok result -> result
    | Error error -> Error (Backlog_read_failed (Masc_domain.masc_error_to_string error))) with
  | Ok result -> result
  | Error (Goal_store.Goal_missing id) -> Error (Unknown_goal id)
  | Error (Goal_store.Goal_source_unavailable message) -> Error (Goal_source_unavailable message)
;;

(* Workspace is the persistence layer and Goal depends on it. This task-domain
   boundary joins Goal authority to that existing backlog/link transaction
   without introducing a workspace-to-Goal dependency cycle. *)
let add_task_with_result ?contract ?goal_id ?created_by ?predecessor_task_id
    ?skills config ~title ~priority ~description =
  let goal_id = Workspace_task_classify.trim_opt goal_id in
  match Goal_store.with_existing_goals config ~goal_ids:(Option.to_list goal_id) (fun () ->
    Workspace_task.add_task_with_result ?contract ?goal_id ?created_by
      ?predecessor_task_id ?skills config ~title ~priority ~description) with
  | Ok result -> result
  | Error (Goal_store.Goal_missing id) -> Error (Workspace_task.Unknown_goal id)
  | Error (Goal_store.Goal_source_unavailable message) -> Error (Workspace_task.Goal_source_unavailable message)
;;

let batch_add_tasks_with_contracts_result ?created_by config tasks =
  let tasks = List.map (fun (title, priority, description, contract, goal_id) ->
    title, priority, description, contract, Workspace_task_classify.trim_opt goal_id) tasks in
  let goal_ids = List.filter_map (fun (_, _, _, _, goal_id) -> goal_id) tasks in
  match Goal_store.with_existing_goals config ~goal_ids (fun () ->
    Workspace_task.batch_add_tasks_with_contracts_result ?created_by config tasks) with
  | Ok result -> result
  | Error (Goal_store.Goal_missing id) -> Error (Workspace_task.Batch_unknown_goal id)
  | Error (Goal_store.Goal_source_unavailable message) -> Error (Workspace_task.Batch_goal_source_unavailable message)
;;
