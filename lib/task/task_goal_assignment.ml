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
  | Registry_unreadable of string
  | Already_assigned of
      { task_id : string
      ; existing_goal_ids : string list
      }

let set_task_goal_error_to_string = function
  | Unknown_task task_id -> Printf.sprintf "unknown task '%s'" task_id
  | Unknown_goal goal_id -> Printf.sprintf "unknown goal '%s'" goal_id
  | Registry_unreadable msg -> "goal-task registry unreadable: " ^ msg
  | Already_assigned { task_id; existing_goal_ids } ->
    Printf.sprintf
      "task '%s' is already assigned to goal(s) [%s]; reassignment is out of \
       scope (RFC-0267 Phase 2 only links goalless tasks)"
      task_id
      (String.concat ", " existing_goal_ids)
;;

let set_task_goal config ~task_id ~goal_id : (unit, set_task_goal_error) result =
  let task_exists ~task_id =
    Workspace_query.get_tasks_raw config
    |> List.exists (fun (t : Masc_domain.task) -> String.equal t.id task_id)
  in
  let goal_exists ~goal_id = Option.is_some (Goal_store.get_goal config ~goal_id) in
  (* Reassignment/unlink is a deliberate Non-Goal (RFC-0267 §4). Validate task
     existence, goal existence, and the single-goal registry invariant under the
     goal-task-links file lock immediately before writing the link. This keeps
     the task/goal domain dependency here while avoiding a caller-side
     validate-then-write window around the registry mutation. *)
  match
    Workspace_goal_index.link_goalless_task_to_goal_checked
      config
      ~goal_id
      ~task_id
      ~task_exists
      ~goal_exists
  with
  | Ok () -> Ok ()
  | Error Workspace_goal_index.Link_unknown_task -> Error (Unknown_task task_id)
  | Error Workspace_goal_index.Link_unknown_goal -> Error (Unknown_goal goal_id)
  | Error (Workspace_goal_index.Link_registry_unreadable msg) ->
    Error (Registry_unreadable msg)
  | Error (Workspace_goal_index.Link_already_assigned existing_goal_ids) ->
    Error (Already_assigned { task_id; existing_goal_ids })
;;
