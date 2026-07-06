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
  | Unknown_task of string
  | Unknown_goal of string
  | Task_read_failed of string
  | Goal_read_failed of string
  | Already_assigned of
      { task_id : string
      ; existing_goal_ids : string list
      }
  | Link_write_failed of string

let set_task_goal_error_to_string = function
  | Unknown_task task_id -> Printf.sprintf "unknown task '%s'" task_id
  | Unknown_goal goal_id -> Printf.sprintf "unknown goal '%s'" goal_id
  | Task_read_failed msg -> Printf.sprintf "failed to read task backlog: %s" msg
  | Goal_read_failed msg -> Printf.sprintf "failed to read goal store: %s" msg
  | Already_assigned { task_id; existing_goal_ids } ->
    Printf.sprintf
      "task '%s' is already assigned to goal(s) [%s]; reassignment is out of \
       scope (RFC-0267 Phase 2 only links goalless tasks)"
      task_id
      (String.concat ", " existing_goal_ids)
  | Link_write_failed msg -> Printf.sprintf "failed to persist task goal link: %s" msg
;;

let set_task_goal config ~task_id ~goal_id : (unit, set_task_goal_error) result =
  match Workspace_query.get_tasks_raw_result config with
  | Error msg -> Error (Task_read_failed msg)
  | Ok tasks ->
    let task_exists =
      List.exists (fun (t : Masc_domain.task) -> String.equal t.id task_id) tasks
    in
    if not task_exists then Error (Unknown_task task_id)
    else (
      match Goal_store.get_goal_result config ~goal_id with
      | Error msg -> Error (Goal_read_failed msg)
      | Ok None -> Error (Unknown_goal goal_id)
      | Ok (Some _) ->
        (* Reassignment/unlink is a deliberate Non-Goal (RFC-0267 §4). Enforce the
           single-goal invariant at the registry write boundary, not as a
           caller-side check-then-write: concurrent assign requests must be
           serialized by the goal-task-links file lock before observing whether
           the task is still goalless. *)
        (match Workspace_goal_index.link_goalless_task_to_goal config ~goal_id ~task_id with
         | Ok () -> Ok ()
         | Error (Workspace_goal_index.Already_linked_to_goals existing_goal_ids) ->
           Error (Already_assigned { task_id; existing_goal_ids })
         | Error (Workspace_goal_index.Link_write_failed msg) ->
           Error (Link_write_failed msg)))
;;
