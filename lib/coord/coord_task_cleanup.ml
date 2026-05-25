(* Coord_task_cleanup — worktree cleanup + post-transition hooks extracted from Coord_task_transitions. *)
open Masc_domain
open Coord_utils
open Coord_state

let worktree_not_found_payload = function
  | System (System_error.WorktreeNotFound { worktree; searched_in }) ->
    Some (worktree, searched_in)
  | System
      ( System_error.NotInitialized
      | System_error.AlreadyInitialized
      | System_error.InvalidJson _
      | System_error.IoError _
      | System_error.InvalidFilePath _
      | System_error.StorageError _
      | System_error.ValidationError _ )
  | Task _
  | Agent _
  | Auth _
  | Portal _
  | RateLimitExceeded _
  | CacheError _ -> None
;;

let cleanup_worktree_for_transition config ~agent_name ~task_id task reason_label =
  match task.worktree with
  | None -> ()
  | Some _ ->
    (try
       match Coord_worktree.worktree_remove_r config ~agent_name ~task_id with
       | Ok msg ->
         Log.RoomTask.info "%s worktree auto-cleanup: %s" reason_label msg
       | Error e ->
         (match worktree_not_found_payload e with
          | Some (worktree, searched_in) ->
            Log.RoomTask.info
              "%s worktree auto-cleanup: skipped (already absent: worktree=%s searched_in=%s)"
              reason_label
              worktree
              searched_in
          | None ->
            Log.RoomTask.warn
              "%s worktree auto-cleanup failed (best-effort, suppressed): %s"
              reason_label
              (Masc_domain.masc_error_to_string e))
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
       Log.RoomTask.warn
         "%s worktree auto-cleanup raised (best-effort, suppressed): %s"
         reason_label (Printexc.to_string exn))

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
