(** RFC-0267 Phase 2 — explicit, validated task->goal assignment.

    See {!Goal_task_assignment} (the .mli) for the contract. *)

(* Why this lives in [masc_goal]: the operation needs all three stores —
   [Goal_store] (goal existence), the task backlog ([Workspace_query], task
   existence), and [Workspace_goal_index] (the link write). [masc_goal] is the
   only library that sees all three: it defines [Goal_store] and depends on
   [masc_workspace]. [masc_workspace] cannot see [Goal_store], and the [masc]
   mega-lib is downstream of the MCP task handlers, so neither could host a
   function that both the MCP and HTTP surfaces call. *)

type set_task_goal_error =
  | Unknown_task of string
  | Unknown_goal of string
  | Already_assigned of
      { task_id : string
      ; existing_goal_ids : string list
      }

let set_task_goal_error_to_string = function
  | Unknown_task task_id -> Printf.sprintf "unknown task '%s'" task_id
  | Unknown_goal goal_id -> Printf.sprintf "unknown goal '%s'" goal_id
  | Already_assigned { task_id; existing_goal_ids } ->
    Printf.sprintf
      "task '%s' is already assigned to goal(s) [%s]; reassignment is out of \
       scope (RFC-0267 Phase 2 only links goalless tasks)"
      task_id
      (String.concat ", " existing_goal_ids)
;;

(* Goal ids currently linked to [task_id] in the registry. Uses the typed
   task->goals index ([build_task_goal_index_for_config]) — the same index the
   dashboard read path projects (RFC-0267 Phase 1) — so "assigned" means
   exactly what the board renders. *)
let existing_goal_ids config ~task_id =
  match
    Stdlib.Hashtbl.find_opt
      (Workspace_goal_index.build_task_goal_index_for_config config)
      task_id
  with
  | Some goal_ids -> goal_ids
  | None -> []
;;

let set_task_goal config ~task_id ~goal_id : (unit, set_task_goal_error) result =
  let task_exists =
    Workspace_query.get_tasks_raw config
    |> List.exists (fun (t : Masc_domain.task) -> String.equal t.id task_id)
  in
  if not task_exists then Error (Unknown_task task_id)
  else (
    match Goal_store.get_goal config ~goal_id with
    | None -> Error (Unknown_goal goal_id)
    | Some _ ->
      (* Reassignment/unlink is a deliberate Non-Goal (RFC-0267 §4): a task that
         already carries any link is rejected rather than silently re-homed. The
         dashboard only offers this control on the "미배정 작업" (unassigned)
         list, so this path is reached only by a direct API caller, for whom an
         explicit error beats a silent no-op. *)
      (match existing_goal_ids config ~task_id with
       | [] ->
         Workspace_goal_index.link_task_to_goal config ~goal_id ~task_id;
         Ok ()
       | existing ->
         Error (Already_assigned { task_id; existing_goal_ids = existing })))
;;
