(* Workspace_task_cleanup — post-transition hooks extracted from Workspace_task_transitions. *)
open Masc_domain
open Workspace_utils
open Workspace_state

let run_done_hooks config ~agent_name ~task_id =
  (try
     (Atomic.get Workspace_hooks.agent_economy_earn_fn)
       ~base_path:config.base_path ~agent_name
       ~reason:(Printf.sprintf "completed %s" task_id)
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
     Log.TaskState.error "transition economy done hook: %s" (Printexc.to_string exn));
  (try
     let snapshot = read_state_snapshot config in
     (match snapshot.status with
      | State_default_from_read_error ->
        Log.TaskState.error
          "transition relation done hook skipped: state read failed: %s"
          (String.concat "; " snapshot.read_errors)
      | State_authoritative | State_recovered_unpersisted ->
        (Atomic.get Workspace_hooks.relation_on_task_done_fn)
          ~assignee:agent_name ~active_agents:snapshot.state.active_agents);
     match Workspace_task_classify.working_agents_result config with
     | Ok workers ->
       (Atomic.get Workspace_hooks.hebbian_on_task_done_fn)
         config ~assignee:agent_name ~active_agents:workers
     | Error error ->
       Log.TaskState.error
         "transition hebbian done hook skipped: %s"
         (Workspace_task_classify.working_agents_error_to_string error)
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     Log.TaskState.error "transition relation/hebbian done hook: %s" (Printexc.to_string exn))

let run_cancel_hooks config ~agent_name =
  (try
     match Workspace_task_classify.working_agents_result config with
     | Ok workers ->
       (Atomic.get Workspace_hooks.hebbian_on_task_cancelled_fn)
         config ~agent_name ~active_agents:workers
     | Error error ->
       Log.TaskState.error
         "transition hebbian cancel hook skipped: %s"
         (Workspace_task_classify.working_agents_error_to_string error)
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     Log.TaskState.error "transition hebbian cancel hook: %s" (Printexc.to_string exn))
