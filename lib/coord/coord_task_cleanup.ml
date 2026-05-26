(* Coord_task_cleanup — post-transition hooks extracted from Coord_task_transitions. *)
open Masc_domain
open Coord_utils
open Coord_state

let run_done_hooks config ~agent_name ~task_id ~force =
  (try
     (Atomic.get Coord_hooks.agent_economy_earn_fn)
       ~base_path:config.base_path ~agent_name
       ~reason:(Printf.sprintf "completed %s" task_id)
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     Log.RoomTask.error "transition economy done hook: %s" (Printexc.to_string exn));
  (try
     let active = (read_state config).active_agents in
     (Atomic.get Coord_hooks.relation_on_task_done_fn)
       ~assignee:agent_name ~active_agents:active;
     let workers = Coord_task_classify.working_agents config in
     (Atomic.get Coord_hooks.hebbian_on_task_done_fn)
       config ~assignee:agent_name ~active_agents:workers
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     Log.RoomTask.error "transition relation/hebbian done hook: %s" (Printexc.to_string exn))

let run_cancel_hooks config ~agent_name =
  (try
     let workers = Coord_task_classify.working_agents config in
     (Atomic.get Coord_hooks.hebbian_on_task_cancelled_fn)
       config ~agent_name ~active_agents:workers
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     Log.RoomTask.error "transition hebbian cancel hook: %s" (Printexc.to_string exn))
