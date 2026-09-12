(* Workspace_task_cleanup — post-transition hooks extracted from Workspace_task_transitions. *)

let run_done_hooks config ~agent_name =
  (try
     let workers = Workspace_task_classify.working_agents config in
     (Atomic.get Workspace_hooks.hebbian_on_task_done_fn)
       config ~assignee:agent_name ~active_agents:workers
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     Log.TaskState.error "transition hebbian done hook: %s" (Printexc.to_string exn))

let run_cancel_hooks config ~agent_name =
  (try
     let workers = Workspace_task_classify.working_agents config in
     (Atomic.get Workspace_hooks.hebbian_on_task_cancelled_fn)
       config ~agent_name ~active_agents:workers
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     Log.TaskState.error "transition hebbian cancel hook: %s" (Printexc.to_string exn))
