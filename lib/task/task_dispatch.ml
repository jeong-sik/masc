(** Task_dispatch - Task operations over the bound Workspace store.

    @since 0.7.0
*)

module Workspace = Workspace_core
open Masc_domain

(** {1 Dispatch Functions} *)

(** Add a new task.
    Delegates to Workspace.add_task. *)
let add_task config ~title ~priority ~description =
  Ok
    (Workspace.add_task
       config ~title ~priority ~description)

(** Get a task by ID *)
let get_task config ~task_id =
  match Workspace.read_backlog_observation_r config with
  | Error message -> Error (System (System_error.IoError message))
  | Ok backlog ->
    Ok (List.find_opt (fun (t : task) -> t.id = task_id) backlog.tasks)

(** List tasks *)
let list_tasks config ?(include_done=false) ?(include_cancelled=false) () =
  match Workspace.read_backlog_observation_r config with
  | Error message -> Error (System (System_error.IoError message))
  | Ok backlog ->
    let tasks =
      List.filter
        (fun (t : task) ->
           let dominated =
             match t.task_status with
             | Done _ -> not include_done
             | Cancelled _ -> not include_cancelled
             | Todo | Claimed _ | InProgress _ | AwaitingVerification _ -> false
           in
           not dominated)
        backlog.tasks
    in
    Ok tasks

let with_locked_backlog
    config
    (f : backlog -> ('a, Masc_error.t) result)
    : ('a, Masc_error.t) result =
  Workspace.with_file_lock config (Workspace.backlog_lock_path config) (fun () ->
    match Workspace.read_backlog_r config with
    | Error msg -> Error (System (System_error.IoError msg))
    | Ok backlog -> f backlog)

(** Delete a task.  Also clears any agent [current_task] cache that still
    points to the deleted task id, so the backlog write and cache
    invalidation happen in the same locked transaction. *)
let delete_task config ~task_id =
  with_locked_backlog config (fun backlog ->
    let task_opt =
      List.find_opt (fun (t : task) -> t.id = task_id) backlog.tasks
    in
    let new_tasks =
      List.filter (fun (t : task) -> t.id <> task_id) backlog.tasks
    in
    (* [write_backlog] stamps version/last_updated at the commit point. *)
    let new_backlog = { backlog with tasks = new_tasks } in
    let status_for_clear =
      match task_opt with
      | Some t -> t.task_status
      | None -> Masc_domain.Todo
    in
    let clear_stale () =
      Task_cache_invariant.clear_stale_agent_task_for_task
        config
        ~task_id
        ~status:status_for_clear
        ~module_name:"task_dispatch.delete_task"
    in
    Workspace.write_backlog ~after_commit:clear_stale config new_backlog;
    Ok ())
